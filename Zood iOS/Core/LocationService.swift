import CoreLocation
import os
import UIKit

private let log = Logger(subsystem: "com.bensanzone.zood", category: "location")

/// Owns CoreLocation. Two tiers:
/// - **Baseline**: a ~150 m exit geofence around the last shared location, plus significant-change and visit
///   monitoring as a general fallback. All three are cheap, and iOS relaunches the app for them even after it's been
///   terminated, so friends still get our location when we move. This is all iOS 15/16 phones get in the background.
/// - **Live mode**: continuous low-accuracy (Wi-Fi/cell) updates with background updates enabled. This keeps the
///   process alive in the background, which keeps the oscar socket open so we can answer location requests.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var authorization: CLAuthorizationStatus {
        didSet { if authorization != oldValue { onStateChange?() } }
    }
    private(set) var accuracyAuthorization: CLAccuracyAuthorization
    private(set) var lastLocation: CLLocation?
    /// What the user asked for. Live mode only actually runs once iOS grants "Always".
    private var liveRequested = false
    /// Signed-out users must not be monitored, even when location permission was granted previously.
    private var isEnabled = false
    /// While the app is on screen we stream updates regardless of the live setting.
    private var isForeground = true
    var isLive: Bool { liveRequested && hasAlwaysPermission }
    /// A timed share is running: precise fixes every few seconds, in the background too (shown to the person by
    /// the system's location indicator, like Android's "Timed share is running" notification).
    private(set) var isTimedSharing = false
    /// How often to share while a timed share runs (george's TimedShareService asks for a fix every 5 s).
    private let timedShareInterval: TimeInterval = 5

    /// Called for every location that should be shared with friends.
    var onShareableLocation: ((CLLocation) -> Void)?
    /// Called when permission state changes (AppModel republishes it to SwiftUI).
    var onStateChange: (() -> Void)?

    private let manager = CLLocationManager()
    private var lastShared: CLLocation?
    private var freshFixWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var freshFixBest: CLLocation?
    private var freshFixTimeout: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    /// Whether we've asked CoreLocation for continuous updates (it doesn't tell us if it silently dropped them).
    private var isStreaming = false
    private var lastUpdateAt = Date()
    /// iOS 17+: keeps the app "in use" in the background. Without it, iOS only grants ~10 s of runtime per location
    /// event, so a phone sitting still gets suspended and can't hear location requests on the socket.
    private var backgroundSession: AnyObject?
    /// True only when the background session was started while the app was on screen. iOS ignores a session
    /// started during a background relaunch (e.g. after the user swiped the app away), so until the app is
    /// opened again we can't actually answer requests and must not claim we can.
    private(set) var liveArmed = false {
        didSet { if liveArmed != oldValue { onStateChange?() } }
    }

    /// Exit geofence redrawn around every shared location. Apple recommends ≥ 100 m for reliable region events.
    private static let geofenceID = "com.bensanzone.zood.last-shared"
    private let geofenceRadius: CLLocationDistance = 150

    /// CLBackgroundActivitySession (iOS 17+) is what lets live mode keep the app awake. Debug builds can pretend to be
    /// on iOS 15/16 with the `-simulateIOS16` launch argument, since Xcode 27 can't run those simulators.
    static var supportsBackgroundSession: Bool {
        #if DEBUG
        // `simctl launch` swallows dash arguments, so also accept SIMCTL_CHILD_ZOOD_SIMULATE_IOS16=1.
        if ProcessInfo.processInfo.arguments.contains("-simulateIOS16")
            || ProcessInfo.processInfo.environment["ZOOD_SIMULATE_IOS16"] == "1" { return false }
        #endif
        if #available(iOS 17, *) { return true }
        return false
    }

    /// Share when we've moved this far or this long has passed since the last share.
    private let shareDistance: CLLocationDistance = 100
    private let shareInterval: TimeInterval = 10 * 60

    override init() {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        super.init()
        manager.delegate = self
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .other
        UIDevice.current.isBatteryMonitoringEnabled = true
        log.notice("launch: background session supported=\(Self.supportsBackgroundSession, privacy: .public) state=\(UIApplication.shared.applicationState.rawValue, privacy: .public) regions=\(self.manager.monitoredRegions.count, privacy: .public)")
    }

    var hasAlwaysPermission: Bool { authorization == .authorizedAlways }
    var hasAnyPermission: Bool { authorization == .authorizedAlways || authorization == .authorizedWhenInUse }

    func requestPermission() {
        switch authorization {
        case .notDetermined:
            // iOS requires When In Use first; we escalate to Always once that's granted.
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func startBaseline() {
        isEnabled = true
        guard hasAnyPermission else { return }
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        manager.startMonitoringVisits()
        manager.requestLocation()
    }

    func setLive(_ live: Bool) {
        liveRequested = live
        applyStreamingConfiguration()
    }

    func setTimedSharing(_ on: Bool) {
        guard on != isTimedSharing else { return }
        isTimedSharing = on
        applyStreamingConfiguration()
        if on, let lastLocation { share(lastLocation, force: true) }
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        applyStreamingConfiguration()
    }

    func stopAll() {
        isEnabled = false
        liveRequested = false
        isTimedSharing = false
        restartTask?.cancel()
        restartTask = nil
        freshFixTimeout?.cancel()
        freshFixTimeout = nil
        let waiters = freshFixWaiters
        freshFixWaiters = []
        freshFixBest = nil
        waiters.forEach { $0.resume(returning: nil) }
        lastLocation = nil
        lastShared = nil
        isStreaming = false
        updateBackgroundSession()
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
        manager.monitoredRegions.filter { $0.identifier == Self.geofenceID }.forEach { manager.stopMonitoring(for: $0) }
    }

    /// Gets a reasonably precise fix (≤ 50 m, or the best we saw within 20 s). Used to answer a friend's request.
    func freshFix() async -> CLLocation? {
        guard isEnabled, hasAnyPermission else { return nil }
        return await withCheckedContinuation { continuation in
            freshFixWaiters.append(continuation)
            guard freshFixWaiters.count == 1 else { return }
            freshFixBest = nil
            applyStreamingConfiguration()
            freshFixTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finishFreshFix(with: self?.freshFixBest ?? self?.lastLocation)
            }
        }
    }

    private var wantsFreshFix: Bool { !freshFixWaiters.isEmpty }

    private func applyStreamingConfiguration() {
        if wantsFreshFix || isTimedSharing {
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = kCLDistanceFilterNone
        } else {
            // Hundred-meter accuracy is served mostly by Wi-Fi/cell, which is what keeps live mode affordable.
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
        }
        // Re-evaluated on every call, so granting "Always" later switches live mode on without a restart.
        let backgroundStream = isLive || wantsFreshFix || isTimedSharing
        let stream = isEnabled && hasAnyPermission && (backgroundStream || isForeground)
        // A timed share keeps going in the background even with While Using permission; that requires (and
        // shows) the system's background location indicator.
        manager.allowsBackgroundLocationUpdates = (hasAlwaysPermission && backgroundStream) || (isTimedSharing && hasAnyPermission)
        manager.showsBackgroundLocationIndicator = isTimedSharing
        if stream {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
        isStreaming = stream
        updateBackgroundSession()
    }

    private func updateBackgroundSession() {
        guard #available(iOS 17, *), Self.supportsBackgroundSession else { return }
        if isLive || isTimedSharing {
            if backgroundSession == nil || (!liveArmed && isForeground) {
                (backgroundSession as? CLBackgroundActivitySession)?.invalidate()
                backgroundSession = CLBackgroundActivitySession()
                liveArmed = isForeground
            }
        } else {
            (backgroundSession as? CLBackgroundActivitySession)?.invalidate()
            backgroundSession = nil
            liveArmed = false
        }
    }

    /// Stop and start again. Live mode only keeps the app alive while CoreLocation is actively streaming, and an
    /// interruption (locationd restart, transient error) can leave the stream dead without telling us, after which
    /// iOS suspends the app and the socket goes quiet.
    private func restartStreaming(after delay: UInt64 = 1_000_000_000) {
        guard restartTask == nil else { return }
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.isEnabled else { return }
            self.restartTask = nil
            self.manager.stopUpdatingLocation()
            self.applyStreamingConfiguration()
        }
    }

    private func finishFreshFix(with location: CLLocation?) {
        freshFixTimeout?.cancel()
        freshFixTimeout = nil
        let waiters = freshFixWaiters
        freshFixWaiters = []
        applyStreamingConfiguration()
        waiters.forEach { $0.resume(returning: location) }
        if let location { share(location, force: true) }
    }

    private func share(_ location: CLLocation, force: Bool = false) {
        guard isEnabled else { return }
        if !force, isTimedSharing, let lastShared {
            // Timed share: time-based, so the person following the link sees steady updates.
            guard location.timestamp.timeIntervalSince(lastShared.timestamp) >= timedShareInterval else { return }
        } else if !force, let lastShared {
            let moved = location.distance(from: lastShared)
            let elapsed = location.timestamp.timeIntervalSince(lastShared.timestamp)
            guard moved >= shareDistance || elapsed >= shareInterval else { return }
        }
        lastShared = location
        onShareableLocation?(location)
        updateGeofence(around: location)
    }

    /// Replace the exit geofence so leaving the area around where friends last saw us wakes the app, even if it was
    /// suspended or terminated. Finer-grained than significant-change monitoring (~500 m, cell-tower based).
    /// Mainly for iOS 15/16, which can't keep live mode awake. Where region monitoring isn't available (it's
    /// deprecated on iOS 17+ and absent in the simulator) we skip it and rely on significant change and visits.
    private func updateGeofence(around location: CLLocation) {
        guard hasAlwaysPermission, CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            log.notice("geofence skipped: always=\(self.hasAlwaysPermission, privacy: .public) available=\(CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self), privacy: .public)")
            return
        }
        let region = CLCircularRegion(center: location.coordinate,
                                      radius: min(max(geofenceRadius, location.horizontalAccuracy), manager.maximumRegionMonitoringDistance),
                                      identifier: Self.geofenceID)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        // Same identifier replaces the previous region.
        manager.startMonitoring(for: region)
        log.notice("geofence set: r=\(Int(region.radius), privacy: .public) m")
    }

    /// Region exits and visits give us ~10 s of background time; ask for more so the fix and upload can finish.
    private func handleBackgroundTrigger(_ reason: String) {
        guard isEnabled else { return }
        log.notice("wake: \(reason, privacy: .public)")
        let task = BackgroundTask()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "share-location") { task.end() }
        Task {
            _ = await freshFix()   // shares (and redraws the geofence) when it completes
            try? await Task.sleep(nanoseconds: 5_000_000_000)   // let the upload finish
            task.end()
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        guard isEnabled else { return }
        if authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        if hasAnyPermission {
            startBaseline()
        }
        applyStreamingConfiguration()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isEnabled else { return }
        // Any delivery is a chance to re-arm live mode. A long gap means the stream had died and this is a
        // significant-change wake after a suspension, so restart the stream to stay alive from here on.
        let now = Date()
        if isLive, !isStreaming || now.timeIntervalSince(lastUpdateAt) > 120 { restartStreaming(after: 0) }
        lastUpdateAt = now
        if !isStreaming { log.notice("wake: significant change") }
        for location in locations where location.horizontalAccuracy >= 0 {
            lastLocation = location
            if wantsFreshFix {
                if isTimedSharing { share(location) }
                if location.horizontalAccuracy < (freshFixBest?.horizontalAccuracy ?? .greatestFiniteMagnitude) {
                    freshFixBest = location
                }
                if location.horizontalAccuracy <= 50, location.timestamp.timeIntervalSinceNow > -15 {
                    finishFreshFix(with: location)
                }
            } else {
                share(location)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        if isLive { restartStreaming(after: 0) }
        // Arriving somewhere or leaving: worth a precise update.
        handleBackgroundTrigger("visit")
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == Self.geofenceID else { return }
        if isLive { restartStreaming(after: 0) }
        handleBackgroundTrigger("left geofence")
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        log.error("geofence failed: \(error.localizedDescription, privacy: .public)")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { return }
        // Includes "location unavailable" after a locationd interruption: restart so live mode keeps us alive.
        restartStreaming()
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        // We disable automatic pausing, but if iOS pauses anyway, resume immediately.
        restartStreaming(after: 0)
    }
}

/// Holds a background task ID so the expiration handler and the normal path can both end it exactly once.
@MainActor
private final class BackgroundTask {
    var id = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Battery info in the format Zood's `location_info` uses.
@MainActor
enum Battery {
    static var level: Int? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
    }

    static var isCharging: Bool? {
        switch UIDevice.current.batteryState {
        case .charging, .full: return true
        case .unplugged: return false
        default: return nil
        }
    }
}
