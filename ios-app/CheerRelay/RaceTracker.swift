import Foundation
import Combine
import CoreLocation
import UIKit

/// Tracks how far into the race the runner is, and reports each mile marker as it is
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

    /// When Start was first pressed for this race: the race clock counts from
    /// here, through stops and app restarts, until Reset.
    @Published private(set) var startedAt: Date?

    /// The cheer that played most recently during the run, for the race screen.
    @Published private(set) var lastCheer: PlayedCheer?

    struct PlayedCheer: Equatable {
        let sender: String
        let mile: Double
        let raceClock: TimeInterval?
    }

    /// Called on the main thread as each course slot is reached.
    var onMileReached: ((Double) -> Void)?

    /// Everything that happens, for looking back after the race.
    let log = RaceLog()

    private let manager = CLLocationManager()
    private var meter = DistanceMeter()
    private var lastUsableFixAt: Date?
    private var lastBatteryLogAt: Date?

    /// A gap longer than this between usable fixes is worth noting in the log.
    private static let gpsGap: TimeInterval = 30
    private static let batteryEvery: TimeInterval = 5 * 60

    private enum Key {
        static let metres = "race.metres"
        static let reached = "race.reachedMiles"
        static let running = "race.isRunning"
        static let startedAt = "race.startedAt"
        static let stoppedAt = "race.stoppedAt"
    }

    /// When the run was last stopped, so the clock on screen freezes at the
    /// finish time instead of ticking on. The log always uses the real time.
    @Published private(set) var stoppedAt: Date?

    func raceClock(at time: Date = Date()) -> TimeInterval? {
        startedAt.map { time.timeIntervalSince($0) }
    }

    /// The race clock as the screen shows it: frozen while stopped.
    func displayedClock(at time: Date) -> TimeInterval? {
        raceClock(at: isRunning ? time : (stoppedAt ?? time))
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
        // Without this iOS decides on its own that the runner has stopped moving and
        // silently ends updates — which on a four hour run is fatal.
        manager.pausesLocationUpdatesAutomatically = false

        restore()
    }

    // MARK: - Control

    func start() {
        problem = nil
        manager.requestAlwaysAuthorization()

        // No up-front "are Location Services on?" check: it blocks the main
        // thread, and iOS already reports them being off as .denied, which
        // locationManagerDidChangeAuthorization turns into a visible problem.
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isRunning = true
        stoppedAt = nil

        let now = Date()
        if startedAt == nil {
            startedAt = now
            log.begin(at: now)
            logEvent("race_start", at: now)
        } else {
            logEvent("resume", at: now)
        }
        logBattery(at: now)
        persist()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isRunning = false
        meter.breakTrail()
        lastUsableFixAt = nil
        let now = Date()
        stoppedAt = now
        logEvent("stop", at: now)
        persist()
    }

    /// Wipes progress. Only for testing between training runs — never needed
    /// mid-race, which is exactly why it isn't wired to anything automatic.
    func reset() {
        stop()
        logEvent("reset", at: Date())
        meter = DistanceMeter()
        metres = 0
        hasFix = false
        startedAt = nil
        stoppedAt = nil
        lastCheer = nil
        persist()
    }

    /// Where location permission stands, for the race-morning checklist.
    var locationAccess: ReadinessSnapshot.LocationAccess {
        switch manager.authorizationStatus {
        case .notDetermined: return .notAsked
        case .denied, .restricted: return .denied
        default: return manager.accuracyAuthorization == .fullAccuracy ? .allowed : .approximate
        }
    }

    func askForLocation() {
        manager.requestAlwaysAuthorization()
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
        defaults.set(startedAt, forKey: Key.startedAt)
        defaults.set(stoppedAt, forKey: Key.stoppedAt)
    }

    private func restore() {
        let defaults = UserDefaults.standard
        meter = DistanceMeter(
            metres: defaults.double(forKey: Key.metres),
            reachedMiles: Set(defaults.array(forKey: Key.reached) as? [Double] ?? [])
        )
        metres = meter.metres
        startedAt = defaults.object(forKey: Key.startedAt) as? Date
        stoppedAt = defaults.object(forKey: Key.stoppedAt) as? Date

        // An app restart mid-race is exactly what the log is for spotting.
        let wasRunning = defaults.bool(forKey: Key.running)
        if startedAt != nil {
            logEvent("app_launch", at: Date(), detail: wasRunning ? "was running" : "was stopped")
        }

        // Resume automatically after a crash rather than waiting to be noticed.
        if wasRunning {
            start()
        }
    }

    // MARK: - Distance

    private func consume(_ fix: CLLocation) {
        let now = Date()
        let passed = meter.add(fix, now: now)
        log.fix(fix, raceClock: raceClock(at: now), outcome: meter.lastOutcome, metres: meter.metres)
        guard let passed else { return }

        problem = nil // fixes are flowing again
        hasFix = true
        if let last = lastUsableFixAt, now.timeIntervalSince(last) > Self.gpsGap {
            logEvent("gps_gap", at: now, detail: "\(Int(now.timeIntervalSince(last))) s without a usable fix")
        }
        lastUsableFixAt = now

        metres = meter.metres
        for mile in passed {
            logEvent("mile", at: now, mile: mile)
            onMileReached?(mile)
        }
        if let last = lastBatteryLogAt, now.timeIntervalSince(last) >= Self.batteryEvery {
            logBattery(at: now)
        }
        persist()
    }

    // MARK: - Log

    /// Notes a cheer as it starts playing. Previews on the sofa don't count:
    /// only cheers during a run are logged.
    func cheerStarted(sender: String, mile: Double) {
        guard isRunning else { return }
        let now = Date()
        logEvent("cheer", at: now, mile: mile, detail: sender)
        lastCheer = PlayedCheer(sender: sender, mile: mile, raceClock: raceClock(at: now))
    }

    func logEvent(_ name: String, at time: Date, mile: Double? = nil, detail: String? = nil) {
        log.event(name, at: time, raceClock: raceClock(at: time), mile: mile,
                  metres: meter.metres, detail: detail)
    }

    private func logBattery(at time: Date) {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        guard device.batteryLevel >= 0 else { return } // unknown, as in the simulator
        let charging = device.batteryState == .charging || device.batteryState == .full
        logEvent("battery", at: time,
                 detail: "\(Int((device.batteryLevel * 100).rounded()))%" + (charging ? " charging" : ""))
        lastBatteryLogAt = time
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
            problem = "Location is off for this app, or Location Services are off in Settings — distance can't be tracked."
        default:
            // "While Using" is enough: allowsBackgroundLocationUpdates keeps
            // fixes coming with the screen locked, marked by the blue pill.
            problem = nil
        }
    }
}
