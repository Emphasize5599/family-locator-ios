import CoreMotion
import Foundation

/// How you're moving (driving, cycling, running, walking or still), from Apple's Motion & Fitness activity,
/// sent with each location so friends see the same activity icon Android shows. Uses the shared protocol's
/// `movement` values. Asks for Motion & Fitness permission the first time it starts; if that's declined (or the
/// phone has no motion coprocessor) locations simply go without it.
@MainActor
final class MotionActivity {
    static let shared = MotionActivity()

    private let manager = CMMotionActivityManager()
    private var latest: CMMotionActivity?
    private var started = false

    static var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    private var isAuthorized: Bool {
        switch CMMotionActivityManager.authorizationStatus() {
        case .authorized, .notDetermined: return true
        default: return false
        }
    }

    /// Starts following activity (the first call shows the permission prompt).
    func start() {
        guard !started, Self.isAvailable, isAuthorized else { return }
        started = true
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            MainActor.assumeIsolated { self?.latest = activity }
        }
    }

    /// The protocol's movement value for right now, or nil when it isn't known.
    func currentMovement() async -> String? {
        guard Self.isAvailable, CMMotionActivityManager.authorizationStatus() == .authorized else { return nil }
        if let latest, Date().timeIntervalSince(latest.startDate) < 120 || isOngoing(latest), let value = Self.movement(latest) {
            return value
        }
        // Woken in the background, the live updates may have paused; the motion coprocessor keeps a history.
        let recent: [CMMotionActivity] = await withCheckedContinuation { continuation in
            manager.queryActivityStarting(from: Date().addingTimeInterval(-600), to: Date(), to: .main) { activities, _ in
                continuation.resume(returning: activities ?? [])
            }
        }
        guard let last = recent.last(where: { $0.confidence != .low }) else { return nil }
        latest = last
        return Self.movement(last)
    }

    /// An activity stays current until the next one begins, so an old start date alone doesn't make it stale.
    private func isOngoing(_ activity: CMMotionActivity) -> Bool {
        Date().timeIntervalSince(activity.startDate) < 15 * 60
    }

    private static func movement(_ activity: CMMotionActivity) -> String? {
        guard activity.confidence != .low else { return nil }
        if activity.automotive { return "vehicle" }
        if activity.cycling { return "bicycle" }
        if activity.running { return "running" }
        if activity.walking { return "walking" }
        if activity.stationary { return "stationary" }
        return nil
    }
}
