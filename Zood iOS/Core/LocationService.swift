import CoreLocation
import UIKit

/// Owns CoreLocation. Two tiers:
/// - **Baseline**: significant-change + visit monitoring. Cheap, and iOS relaunches the app for these
///   even after it's been terminated, so friends still get our location when we move.
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
    /// While the app is on screen we stream updates regardless of the live setting.
    private var isForeground = true
    var isLive: Bool { liveRequested && hasAlwaysPermission }

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

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        applyStreamingConfiguration()
    }

    func stopAll() {
        liveRequested = false
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.stopMonitoringVisits()
    }

    /// Gets a reasonably precise fix (≤ 50 m, or the best we saw within 20 s). Used to answer a friend's request.
    func freshFix() async -> CLLocation? {
        guard hasAnyPermission else { return nil }
        return await withCheckedContinuation { continuation in
            freshFixWaiters.append(continuation)
            guard freshFixWaiters.count == 1 else { return }
            freshFixBest = nil
            applyStreamingConfiguration()
            freshFixTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.finishFreshFix(with: self?.freshFixBest ?? self?.lastLocation)
            }
        }
    }

    private var wantsFreshFix: Bool { !freshFixWaiters.isEmpty }

    private func applyStreamingConfiguration() {
        if wantsFreshFix {
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = kCLDistanceFilterNone
        } else {
            // Hundred-meter accuracy is served mostly by Wi-Fi/cell, which is what keeps live mode affordable.
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 50
        }
        // Re-evaluated on every call, so granting "Always" later switches live mode on without a restart.
        let backgroundStream = isLive || wantsFreshFix
        let stream = hasAnyPermission && (backgroundStream || isForeground)
        manager.allowsBackgroundLocationUpdates = hasAlwaysPermission && backgroundStream
        manager.showsBackgroundLocationIndicator = false
        if stream {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
        isStreaming = stream
        updateBackgroundSession()
    }

    private func updateBackgroundSession() {
        guard #available(iOS 17, *) else { return }
        if isLive {
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
            guard let self else { return }
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
        if !force, let lastShared {
            let moved = location.distance(from: lastShared)
            let elapsed = location.timestamp.timeIntervalSince(lastShared.timestamp)
            guard moved >= shareDistance || elapsed >= shareInterval else { return }
        }
        lastShared = location
        onShareableLocation?(location)
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        if authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
        if hasAnyPermission {
            startBaseline()
            applyStreamingConfiguration()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Any delivery is a chance to re-arm live mode. A long gap means the stream had died and this is a
        // significant-change wake after a suspension, so restart the stream to stay alive from here on.
        let now = Date()
        if isLive, !isStreaming || now.timeIntervalSince(lastUpdateAt) > 120 { restartStreaming(after: 0) }
        lastUpdateAt = now
        for location in locations where location.horizontalAccuracy >= 0 {
            lastLocation = location
            if wantsFreshFix {
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
        Task { _ = await freshFix() }
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
