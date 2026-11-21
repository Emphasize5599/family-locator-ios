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
    private(set) var isLive = false

    /// Called for every location that should be shared with friends.
    var onShareableLocation: ((CLLocation) -> Void)?
    /// Called when permission state changes (AppModel republishes it to SwiftUI).
    var onStateChange: (() -> Void)?

    private let manager = CLLocationManager()
    private var lastShared: CLLocation?
    private var freshFixWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var freshFixBest: CLLocation?
    private var freshFixTimeout: Task<Void, Never>?

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
        isLive = live && hasAlwaysPermission
        applyStreamingConfiguration()
    }

    func stopAll() {
        isLive = false
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
        let stream = isLive || wantsFreshFix
        manager.allowsBackgroundLocationUpdates = hasAlwaysPermission && stream
        manager.showsBackgroundLocationIndicator = false
        if stream {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
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
        // Arriving somewhere or leaving: worth a precise update.
        Task { _ = await freshFix() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; everything else we just wait out.
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
