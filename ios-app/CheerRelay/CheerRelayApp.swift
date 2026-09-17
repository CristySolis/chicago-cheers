import SwiftUI

@main
struct CheerRelayApp: App {
    @StateObject private var relay = WatchRelay()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(relay)
                .onOpenURL { url in
                    relay.handle(url: url)
                }
        }
    }
}
