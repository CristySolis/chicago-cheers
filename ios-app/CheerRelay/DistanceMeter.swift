import Foundation
import CoreLocation

/// Turns a stream of GPS fixes into distance run and course slots passed.
///
/// Pure arithmetic: no location manager, no storage, no clock of its own, so
/// it can be fed made-up fixes in tests. RaceTracker owns the GPS and the
/// saving; this owns the maths.
nonisolated struct DistanceMeter {

    private(set) var metres: Double
    private(set) var reachedMiles: Set<Double>
    private var lastFix: CLLocation?

    /// Fixes less precise than this are skipped entirely.
    static let worstAccuracy: CLLocationAccuracy = 25
    /// Fixes older than this on arrival are skipped: iOS sometimes delivers a
    /// cached position first, which would count distance from the wrong place.
    static let oldestFix: TimeInterval = 5
    /// Over 8 m/s is a bad fix, faster than any marathon pace by a wide margin.
    static let fastestPace: Double = 8

    init(metres: Double = 0, reachedMiles: Set<Double> = []) {
        self.metres = metres
        self.reachedMiles = reachedMiles
    }

    var milesCovered: Double { metres / Course.metresPerMile }

    /// Adds one fix. Returns nil if the fix was unusable (too imprecise or
    /// stale), otherwise the course slots it carried the runner past, in
    /// course order — usually none.
    mutating func add(_ fix: CLLocation, now: Date) -> [Double]? {
        guard fix.horizontalAccuracy > 0,
              fix.horizontalAccuracy < Self.worstAccuracy else { return nil }
        guard fix.timestamp.timeIntervalSince(now) > -Self.oldestFix else { return nil }

        defer { lastFix = fix }
        guard let previous = lastFix else { return [] }

        let elapsed = fix.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return [] }

        let step = Self.distance(from: previous, to: fix, over: elapsed)
        guard step / elapsed < Self.fastestPace else { return [] }

        metres += step
        return passSlots()
    }

    /// Forgets where the runner last was, so the next fix starts a new trail
    /// instead of counting a straight line from before a pause.
    mutating func breakTrail() {
        lastFix = nil
    }

    /// Joining the dots between positions overcounts. Every fix is a few metres
    /// off in a direction that wanders, so the traced path zigzags, and a
    /// zigzag is longer than the line actually run. The first field test read
    /// about 6% long — 200 m by mile 2, which would be 1.6 miles by the finish
    /// — and simulating noisier GPS, like the Loop's towers, pushes that past
    /// 20%.
    ///
    /// The receiver's Doppler speed doesn't wobble that way (within 0.2% in the
    /// same simulation), so distance is speed integrated over time, falling
    /// back to position only when speed isn't reported.
    static func distance(from previous: CLLocation,
                         to fix: CLLocation,
                         over elapsed: TimeInterval) -> Double {
        switch (hasUsableSpeed(previous), hasUsableSpeed(fix)) {
        case (true, true):
            return (previous.speed + fix.speed) / 2 * elapsed
        case (_, true):
            return fix.speed * elapsed
        default:
            let step = fix.distance(from: previous)
            return step > 1 ? step : 0 // under a metre is jitter while standing
        }
    }

    private static func hasUsableSpeed(_ fix: CLLocation) -> Bool {
        fix.speed >= 0 && fix.speedAccuracy >= 0
    }

    private mutating func passSlots() -> [Double] {
        let covered = milesCovered
        let passed = Course.slots.filter { $0 <= covered && !reachedMiles.contains($0) }
        reachedMiles.formUnion(passed)
        return passed
    }
}
