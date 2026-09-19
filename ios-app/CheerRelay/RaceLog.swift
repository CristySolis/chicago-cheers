import Foundation
import CoreLocation

/// Two CSV files per race, written as it happens, for looking back afterwards:
///
/// - `events.csv`: the race starting and stopping, every course slot passed,
///   every cheer as it starts playing, battery every few minutes, gaps in the
///   GPS and app restarts. Comparing a cheer's time against pace or official
///   splits shows how far off the distance was at that moment.
/// - `gps.csv`: every fix, whether it was counted (and if not, why), and the
///   distance so far — enough to replay the run and test changes to the
///   distance maths against real data.
///
/// Every line is written the moment it happens, so a crash loses nothing
/// already logged. Files live under Documents/RaceLogs, visible in the Files
/// app under On My iPhone → CheerRelay.
@MainActor
final class RaceLog {

    private(set) var folder: URL?

    /// Only the folder's name is remembered, never its full path: iOS moves an
    /// app's files to a new path when the app is reinstalled or updated.
    private static let folderKey = "race.logFolderName"

    private static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RaceLogs", isDirectory: true)
    }

    init() {
        if let name = UserDefaults.standard.string(forKey: Self.folderKey) {
            let folder = Self.root.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                self.folder = folder
            }
        }
    }

    /// The race's files, once it has started — for sharing afterwards.
    var files: [URL] {
        guard let folder else { return [] }
        return [folder.appendingPathComponent("events.csv"), folder.appendingPathComponent("gps.csv")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Starts a new pair of files, named after when the race began.
    func begin(at start: Date) {
        let name = RaceLogFormat.folderName(for: start)
        let folder = Self.root.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try (RaceLogFormat.eventsHeader + "\n").write(
                to: folder.appendingPathComponent("events.csv"), atomically: true, encoding: .utf8)
            try (RaceLogFormat.gpsHeader + "\n").write(
                to: folder.appendingPathComponent("gps.csv"), atomically: true, encoding: .utf8)
        } catch {
            // Logging is for afterwards; it must never get in the way of the race.
            return
        }
        self.folder = folder
        UserDefaults.standard.set(name, forKey: Self.folderKey)
    }

    func event(_ name: String, at time: Date, raceClock: TimeInterval?, mile: Double? = nil,
               metres: Double, detail: String? = nil) {
        append(RaceLogFormat.eventLine(time: time, raceClock: raceClock, event: name,
                                       mile: mile, metres: metres, detail: detail),
               to: "events.csv")
    }

    func fix(_ fix: CLLocation, raceClock: TimeInterval?, outcome: DistanceMeter.Outcome, metres: Double) {
        append(RaceLogFormat.gpsLine(fix: fix, raceClock: raceClock, outcome: outcome, metres: metres),
               to: "gps.csv")
    }

    private func append(_ line: String, to file: String) {
        guard let folder,
              let handle = try? FileHandle(forWritingTo: folder.appendingPathComponent(file))
        else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

/// The text of the log, kept apart from the files so it can be tested.
nonisolated enum RaceLogFormat {

    static let eventsHeader = "time_utc,race_clock_s,race_clock,event,mile,distance_m,distance_mi,detail"
    static let gpsHeader = "time_utc,race_clock_s,latitude,longitude,accuracy_m,speed_mps,speed_accuracy_mps,outcome,step_m,distance_m,distance_mi"

    static func eventLine(time: Date, raceClock: TimeInterval?, event: String, mile: Double?,
                          metres: Double, detail: String?) -> String {
        [
            timestamp(time),
            raceClock.map { decimal($0, places: 1) } ?? "",
            raceClock.map(RaceClock.text) ?? "",
            event,
            mile.map { decimal($0, places: 1) } ?? "",
            decimal(metres, places: 1),
            decimal(metres / Course.metresPerMile, places: 3),
            field(detail ?? ""),
        ].joined(separator: ",")
    }

    static func gpsLine(fix: CLLocation, raceClock: TimeInterval?, outcome: DistanceMeter.Outcome,
                        metres: Double) -> String {
        let step: Double? = switch outcome {
        case .counted(let step), .tooFast(let step): step
        default: nil
        }
        return [
            timestamp(fix.timestamp),
            raceClock.map { decimal($0, places: 1) } ?? "",
            decimal(fix.coordinate.latitude, places: 6),
            decimal(fix.coordinate.longitude, places: 6),
            decimal(fix.horizontalAccuracy, places: 1),
            fix.speed >= 0 ? decimal(fix.speed, places: 2) : "",
            fix.speedAccuracy >= 0 ? decimal(fix.speedAccuracy, places: 2) : "",
            outcome.logName,
            step.map { decimal($0, places: 2) } ?? "",
            decimal(metres, places: 1),
            decimal(metres / Course.metresPerMile, places: 3),
        ].joined(separator: ",")
    }

    /// "2026-10-11 07.30" — sorts by date in the Files app.
    static func folderName(for start: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        return String(format: "%04d-%02d-%02d %02d.%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// UTC, to the millisecond, so lines from both files line up exactly.
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Quoted when needed, so a supporter called "Mum, Dad" stays one field.
    static func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// How the race clock and pace read on screen and in the log.
nonisolated enum RaceClock {

    /// "0:07", "12:05", "1:52:10".
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Average minutes per mile, "8:34", or nil before there's enough to say.
    static func pace(seconds: TimeInterval, miles: Double) -> String? {
        guard miles >= 0.1, seconds > 0 else { return nil }
        return text(seconds / miles)
    }
}
