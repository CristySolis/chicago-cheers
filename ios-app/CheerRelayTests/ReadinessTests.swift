import Foundation
import Testing
@testable import CheerRelay

/// The race-morning checklist must never call the phone ready when a cheer
/// wouldn't play, so each rule is pinned down here.
struct ReadinessTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A phone that is ready in every way; each test changes one thing.
    private func ready() -> ReadinessSnapshot {
        ReadinessSnapshot(location: .allowed, isSignedIn: true, cheersOnPhone: 12, cheersMissingAudio: 0,
                          lastSynced: now.addingTimeInterval(-600), batteryLevel: 1,
                          output: .headphones(name: "AirPods"), volume: 0.6, now: now)
    }

    private func item(_ area: ReadinessItem.Area, _ s: ReadinessSnapshot) -> ReadinessItem {
        Readiness.check(s).first { $0.area == area }!
    }

    @Test func aFullyPreparedPhoneIsReady() {
        let items = Readiness.check(ready())
        #expect(items.map(\.area) == [.location, .cheers, .battery, .sound])
        #expect(items.allSatisfy { $0.status == .ready })
        #expect(Readiness.summary(of: items).text == "Ready to race")
    }

    // MARK: - Location

    @Test(arguments: [
        (ReadinessSnapshot.LocationAccess.notAsked, ReadinessItem.Fix.allowLocation),
        (.denied, .openSettings),
        (.approximate, .openSettings),
    ])
    func withoutPreciseLocationNothingCanPlay(access: ReadinessSnapshot.LocationAccess,
                                              fix: ReadinessItem.Fix) {
        var s = ready()
        s.location = access
        let location = item(.location, s)
        #expect(location.status == .problem)
        #expect(location.fix == fix)
    }

    // MARK: - Cheers

    @Test func cheersThatDidntDownloadMustBeFixed() {
        var s = ready()
        s.cheersMissingAudio = 2
        let cheers = item(.cheers, s)
        #expect(cheers.status == .problem)
        #expect(cheers.title == "2 cheers not downloaded")
        #expect(cheers.fix == .sync)
    }

    @Test func aRecentSyncIsReady() {
        let cheers = item(.cheers, ready())
        #expect(cheers.status == .ready)
        #expect(cheers.title == "12 cheers ready")
        #expect(cheers.detail == "Synced 10 min ago.")
    }

    @Test func aSyncOverTwelveHoursOldIsWorthRepeating() {
        var s = ready()
        s.lastSynced = now.addingTimeInterval(-13 * 3600)
        let cheers = item(.cheers, s)
        #expect(cheers.status == .warning)
        #expect(cheers.title == "12 cheers, last synced 13 h ago")
    }

    @Test func neverSyncedOrEmptyIsAWarning() {
        var never = ready()
        never.lastSynced = nil
        #expect(item(.cheers, never).title == "Never synced")

        var empty = ready()
        empty.cheersOnPhone = 0
        #expect(item(.cheers, empty).status == .warning)
        #expect(item(.cheers, empty).title == "No cheers on the phone")
    }

    @Test func signedOutSaysToSignInFirst() {
        var s = ready()
        s.isSignedIn = false
        let cheers = item(.cheers, s)
        #expect(cheers.title == "Not signed in")
        #expect(cheers.fix == nil) // Sync can't work until then
    }

    // MARK: - Battery

    @Test(arguments: [
        (1.0, ReadinessItem.Status.ready),
        (0.9, .ready),
        (0.89, .warning),
        (0.6, .warning),
        (0.59, .problem),
    ])
    func batteryNeedsToBeNearlyFull(level: Double, status: ReadinessItem.Status) {
        var s = ready()
        s.batteryLevel = level
        #expect(item(.battery, s).status == status)
    }

    @Test func anUnreadableBatteryIsAWarning() {
        var s = ready()
        s.batteryLevel = nil
        #expect(item(.battery, s).status == .warning)
    }

    // MARK: - Sound

    @Test func theSpeakerInsteadOfHeadphonesIsAWarning() {
        var s = ready()
        s.output = .speaker
        #expect(item(.sound, s).status == .warning)
    }

    @Test func aLowVolumeIsAWarning() {
        var s = ready()
        s.volume = 0.2
        let sound = item(.sound, s)
        #expect(sound.status == .warning)
        #expect(sound.detail.contains("volume is low"))
    }

    // MARK: - Summary

    @Test func theSummaryCountsProblemsBeforeWarnings() {
        var s = ready()
        s.location = .denied
        s.cheersMissingAudio = 1
        s.output = .speaker
        let summary = Readiness.summary(of: Readiness.check(s))
        #expect(summary.status == .problem)
        #expect(summary.text == "2 to fix before the start")

        var w = ready()
        w.output = .speaker
        #expect(Readiness.summary(of: Readiness.check(w)).text == "1 thing to check")
    }

    @Test(arguments: [
        (30.0, "just now"),
        (600, "10 min ago"),
        (3 * 3600, "3 h ago"),
        (86_400, "1 day ago"),
        (3 * 86_400, "3 days ago"),
    ])
    func agesReadNaturally(seconds: TimeInterval, text: String) {
        #expect(Readiness.ago(seconds) == text)
    }
}
