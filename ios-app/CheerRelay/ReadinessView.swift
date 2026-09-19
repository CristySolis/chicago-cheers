import SwiftUI
import UIKit
import AVFoundation

/// The race-morning checklist: open it at the start line, fix anything red,
/// then press Start.
struct ReadinessView: View {
    @ObservedObject var tracker: RaceTracker
    @ObservedObject var library: CheerLibrary
    @ObservedObject var sync: CheerSync
    @ObservedObject var player: CheerPlayer
    let runSync: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationView {
            // Battery, headphones and volume change without telling the app,
            // so the list is simply re-read every second while it's open.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let items = Readiness.check(.current(tracker: tracker, library: library,
                                                     sync: sync, now: context.date))
                List {
                    Section {
                        ForEach(items) { row($0) }
                    } footer: {
                        Text(Readiness.summary(of: items).text)
                    }

                    Section {
                        Button {
                            player.playSoundCheck()
                        } label: {
                            Label("Play test sound", systemImage: "speaker.wave.2")
                        }
                        .disabled(player.nowPlaying != nil)
                    } footer: {
                        Text("Start your music first: it should dip while the beeps play, just as it will for each cheer.")
                    }
                }
            }
            .navigationTitle("Ready to race?")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ item: ReadinessItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.status.symbol)
                .foregroundColor(item.status.color)
                .font(.title3)
                .accessibilityLabel(item.status.spoken)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = item.fix {
                    fixButton(fix)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func fixButton(_ fix: ReadinessItem.Fix) -> some View {
        switch fix {
        case .allowLocation:
            Button("Allow") { tracker.askForLocation() }
        case .openSettings:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        case .sync:
            if case .syncing = sync.state {
                ProgressView()
            } else {
                Button("Sync") { Task { await runSync() } }
                    .disabled(!sync.isSignedIn || tracker.isRunning)
            }
        }
    }
}

extension ReadinessItem.Status {
    var symbol: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .warning: return .orange
        case .problem: return .red
        }
    }

    var spoken: String {
        switch self {
        case .ready: return "Ready"
        case .warning: return "Check"
        case .problem: return "Needs fixing"
        }
    }
}

extension ReadinessSnapshot {

    /// Reads the phone as it is right now.
    static func current(tracker: RaceTracker, library: CheerLibrary,
                        sync: CheerSync, now: Date) -> ReadinessSnapshot {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel

        let session = AVAudioSession.sharedInstance()
        let listening: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP]
        let headphones = session.currentRoute.outputs.first { listening.contains($0.portType) }

        return ReadinessSnapshot(
            location: tracker.locationAccess,
            isSignedIn: sync.isSignedIn,
            cheersOnPhone: library.count,
            cheersMissingAudio: library.missingAudio.count,
            lastSynced: sync.lastSynced,
            batteryLevel: level < 0 ? nil : Double(level),
            output: headphones.map { .headphones(name: $0.portName) } ?? .speaker,
            volume: Double(session.outputVolume),
            now: now
        )
    }
}
