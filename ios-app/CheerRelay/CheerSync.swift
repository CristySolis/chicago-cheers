import Foundation
import Combine

/// Signs the runner in, and brings her recordings down from the server.
///
/// Sync is a deliberate step taken before the race, never during it: once it
/// has run, the race reads only what it saved to disk.
@MainActor
final class CheerSync: ObservableObject {

    enum State: Equatable {
        case idle
        case syncing(done: Int, total: Int)
        case finished(count: Int, failed: Int)
        case failed(String)
    }

    @Published private(set) var isSignedIn: Bool
    @Published private(set) var state: State = .idle
    @Published private(set) var lastSynced: Date?

    private let api: ApiClient
    private static let lastSyncedKey = "sync.lastSynced"

    init(api: ApiClient) {
        self.api = api
        isSignedIn = SessionStore.refreshToken != nil
        lastSynced = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date
    }

    /// Nil when signed in; otherwise a message to show.
    func signIn(email: String, password: String) async -> String? {
        do {
            let tokens = try await api.signIn(email: email, password: password)
            SessionStore.save(refreshToken: tokens.refreshToken)
            isSignedIn = true
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func signOut() {
        SessionStore.clear()
        isSignedIn = false
    }

    func sync() async {
        guard let refreshToken = SessionStore.refreshToken else {
            isSignedIn = false
            return
        }
        state = .syncing(done: 0, total: 0)

        do {
            let tokens = try await api.refresh(refreshToken)
            // Save the replacement before using the session it came with: the
            // provider may revoke everything if the old token is used again.
            SessionStore.save(refreshToken: tokens.refreshToken)

            guard let event = try await api.events(accessToken: tokens.accessToken).first else {
                state = .failed("No race is set up for this account yet.")
                return
            }
            let remote = try await api.cheers(accessToken: tokens.accessToken, eventID: event.id)

            let directory = SyncedCheerSource.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            var entries: [SyncedCheerSource.Entry] = []
            var failed = 0
            for (index, cheer) in remote.enumerated() {
                state = .syncing(done: index, total: remote.count)
                let file = "\(cheer.id.uuidString.lowercased()).wav"
                let destination = directory.appending(path: file)

                // A finished recording can never change on the server, so one
                // already on the phone is kept rather than fetched again.
                if !FileManager.default.fileExists(atPath: destination.path) {
                    do {
                        try await api.download(cheer.downloadUrl, to: destination)
                    } catch {
                        failed += 1
                        continue
                    }
                }
                entries.append(.init(id: cheer.id, mile: cheer.slot.value,
                                     sender: cheer.senderName, file: file))
            }

            // Only the manifest decides what plays. Files it no longer names are
            // left in place rather than deleted, so a bad answer from the server
            // can never destroy recordings the phone already holds.
            let manifest = try JSONEncoder().encode(entries)
            try manifest.write(to: SyncedCheerSource.manifestURL, options: .atomic)

            let now = Date()
            lastSynced = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncedKey)
            state = .finished(count: entries.count, failed: failed)

        } catch let failure as ApiClient.Failure where failure.needsSignIn {
            signOut()
            state = .failed(failure.localizedDescription)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
