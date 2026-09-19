import CoreLocation
import Foundation
import Testing
@testable import CheerRelay

/// Distance is what decides when each cheer plays, and there is no second
/// chance on race day, so these pin down every rule the meter applies to a fix.
struct DistanceMeterTests {

    // MARK: - How far a step is

    @Test func withSpeedOnBothFixesTheStepIsTheAverageSpeedOverTheGap() {
        var meter = DistanceMeter()
        feed(&meter, fix(at: 0, speed: 3))
        feed(&meter, fix(at: 2, speed: 4))

        #expect(meter.metres == 7) // (3 + 4) / 2 × 2 s
    }

    @Test func withSpeedOnlyOnTheNewFixThatSpeedIsUsed() {
        var meter = DistanceMeter()
        feed(&meter, fix(at: 0))
        feed(&meter, fix(at: 2, speed: 3))

        #expect(meter.metres == 6)
    }

    @Test func speedIsPreferredOverPosition() {
        var meter = DistanceMeter()
        feed(&meter, fix(at: 0, north: 0, speed: 3))
        feed(&meter, fix(at: 1, north: 10, speed: 3)) // positions 10 m apart

        #expect(meter.metres == 3)
    }

    @Test func withoutSpeedTheStepIsTheDistanceBetweenPositions() {
        var meter = DistanceMeter()
        feed(&meter, fix(at: 0, north: 0))
        feed(&meter, fix(at: 2, north: 6))

        #expect(abs(meter.metres - 6) < 0.05)
    }

    @Test func withoutSpeedUnderAMetreIsTreatedAsStandingStill() {
        var meter = DistanceMeter()
        feed(&meter, fix(at: 0, north: 0))
        feed(&meter, fix(at: 1, north: 0.8))

        #expect(meter.metres == 0)
    }

    @Test func aSpeedWithoutAKnownAccuracyIsNotTrusted() {
        var meter = DistanceMeter()
        feed(&meter, fix(at: 0, north: 0))
        feed(&meter, fix(at: 1, north: 4, speed: 3, speedAccuracy: -1))

        #expect(abs(meter.metres - 4) < 0.05) // position, not the 3 m/s
    }

    /// The bug that made cheers fire early: joining noisy positions reads
    /// long, integrating speed does not.
    @Test func noisyPositionsDoNotStretchTheDistance() {
        var bySpeed = DistanceMeter()
        var byPosition = DistanceMeter()
        var noise = Noise()

        for second in 0...600 {
            let t = Double(second)
            let north = 3 * t + noise.next(within: 1.5)
            let east = noise.next(within: 1.5)
            feed(&bySpeed, fix(at: t, north: north, east: east, speed: 3 + noise.next(within: 0.1)))
            feed(&byPosition, fix(at: t, north: north, east: east))
        }

        let truth = 1800.0
        #expect(abs(bySpeed.metres - truth) / truth < 0.005)
        #expect(byPosition.metres > truth * 1.05) // why speed is used at all
    }

    // MARK: - Which fixes count

    @Test func theFirstFixIsAcceptedButCountsNothing() {
        var meter = DistanceMeter()
        #expect(meter.add(fix(at: 0, speed: 3), now: at(0)) == [])
        #expect(meter.metres == 0)
    }

    @Test(arguments: [25.0, 60, 0, -1])
    func impreciseFixesAreSkipped(accuracy: Double) {
        var meter = DistanceMeter()
        feed(&meter, fix(at: 0, speed: 3))

        #expect(meter.add(fix(at: 1, speed: 3, accuracy: accuracy), now: at(1)) == nil)
        #expect(meter.metres == 0)
    }

    @Test func aSkippedFixIsNotUsedAsTheStartOfTheNextStep() {
        var meter = DistanceMeter()
        feed(&meter, fix(at: 0, north: 0))
        _ = meter.add(fix(at: 1, north: 500, accuracy: 80), now: at(1))
        feed(&meter, fix(at: 2, north: 5))

        #expect(abs(meter.metres - 5) < 0.05)
    }

    @Test func staleFixesAreSkipped() {
        var meter = DistanceMeter()
        feed(&meter, fix(at: 0, speed: 3))

        // Arrives 6 s after it was taken: a cached position, not a live one.
        #expect(meter.add(fix(at: 10, speed: 3), now: at(16)) == nil)
        #expect(meter.add(fix(at: 11, speed: 3), now: at(15)) != nil)
    }

    @Test func impossiblyFastStepsAreDiscarded() {
        var meter = DistanceMeter()
        feed(&meter, fix(at: 0, north: 0))

        #expect(meter.add(fix(at: 1, north: 9), now: at(1)) == []) // 9 m/s
        #expect(meter.metres == 0)
    }

