import Foundation

/// Everything that has to be right before the start, read off the phone at one
/// moment. Plain values so the rules below can be tested without a phone.
nonisolated struct ReadinessSnapshot {

    enum LocationAccess: Equatable {
        case notAsked, denied, approximate, allowed
    }

    enum Output: Equatable {
        case headphones(name: String)
        case speaker
    }

    var location: LocationAccess
    var isSignedIn: Bool
    var cheersOnPhone: Int
    var cheersMissingAudio: Int
    var lastSynced: Date?
    /// 0 to 1, or nil where the phone can't say (the simulator).
    var batteryLevel: Double?
    var output: Output
    /// 0 to 1.
    var volume: Double
    var now: Date
}

nonisolated struct ReadinessItem: Identifiable, Equatable {

    enum Area: String {
        case location, cheers, battery, sound
    }

    enum Status: Int, Comparable {
        case ready, warning, problem
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    /// The one-tap fix offered next to an item.
    enum Fix: Equatable {
        case allowLocation, openSettings, sync
    }

    let area: Area
    let status: Status
    let title: String
    let detail: String
    var fix: Fix?

    var id: Area { area }
}

/// The race-morning checklist.
///
/// A problem means cheers won't play (or not at the right place); a warning
/// means they'll play but something is worth a look — quiet, on the speaker,
/// a battery that may not last.
nonisolated enum Readiness {

    /// Cheers recorded after this long since the last sync may be missing.
    static let staleSync: TimeInterval = 12 * 3600
    static let fullBattery = 0.9
    static let lowBattery = 0.6
    static let quiet = 0.25

    static func check(_ s: ReadinessSnapshot) -> [ReadinessItem] {
        [location(s), cheers(s), battery(s), sound(s)]
    }

    static func summary(of items: [ReadinessItem]) -> (status: ReadinessItem.Status, text: String) {
        let problems = items.filter { $0.status == .problem }.count
        let warnings = items.filter { $0.status == .warning }.count
        if problems > 0 { return (.problem, "\(problems) to fix before the start") }
        if warnings > 0 { return (.warning, "\(warnings) \(warnings == 1 ? "thing" : "things") to check") }
        return (.ready, "Ready to race")
    }

    // MARK: - The checks

    private static func location(_ s: ReadinessSnapshot) -> ReadinessItem {
        switch s.location {
        case .allowed:
            return ReadinessItem(area: .location, status: .ready,
                                 title: "Location allowed",
                                 detail: "Distance is measured by GPS.")
        case .notAsked:
            return ReadinessItem(area: .location, status: .problem,
                                 title: "Location not allowed yet",
                                 detail: "No cheer can play without it. Tap Allow, then Allow While Using App.",
                                 fix: .allowLocation)
        case .denied:
            return ReadinessItem(area: .location, status: .problem,
                                 title: "Location is off for this app",
                                 detail: "No cheer can play without it. Turn it on in Settings.",
                                 fix: .openSettings)
        case .approximate:
            return ReadinessItem(area: .location, status: .problem,
                                 title: "Precise Location is off",
                                 detail: "Approximate location can't measure distance. In Settings, under Location, turn on Precise Location.",
                                 fix: .openSettings)
        }
    }

    private static func cheers(_ s: ReadinessSnapshot) -> ReadinessItem {
        if s.cheersMissingAudio > 0 {
            let n = s.cheersMissingAudio
            return ReadinessItem(area: .cheers, status: .problem,
                                 title: "\(n) \(n == 1 ? "cheer" : "cheers") not downloaded",
                                 detail: "\(n == 1 ? "It" : "They") won't play. Tap Sync, ideally on Wi-Fi.",
                                 fix: .sync)
        }
        guard s.isSignedIn else {
            return ReadinessItem(area: .cheers, status: .warning,
                                 title: "Not signed in",
                                 detail: "Sign in at the top right, then Sync to download your cheers.")
        }
        guard let synced = s.lastSynced else {
            return ReadinessItem(area: .cheers, status: .warning,
                                 title: "Never synced",
                                 detail: "Tap Sync to download your cheers.",
                                 fix: .sync)
        }
        let age = s.now.timeIntervalSince(synced)
        if s.cheersOnPhone == 0 {
            return ReadinessItem(area: .cheers, status: .warning,
                                 title: "No cheers on the phone",
                                 detail: "Last synced \(ago(age)). Sync again once supporters have recorded.",
                                 fix: .sync)
        }
        let count = "\(s.cheersOnPhone) \(s.cheersOnPhone == 1 ? "cheer" : "cheers")"
        if age > staleSync {
            return ReadinessItem(area: .cheers, status: .warning,
                                 title: "\(count), last synced \(ago(age))",
                                 detail: "Sync again to pick up any recorded since.",
                                 fix: .sync)
        }
        return ReadinessItem(area: .cheers, status: .ready,
                             title: "\(count) ready",
                             detail: "Synced \(ago(age)).")
    }

    private static func battery(_ s: ReadinessSnapshot) -> ReadinessItem {
        guard let level = s.batteryLevel else {
            return ReadinessItem(area: .battery, status: .warning,
                                 title: "Battery level unknown",
                                 detail: "Start the race fully charged.")
        }
        let percent = "\(Int((level * 100).rounded()))%"
        if level >= fullBattery {
            return ReadinessItem(area: .battery, status: .ready,
                                 title: "Battery \(percent)",
                                 detail: "Enough for the whole race.")
        }
        return ReadinessItem(area: .battery,
                             status: level < lowBattery ? .problem : .warning,
                             title: "Battery \(percent)",
                             detail: "GPS and audio for four-plus hours use a lot. Charge to full before the start.")
    }

    private static func sound(_ s: ReadinessSnapshot) -> ReadinessItem {
        let quiet = s.volume < Self.quiet
        switch s.output {
        case .speaker:
            return ReadinessItem(area: .sound, status: .warning,
                                 title: "No headphones connected",
                                 detail: "Cheers would play from the phone's speaker"
                                    + (quiet ? ", and the volume is low." : "."))
        case .headphones(let name):
            return ReadinessItem(area: .sound, status: quiet ? .warning : .ready,
                                 title: "Playing through \(name)",
                                 detail: quiet
                                    ? "The volume is low. Turn it up so cheers carry over the crowd."
                                    : "Play the test sound to hear how a cheer comes through.")
        }
    }

    /// "just now", "5 min ago", "3 h ago", "2 days ago".
    static func ago(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default:
            let days = Int(seconds / 86_400)
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
    }
}
