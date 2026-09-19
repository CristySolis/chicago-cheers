import Foundation
import Combine
import CoreLocation

/// Tracks how far into the race she is, and reports each mile marker as it is
/// passed.
///
/// Accuracy barely matters here: a cheer placed at mile 18 is just as good
/// arriving 100 metres early or late, so this deliberately avoids the
/// calibration and filtering a real distance tracker would need.
///
/// It does have to survive being killed mid-race, though — an app restart at
/// mile 14 must not replay miles 1 to 13. Progress is written to disk on every
/// update for that reason.
final class RaceTracker: NSObject, ObservableObject {

    @Published private(set) var metres: Double = 0
    @Published private(set) var isRunning = false
    @Published private(set) var problem: String?

    /// False until the first real fix arrives, so "waiting for GPS" is never
    /// mistaken for "running normally".
    @Published private(set) var hasFix = false

    /// Called on the main thread as each course slot is reached.
    var onMileReached: ((Double) -> Void)?

    private let manager = CLLocationManager()
    private var meter = DistanceMeter()

    private enum Key {
        static let metres = "race.metres"
        static let reached = "race.reachedMiles"
        static let running = "race.isRunning"
    }

    var milesCovered: Double { meter.milesCovered }

    override init() {
        super.init()
        manager.delegate = self
        // Ten metres, not Best. A cheer placed at mile 18 reads the same either
        // way, and Best is materially hungrier over four and a half hours —
        // battery is the real constraint here, not precision.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.activityType = .fitness
        // Without this iOS decides on its own that she has stopped moving and
        // silently ends updates — which on a four hour run is fatal.
        manager.pausesLocationUpdatesAutomatically = false

        restore()
    }

    // MARK: - Control

    func start() {
        problem = nil
        manager.requestAlwaysAuthorization()

        guard CLLocationManager.locationServicesEnabled() else {
            problem = "Location Services are off — distance can't be tracked."
            return
        }

        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isRunning = true
        persist()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
        meter.breakTrail()
        persist()
    }

    /// Wipes progress. Only for testing between training runs — never needed
    /// mid-race, which is exactly why it isn't wired to anything automatic.
    func reset() {
        stop()
        meter = DistanceMeter()
        metres = 0
        hasFix = false
        persist()
    }

    func hasReached(mile: Double) -> Bool { meter.reachedMiles.contains(mile) }

    var nextMile: Double? {
        Course.slots.first { !meter.reachedMiles.contains($0) }
    }

    // MARK: - Persistence

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(metres, forKey: Key.metres)
        defaults.set(Array(meter.reachedMiles), forKey: Key.reached)
        defaults.set(isRunning, forKey: Key.running)
    }

    private func restore() {
        let defaults = UserDefaults.standard
        meter = DistanceMeter(
            metres: defaults.double(forKey: Key.metres),
            reachedMiles: Set(defaults.array(forKey: Key.reached) as? [Double] ?? [])
        )
        metres = meter.metres

        // Resume automatically after a crash rather than waiting to be noticed.
        if defaults.bool(forKey: Key.running) {
            start()
        }
    }

    // MARK: - Distance

    private func consume(_ fix: CLLocation) {
        guard let passed = meter.add(fix, now: Date()) else { return }

        problem = nil // fixes are flowing again
        hasFix = true

        metres = meter.metres
        passed.forEach { onMileReached?($0) }
        persist()
    }
}

extension RaceTracker: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locations.forEach(consume)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // locationUnknown means "no fix yet". Core Location keeps retrying and
        // recovers on its own, so reporting it just leaves a red error on
        // screen that never clears — alarming at mile 18 for no reason.
        if (error as? CLError)?.code == .locationUnknown { return }
        problem = "Location error: \(error.localizedDescription)"
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            problem = "Location access denied — distance can't be tracked."
        default:
            // "While Using" is enough: allowsBackgroundLocationUpdates keeps
            // fixes coming with the screen locked, marked by the blue pill.
            problem = nil
        }
    }
}
