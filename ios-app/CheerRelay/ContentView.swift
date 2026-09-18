import SwiftUI

struct ContentView: View {
    @EnvironmentObject var relay: WatchRelay
    @StateObject private var poller = SheetPoller()
    @StateObject private var speaker = CheerSpeaker()

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                statusRow

                if let error = speaker.audioError ?? relay.lastSendError {
                    Text(error).foregroundColor(.red).font(.footnote)
                }

                List(poller.received.reversed()) { msg in
                    VStack(alignment: .leading) {
                        Text(msg.sender).font(.headline)
                        Text(msg.text).font(.body)
                    }
                }

                Button("Speak test cheer") {
                    let test = CheerMessage(id: UUID().uuidString, sender: "Test",
                                             text: "GO CRISTY GO! 🎉", timestamp: Date())
                    speaker.speak(test)
                    relay.send(test)
                    poller.received.append(test)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Chicago Cheer Squad")
            .onAppear {
                relay.initializeSDK()
                speaker.start()
                // capture the objects, not this view struct
                let watch = relay
                let voice = speaker
                poller.onNewMessages = { fresh in
                    for msg in fresh {
                        voice.speak(msg)
                        watch.send(msg)
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