    @Test func aFixAtTheSameMomentAddsNothing() {
        var meter = DistanceMeter()
        feed(&meter, fix(at: 5, speed: 3))
        feed(&meter, fix(at: 5, speed: 3))
        feed(&meter, fix(at: 4, speed: 3)) // delivered out of order

        #expect(meter.metres == 0)
    }

    @Test func afterAPauseTheGapIsNotCounted() {
        var meter = DistanceMeter()
        feed(&meter, fix(at: 0, north: 0))
        feed(&meter, fix(at: 1, north: 3))
        meter.breakTrail() // stopped, walked to the start corral, started again
        feed(&meter, fix(at: 600, north: 700))
        feed(&meter, fix(at: 601, north: 703))

        #expect(abs(meter.metres - 6) < 0.05)
    }

    // MARK: - Which slots are passed

    @Test func aSlotIsReportedOnceWhenItsDistanceIsReached() {
        var meter = DistanceMeter(metres: Course.metresPerMile - 4)

        #expect(meter.add(fix(at: 0, speed: 3), now: at(0)) == [])
        #expect(meter.add(fix(at: 1, speed: 3), now: at(1)) == []) // 1 m short
        #expect(meter.add(fix(at: 2, speed: 3), now: at(2)) == [1])
        #expect(meter.add(fix(at: 3, speed: 3), now: at(3)) == [])
        #expect(meter.reachedMiles == [1])
    }

    @Test func afterARestartSlotsAlreadyPlayedAreNotRepeated() {
        let restored = DistanceMeter(metres: 14.4 * Course.metresPerMile,
                                     reachedMiles: Set(Course.slots.filter { $0 <= 14 }))
        var meter = restored
        feed(&meter, fix(at: 0, speed: 3))
        let passed = meter.add(fix(at: 60, speed: 3), now: at(60)) // 180 m on

        #expect(passed == [14.5])
    }

    @Test func slotsMissedWhileNotCountingAreAllReportedInCourseOrder() {
        var meter = DistanceMeter(metres: 3 * Course.metresPerMile, reachedMiles: [1])
        feed(&meter, fix(at: 0, speed: 3))

        #expect(meter.add(fix(at: 1, speed: 3), now: at(1)) == [2, 3])
    }

    @Test func aWholeMarathonPassesEverySlotOnceInOrder() {
        var meter = DistanceMeter()
        var passed: [Double] = []
        let marathon = 42_195.0
        let pace = 3.0 // m/s, a 3:54 marathon

        for second in 0...Int(marathon / pace) {
            passed += meter.add(fix(at: Double(second), speed: pace), now: at(Double(second))) ?? []
        }

        #expect(passed == Course.slots)
        #expect(abs(meter.metres - marathon) < pace)
    }

    // MARK: - Helpers

    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let grantPark = CLLocationCoordinate2D(latitude: 41.8756, longitude: -87.6244)

    private func at(_ seconds: TimeInterval) -> Date {
        Self.start.addingTimeInterval(seconds)
    }

    /// A fix taken `seconds` into the run, `north`/`east` metres from the start.
    /// A negative speed means "not reported", as Core Location does.
    private func fix(at seconds: TimeInterval,
                     north: Double = 0,
                     east: Double = 0,
                     speed: Double = -1,
                     speedAccuracy: Double? = nil,
                     accuracy: Double = 5) -> CLLocation {
        let metresPerDegree = 111_320.0
        let latitude = Self.grantPark.latitude + north / metresPerDegree
        let longitude = Self.grantPark.longitude
            + east / (metresPerDegree * cos(Self.grantPark.latitude * .pi / 180))
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 180,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            course: -1,
            courseAccuracy: -1,
            speed: speed,
            speedAccuracy: speedAccuracy ?? (speed >= 0 ? 0.3 : -1),
            timestamp: at(seconds)
        )
    }

    /// Adds a fix that arrives the moment it was taken, and requires it to count.
    private func feed(_ meter: inout DistanceMeter, _ fix: CLLocation) {
        let result = meter.add(fix, now: fix.timestamp)
        #expect(result != nil, "a good fix was skipped")
    }
}

/// Repeatable noise, so a failing run can be rerun exactly.
private struct Noise {
    private var state: UInt64 = 0x2545_F491_4F6C_DD1D

    mutating func next(within bound: Double) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double(state >> 11) / Double(1 << 53) // 0 ..< 1
        return (unit * 2 - 1) * bound
    }
}
