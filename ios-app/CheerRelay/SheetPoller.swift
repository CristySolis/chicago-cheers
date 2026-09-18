import Foundation
import Combine

/// Polls a published Google Sheet (as CSV) for new rows and reports any
/// messages not seen before. Expects columns: Timestamp, Sender, Message
/// (this is exactly what a Google Form's response sheet looks like with
/// two short-answer questions, "Name" and "Message").
final class SheetPoller: ObservableObject {

    private(set) var seenIds = Set<String>()
    private var timer: Timer?

    /// Every cheer seen this session, oldest first. Owned here rather than in the
    /// view: a closure captured once in .onAppear writes to a @State location
    /// SwiftUI has already discarded, so appends from it are silently lost.
    @Published var received: [CheerMessage] = []

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
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            // Google serves an HTML error/login page on a bad or unpublished
            // URL. Parsing that as CSV relays page markup to the watch as
            // cheers, so only accept an actual CSV 200.
            guard let self, let data, error == nil,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.mimeType?.hasPrefix("text/csv") == true,
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
                self.received.append(contentsOf: fresh)
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
                // Swift treats CRLF as one Character, so "\r\n" must be matched
                // explicitly — Google's CSV export uses it and would otherwise
                // never terminate a row.
                case "\n", "\r\n": row.append(field); field = ""; rows.append(row); row = []
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
