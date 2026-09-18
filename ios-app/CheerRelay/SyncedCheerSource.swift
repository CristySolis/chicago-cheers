import Foundation

/// The recordings Sync brought down, read back from disk. This is what the race
/// runs on: it never touches the network, so it behaves the same in a dead zone
/// on Michigan Avenue as it did on the sofa the night before.
///
/// Files live in Application Support rather than Caches, because iOS may empty
/// Caches when storage runs low — and the night before a marathon is exactly
/// when that must not happen.
nonisolated struct SyncedCheerSource: CheerSource {

    struct Entry: Codable {
        let id: UUID
        let mile: Double
        let sender: String
        let file: String
    }

    var describedAs: String { "Synced from the server" }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SyncedCheers", directoryHint: .isDirectory)
    }

    static var manifestURL: URL {
        directory.appending(path: "manifest.json")
    }

    func fetchCheers() async throws -> [Cheer] {
        guard let data = try? Data(contentsOf: Self.manifestURL) else {
            return [] // never synced yet
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries
            .filter { Course.isSlot($0.mile) }
            .map { entry in
                let file = Self.directory.appending(path: entry.file)
                return Cheer(
                    id: entry.id.uuidString,
                    mile: entry.mile,
                    sender: entry.sender,
                    localURL: FileManager.default.fileExists(atPath: file.path) ? file : nil,
                    remoteURL: nil)
            }
            .sorted { ($0.mile, $0.id) < ($1.mile, $1.id) }
    }

    /// Already on disk by definition; Sync is what put it there.
    func makeAvailableOffline(_ cheers: [Cheer]) async throws -> [Cheer] { cheers }
}
