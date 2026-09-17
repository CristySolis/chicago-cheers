import SwiftUI

struct ContentView: View {
    @EnvironmentObject var relay: WatchRelay
    @StateObject private var poller = SheetPoller()

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                statusRow

                if let error = relay.lastSendError {
                    Text(error).foregroundColor(.red).font(.footnote)
                }

                List(poller.received.reversed()) { msg in
                    VStack(alignment: .leading) {
                        Text(msg.sender).font(.headline)
                        Text(msg.text).font(.body)
                    }
                }

                Button("Send test cheer") {
                    let test = CheerMessage(id: UUID().uuidString, sender: "Test",
                                             text: "GO CRISTY GO! 🎉", timestamp: Date())
                    relay.send(test)
                    poller.received.append(test)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Chicago Cheer Squad")
            .onAppear {
                relay.initializeSDK()
                let watch = relay // capture the object, not this view struct
                poller.onNewMessages = { fresh in
                    fresh.forEach(watch.send)
                }
                poller.start()
            }
        }
    }

    private var statusRow: some View {
        HStack {
            Circle()
                .fill(relay.connectedDeviceName != nil ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
            Text(relay.connectedDeviceName ?? "No watch connected")
            Spacer()
            Button(relay.connectedDeviceName == nil ? "Connect" : "Change") {
                relay.selectDevice()
            }
        }
    }
}
