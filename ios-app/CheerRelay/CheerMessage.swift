import Foundation

struct CheerMessage: Identifiable, Equatable {
    let id: String       // stable id derived from row content, used for de-duping
    let sender: String
    let text: String
    let timestamp: Date

    var payload: [String: Any] {
        ["id": id, "sender": sender, "text": text]
    }
}
