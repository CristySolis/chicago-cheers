import Foundation

enum Config {
    // The UUID from watch-app/manifest.xml's <iq:application id="...">.
    // Must match EXACTLY or the watch will never receive messages.
    static let watchAppId = "d4d1e0d2-8f2b-4c1a-9c2e-1a2b3c4d5e6f"

    // Any UUID works here for a sideloaded (non-Store) app — it's only
    // meaningful for apps published to the Connect IQ Store.
    static let watchAppStoreId = "00000000-0000-0000-0000-000000000000"

    // Custom URL scheme this app registers (must also be added to
    // Info.plist's CFBundleURLTypes) so Garmin Connect Mobile can hand
    // control back after device selection.
    static let urlScheme = "cheersquad"

    // The published Google Sheet CSV URL (File > Share > Publish to web,
    // pick the response sheet, format CSV). Expected columns, in order:
    // Timestamp, Sender, Message
    static let sheetCSVURL = URL(string: "https://docs.google.com/spreadsheets/d/e/PASTE_YOUR_PUBLISHED_ID_HERE/pub?output=csv")!

    // How often to check the sheet for new rows.
    static let pollInterval: TimeInterval = 15
}
