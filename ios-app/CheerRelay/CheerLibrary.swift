import Foundation
import Combine

/// The recordings waiting on disk, indexed by the mile they were claimed for.
///
/// Files live in the app's Documents folder so they can be added from Finder or
/// the Files app without a rebuild — which matters because the recordings are
/// gathered in the week before the race, long after the app is installed.
///
/// A file belongs to whichever mile its name starts with: "18.m4a",
/// "18-mum.m4a" and "18 tete.wav" all play at mile 18. More than one file may
/// claim the same mile, which happens once all 26 are taken and people start
/// doubling up.
final class CheerLibrary: ObservableObject {

    @Published private(set) var byMile: [Int: [URL]] = [:]

    private static let playableExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "caf", "aiff", "mp4"
    ]

    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init() {
        reload()
    }

    var count: Int { byMile.values.reduce(0) { $0 + $1.count } }

    var claimedMiles: [Int] { byMile.keys.sorted() }

    func recordings(forMile mile: Int) -> [URL] {
        byMile[mile] ?? []
    }

    func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.documentsURL,
            includingPropertiesForKeys: nil
        )) ?? []

        var found: [Int: [URL]] = [:]
        for url in contents {
            guard Self.playableExtensions.contains(url.pathExtension.lowercased()),
                  let mile = Self.mile(fromFileName: url.lastPathComponent)
            else { continue }
            found[mile, default: []].append(url)
        }

        // Stable order so a doubled-up mile always plays in the same sequence.
        byMile = found.mapValues { $0.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    }

    private static func mile(fromFileName name: String) -> Int? {
        let digits = name.prefix { $0.isNumber }
        guard let mile = Int(digits), (1...RaceTracker.finalMile).contains(mile) else { return nil }
        return mile
    }
}
