import CoreLocation
import Foundation
import Testing
@testable import CheerRelay

/// The log is only useful if it opens cleanly in a spreadsheet afterwards, so
/// its exact shape is pinned down here.
struct RaceLogTests {

    private let start = Date(timeIntervalSince1970: 1_791_720_000) // 2026-10-11 12:00:00 UTC

    @Test func eventsCarryTheTimeOfDayRaceClockAndDistance() {
        let line = RaceLogFormat.eventLine(
            time: start.addingTimeInterval(6730.5), raceClock: 6730.5, event: "cheer",
            mile: 13.5, metres: 21_726.1, detail: "Mum")

        #expect(line == "2026-10-11T13:52:10.500Z,6730.5,1:52:10,cheer,13.5,21726.1,13.500,Mum")
        #expect(fields(line).count == fields(RaceLogFormat.eventsHeader).count)
    }

    @Test func eventsBeforeTheRaceHaveNoClock() {
        let line = RaceLogFormat.eventLine(time: start, raceClock: nil, event: "app_launch",
                                           mile: nil, metres: 0, detail: nil)
        #expect(line == "2026-10-11T12:00:00.000Z,,,app_launch,,0.0,0.000,")
    }

    @Test func namesWithCommasOrQuotesStayInOneColumn() {
        #expect(RaceLogFormat.field("Mum, Dad") == "\"Mum, Dad\"")
        #expect(RaceLogFormat.field("The \"Hype\" Man") == "\"The \"\"Hype\"\" Man\"")
        #expect(RaceLogFormat.field("Tete") == "Tete")
    }

    @Test func gpsLinesRecordTheFixAndWhatHappenedToIt() {
        let fix = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 41.875_612_3, longitude: -87.624_401_9),
            altitude: 180, horizontalAccuracy: 4.8, verticalAccuracy: -1,
            course: -1, courseAccuracy: -1, speed: 3.12, speedAccuracy: 0.3,
            timestamp: start.addingTimeInterval(61))

        let line = RaceLogFormat.gpsLine(fix: fix, raceClock: 61, outcome: .counted(step: 3.1),
                                         metres: 190.4)

        #expect(line == "2026-10-11T12:01:01.000Z,61.0,41.875612,-87.624402,4.8,3.12,0.30,counted,3.10,190.4,0.118")
        #expect(fields(line).count == fields(RaceLogFormat.gpsHeader).count)
    }

    @Test func aFixWithoutSpeedLeavesThoseColumnsEmpty() {
        let fix = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 41.9, longitude: -87.6),
            altitude: 0, horizontalAccuracy: 40, verticalAccuracy: -1,
            course: -1, courseAccuracy: -1, speed: -1, speedAccuracy: -1, timestamp: start)

        let columns = fields(RaceLogFormat.gpsLine(fix: fix, raceClock: 0, outcome: .imprecise,
                                                   metres: 0))
        #expect(columns[5] == "" && columns[6] == "")
        #expect(columns[7] == "imprecise")
        #expect(columns[8] == "")
    }

    @Test(arguments: [
        (0.0, "0:00"),
        (7, "0:07"),
        (725, "12:05"),
        (6730, "1:52:10"),
        (-3, "0:00"),
    ])
    func theRaceClockReadsLikeAStopwatch(seconds: TimeInterval, text: String) {
        #expect(RaceClock.text(seconds) == text)
    }

    @Test func paceIsMinutesPerMileOnceThereIsDistance() {
        #expect(RaceClock.pace(seconds: 6730, miles: 13.1) == "8:33")
        #expect(RaceClock.pace(seconds: 30, miles: 0.05) == nil)
    }

    private func fields(_ line: String) -> [String] {
        line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }
}
