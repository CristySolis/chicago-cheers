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
/// A file belongs to whichever slot its name begins with: "18-mum.m4a" plays at
/// mile 18, "20.5 tete.wav" at mile 20.5. Half miles only exist after mile 13,
/// so "7.5-x" is ignored. Several files may share a slot, which is what happens
/// once every slot is claimed and people double up.
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

    /// Reads the number from the name without its extension — otherwise the
    /// dot in "18.m4a" looks like part of "18.".
    private static func mile(fromFileName name: String) -> Double? {
        let stem = (name as NSString).deletingPathExtension
        let number = stem.prefix { $0.isNumber || $0 == "." }
        guard let mile = Double(number), Course.isSlot(mile) else { return nil }
        return mile
    }

    /// "18-mum.m4a" gives "mum"; a bare "18.m4a" gives nothing.
    private static func sender(fromFileName name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        let remainder = stem.drop { $0.isNumber || $0 == "." }
            .drop { $0 == "-" || $0 == "_" || $0 == " " }
        let trimmed = remainder.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
