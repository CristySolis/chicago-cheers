import Foundation

/// Polls a published Google Sheet (as CSV) for new rows and reports any
/// messages not seen before. Expects columns: Timestamp, Sender, Message
/// (this is exactly what a Google Form's response sheet looks like with
/// two short-answer questions, "Name" and "Message").
final class SheetPoller {

    private(set) var seenIds = Set<String>()
    private var timer: Timer?

    /// Called on the main thread with any new messages, oldest first.
    var onNewMessages: (([CheerMessage]) -> Void)?

    func start() {
        stop()
        fetchOnce() // don't wait a full interval for the first check
        timer = Timer.scheduledTimer(withTimeInterval: Config.pollInterval, repeats: true) { [weak self] _ in
            self?.fetchOnce()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func fetchOnce() {
        let request = URLRequest(url: Config.sheetCSVURL, cachePolicy: .reloadIgnoringLocalCacheData)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self, let data, error == nil,
                  let csv = String(data: data, encoding: .utf8) else { return }

            let rows = Self.parseCSV(csv)
            var fresh: [CheerMessage] = []

            for row in rows {
                guard row.count >= 3 else { continue }
                let timestampRaw = row[0]
                let sender = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let text = row[2].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sender.isEmpty, !text.isEmpty else { continue }

                // Stable id: content hash, so re-fetching the same sheet
                // never re-sends a message we already relayed.
                let id = "\(timestampRaw)|\(sender)|\(text)".sha1Short()
                guard !self.seenIds.contains(id) else { continue }

                self.seenIds.insert(id)
                fresh.append(CheerMessage(id: id, sender: sender, text: text, timestamp: Date()))
            }

            guard !fresh.isEmpty else { return }
            DispatchQueue.main.async {
                self.onNewMessages?(fresh)
            }
        }.resume()
    }

    /// Minimal CSV parser: handles quoted fields with embedded commas, which
    /// Google Sheets' CSV export uses whenever a cheer message contains a comma.
    private static func parseCSV(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var iterator = csv.makeIterator()

        while let ch = iterator.next() {
            if inQuotes {
                if ch == "\"" {
                    inQuotes = false
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); field = ""; rows.append(row); row = []
                case "\r": break
                default: field.append(ch)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        // Drop the header row.
        return rows.isEmpty ? [] : Array(rows.dropFirst())
    }
}

import CryptoKit
extension String {
    func sha1Short() -> String {
        let digest = Insecure.SHA1.hash(data: Data(self.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }
}
