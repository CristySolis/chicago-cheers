import SwiftUI

struct RaceView: View {
    @StateObject private var tracker = RaceTracker()
    @StateObject private var library = CheerLibrary()
    @StateObject private var player = CheerPlayer()

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                distance

                if let message = tracker.problem ?? player.problem {
                    Text(message)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }

                if let playing = player.nowPlaying {
                    Label(playing, systemImage: "speaker.wave.2.fill")
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }

                startStop

                miles
            }
            .padding()
            .navigationTitle("Chicago Cheer Squad")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reload") { library.reload() }
                }
            }
            .onAppear {
                let cheers = library
                let sound = player
                tracker.onMileReached = { mile in
                    sound.play(cheers.recordings(forMile: mile))
                }
            }
        }
    }

    private var distance: some View {
        VStack(spacing: 4) {
            Text(String(format: "%.2f", tracker.milesCovered))
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("miles")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if tracker.isRunning && !tracker.hasFix {
                Label("Waiting for GPS…", systemImage: "location")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }

            if let next = tracker.nextMile {
                Text(library.recordings(forMile: next).isEmpty
                     ? "Next cheer: none placed yet"
                     : "Next cheer at mile \(next)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var startStop: some View {
        HStack(spacing: 12) {
            Button(tracker.isRunning ? "Stop" : "Start") {
                tracker.isRunning ? tracker.stop() : tracker.start()
            }
            .buttonStyle(.borderedProminent)
            .tint(tracker.isRunning ? .red : .accentColor)

            if !tracker.isRunning && tracker.milesCovered > 0 {
                Button("Reset", role: .destructive) { tracker.reset() }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var miles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(library.count) recordings across \(library.claimedMiles.count) miles")
                .font(.footnote)
                .foregroundColor(.secondary)

            List {
                ForEach(library.claimedMiles, id: \.self) { mile in
                    HStack {
                        Text("Mile \(mile)")
                            .font(.headline)
                            .frame(width: 80, alignment: .leading)

                        VStack(alignment: .leading) {
                            ForEach(library.recordings(forMile: mile), id: \.self) { url in
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .font(.subheadline)
                            }
                        }

                        Spacer()

                        if tracker.hasReached(mile: mile) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            // Lets a placement be checked on the sofa rather
                            // than discovering it is wrong at mile 18.
                            Button("Preview") {
                                player.play(library.recordings(forMile: mile))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}
