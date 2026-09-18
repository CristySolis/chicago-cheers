import Foundation
import Combine

/// The cheers this phone is carrying, grouped by mile.
///
/// Holds a `CheerSource` rather than reading files itself, so replacing the
/// folder with the submission site's database later is a change of one
/// initialiser argument.
@MainActor
final class CheerLibrary: ObservableObject {

    @Published private(set) var cheers: [Cheer] = []
    @Published private(set) var isLoading = false
    @Published private(set) var problem: String?

    private let source: CheerSource

    init(source: CheerSource = LocalFolderSource()) {
        self.source = source
    }

    var sourceDescription: String { source.describedAs }

    var count: Int { cheers.count }

    var claimedMiles: [Double] {
        Array(Set(cheers.map(\.mile))).sorted()
    }

    /// Cheers whose audio never made it onto the phone. Must be zero before the
    /// start — each one is a supporter whose recording would simply not play.
    var missingAudio: [Cheer] {
        cheers.filter { !$0.isReadyForRace }
    }

    func cheers(forMile mile: Double) -> [Cheer] {
        cheers.filter { $0.mile == mile }
    }

    /// Only ever hands back cheers whose audio is already on disk, so the race
    /// itself never waits on a network.
    func readyCheers(forMile mile: Double) -> [Cheer] {
        cheers(forMile: mile).filter(\.isReadyForRace)
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await source.fetchCheers()
            cheers = try await source.makeAvailableOffline(fetched)
            problem = nil
        } catch {
            problem = "Couldn't load recordings: \(error.localizedDescription)"
        }
    }
}
