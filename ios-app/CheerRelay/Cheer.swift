import Foundation

/// One supporter's recording, placed at a mile.
struct Cheer: Identifiable, Equatable {

    let id: String

    /// A slot on the course: whole miles, or half miles after mile 13.
    let mile: Double

    /// Who recorded it.
    let sender: String?

    /// Where the audio is on this device. Nil means it still has to be fetched.
    var localURL: URL?

    /// Nothing is downloaded during the race, so a cheer is only usable once
    /// its audio is sitting on the phone.
    var isReadyForRace: Bool { localURL != nil }

    var label: String {
        sender ?? localURL?.deletingPathExtension().lastPathComponent ?? id
    }
}
