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

    /// Called on the main thread as each mile marker is reached.
    var onMileReached: ((Int) -> Void)?

    static let metresPerMile = 1609.344
    static let finalMile = 26

    private let manager = CLLocationManager()
    private var lastFix: CLLocation?
    private var reachedMiles: Set<Int> = []

    private enum Key {
        static let metres = "race.metres"
        static let reached = "race.reachedMiles"
        static let running = "race.isRunning"
    }

    var milesCovered: Double { metres / Self.metresPerMile }

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
        lastFix = nil
        persist()
    }

    /// Wipes progress. Only for testing between training runs — never needed
    /// mid-race, which is exactly why it isn't wired to anything automatic.
    func reset() {
        stop()
        metres = 0
        reachedMiles = []
        hasFix = false
        persist()
    }

    func hasReached(mile: Int) -> Bool { reachedMiles.contains(mile) }

    var nextMile: Int? {
        (1...Self.finalMile).first { !reachedMiles.contains($0) }
    }

    // MARK: - Persistence

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(metres, forKey: Key.metres)
        defaults.set(Array(reachedMiles), forKey: Key.reached)
        defaults.set(isRunning, forKey: Key.running)
    }

    private func restore() {
        let defaults = UserDefaults.standard
        metres = defaults.double(forKey: Key.metres)
        reachedMiles = Set(defaults.array(forKey: Key.reached) as? [Int] ?? [])

        // Resume automatically after a crash rather than waiting to be noticed.
        if defaults.bool(forKey: Key.running) {
            start()
        }
    }

    // MARK: - Distance

    private func consume(_ fix: CLLocation) {
        guard fix.horizontalAccuracy > 0, fix.horizontalAccuracy < 25 else { return }
        guard fix.timestamp.timeIntervalSinceNow > -5 else { return }

        problem = nil // fixes are flowing again
        hasFix = true

        defer { lastFix = fix }
        guard let previous = lastFix else { return }

        let step = fix.distance(from: previous)
        let elapsed = fix.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return }

        // Under a metre is GPS jitter while standing; over 8 m/s is a bad fix,
        // being faster than any marathon pace by a wide margin.
        guard step > 1, step / elapsed < 8 else { return }

        metres += step
        announceMilesPassed()
        persist()
    }

    private func announceMilesPassed() {
        let covered = Int(milesCovered)
        guard covered >= 1 else { return }

        for mile in 1...min(covered, Self.finalMile) where !reachedMiles.contains(mile) {
            reachedMiles.insert(mile)
            onMileReached?(mile)
        }
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
