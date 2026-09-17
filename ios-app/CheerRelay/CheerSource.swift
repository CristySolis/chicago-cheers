import Foundation

/// Where placed cheers come from.
///
/// Today that's a folder on the phone, filled by hand. For the real race it
/// will be the submission site's database, and swapping between them should
/// mean writing one new conformer and changing one line in the app — not
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

/// Reads whatever audio has been dropped into the app's Documents folder.
///
/// A file belongs to whichever mile its name begins with, so "18.m4a",
/// "18-mum.m4a" and "18 tete.wav" all play at mile 18. Several files may share
/// a mile, which is what happens once all 26 are claimed and people double up.
nonisolated struct LocalFolderSource: CheerSource {

    var describedAs: String { "Files on this phone" }

    static let playableExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "caf", "aiff", "mp4"
    ]

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func fetchCheers() async throws -> [Cheer] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: Self.documentsURL,
            includingPropertiesForKeys: nil
        )

        return contents
            .filter { Self.playableExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                guard let mile = Self.mile(fromFileName: url.lastPathComponent) else { return nil }
                return Cheer(id: url.lastPathComponent,
                             mile: mile,
                             sender: Self.sender(fromFileName: url.lastPathComponent),
                             localURL: url,
                             remoteURL: nil)
            }
            // Stable order, so a doubled-up mile always plays in the same sequence.
            .sorted { ($0.mile, $0.id) < ($1.mile, $1.id) }
    }

    /// Already local by definition.
    func makeAvailableOffline(_ cheers: [Cheer]) async throws -> [Cheer] { cheers }

    private static func mile(fromFileName name: String) -> Int? {
        let digits = name.prefix { $0.isNumber }
        guard let mile = Int(digits), (1...RaceTracker.finalMile).contains(mile) else { return nil }
        return mile
    }

    /// "18-mum.m4a" gives "mum"; a bare "18.m4a" gives nothing.
    private static func sender(fromFileName name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        let remainder = stem.drop { $0.isNumber }
            .drop { $0 == "-" || $0 == "_" || $0 == " " }
        let trimmed = remainder.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
