import SwiftUI

struct ContentView: View {
    @EnvironmentObject var relay: WatchRelay
    @StateObject private var poller = SheetPoller()
    @State private var received: [CheerMessage] = []

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                statusRow

                if let error = relay.lastSendError {
                    Text(error).foregroundColor(.red).font(.footnote)
                }

                List(received.reversed()) { msg in
                    VStack(alignment: .leading) {
                        Text(msg.sender).font(.headline)
                        Text(msg.text).font(.body)
                    }
                }

                Button("Send test cheer") {
                    let test = CheerMessage(id: UUID().uuidString, sender: "Test",
                                             text: "GO CRISTY GO! 🎉", timestamp: Date())
                    relay.send(test)
                    received.append(test)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Chicago Cheer Squad")
            .onAppear {
                relay.initializeSDK()
                poller.onNewMessages = { fresh in
                    for msg in fresh {
                        relay.send(msg)
                        received.append(msg)
                    }
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
