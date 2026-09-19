import Foundation

/// Where placed cheers come from.
///
/// Today that's the recordings Sync brought down from the server. Another
/// source would mean one new conformer and one changed line in the app — not
/// touching the race screen, the player or the tracker.
///
/// Everything above this protocol deals only in `Cheer` values whose audio is
/// already on the device. How it got there is this layer's problem.
protocol CheerSource {

    /// Shown in the UI so it is never ambiguous which source is live.
    var describedAs: String { get }

    /// The catalogue of placed cheers. May reference audio that hasn't been
    /// downloaded yet, so callers must not assume `localURL` is set.
    func fetchCheers() async throws -> [Cheer]

    /// Brings every cheer's audio onto the device, returning them with
    /// `localURL` populated.
    ///
    /// This is deliberately a separate step from fetching. On race day the
    /// phone is in an armband on a saturated network, so downloads must happen
    /// beforehand — the run itself reads from disk and nothing else.
    func makeAvailableOffline(_ cheers: [Cheer]) async throws -> [Cheer]
}
