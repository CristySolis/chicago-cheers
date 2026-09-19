import SwiftUI

struct RaceView: View {
    @StateObject private var tracker = RaceTracker()
    @StateObject private var library = CheerLibrary(source: SyncedCheerSource())
    @StateObject private var player = CheerPlayer()
    @StateObject private var sync = CheerSync(api: ApiClient(baseURL: AppConfig.apiBaseURL))
    @State private var showingSignIn = false
    @State private var confirmingStop = false
    @State private var confirmingReset = false
    @State private var showingReadiness = false

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                distance

                if let message = tracker.problem ?? library.problem ?? player.problem {
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

                if !tracker.isRunning {
                    readiness

                    if !tracker.log.files.isEmpty {
                        ShareLink(items: tracker.log.files) {
                            Label("Share race log", systemImage: "square.and.arrow.up")
                                .font(.subheadline)
                        }
                    }
                }

                miles
            }
            .padding()
            .navigationTitle("Chicago Cheer Squad")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if sync.isSignedIn {
                        // Never during the race: once Start is pressed, the app
                        // runs only on what's already on the phone.
                        Button("Sync") { Task { await runSync() } }
                            .disabled(tracker.isRunning || isSyncing)
                    } else {
                        Button("Sign in") { showingSignIn = true }
                    }
                }
                if sync.isSignedIn {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Sign out") { sync.signOut() }
                            .disabled(tracker.isRunning || isSyncing)
                    }
                }
            }
            .sheet(isPresented: $showingReadiness) {
                ReadinessView(tracker: tracker, library: library, sync: sync,
                              player: player, runSync: runSync)
            }
            .sheet(isPresented: $showingSignIn, onDismiss: {
                if sync.isSignedIn { Task { await runSync() } }
            }) {
                SignInView(sync: sync)
            }
            .task {
                await library.reload()
                let cheers = library
                let sound = player
                let race = tracker
                tracker.onMileReached = { mile in
                    sound.play(cheers.readyCheers(forMile: mile))
                }
                player.onCheerStarted = { sender, mile in
                    race.cheerStarted(sender: sender, mile: mile)
                }
            }
        }
    }

    private var isSyncing: Bool {
        if case .syncing = sync.state { return true }
        return false
    }

    private var isFailure: Bool {
        switch sync.state {
        case .failed: return true
        case .finished(_, let failed): return failed > 0
        default: return false
        }
    }

    /// The next mile that actually holds a cheer — not simply the next mile
    /// marker, most of which will be empty.
    private var nextCheer: String? {
        guard library.count > 0 else { return "No cheers on the phone yet" }
        guard let mile = library.claimedMiles.first(where: { !tracker.hasReached(mile: $0) }) else {
            return "Every cheer has played"
        }
        let togo = mile - tracker.milesCovered
        guard tracker.startedAt != nil, togo > 0 else { return "Next cheer: \(Course.label(mile))" }
        return "Next cheer: \(Course.label(mile)) · in \(String(format: "%.1f", togo)) mi"
    }

    private func runSync() async {
        await sync.sync()
        await library.reload()
    }

    private var syncStatus: String? {
        switch sync.state {
        case .idle:
            if let last = sync.lastSynced {
                return "Last synced \(last.formatted(date: .abbreviated, time: .shortened))"
            }
            return sync.isSignedIn ? "Not synced yet" : nil
        case .syncing(let done, let total):
            return total == 0 ? "Syncing…" : "Downloading \(done + 1) of \(total)…"
        case .finished(let count, let failed):
            return failed == 0
                ? "\(count) recordings synced"
                : "\(count) synced, \(failed) failed — tap Sync again"
        case .failed(let message):
            return message
        }
    }

    /// The race-day screen: made to be read in a glance while running.
    private var distance: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let clock = tracker.displayedClock(at: context.date)
            VStack(spacing: 6) {
                if let clock {
                    Text(RaceClock.text(clock))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .accessibilityLabel("Race time \(RaceClock.text(clock))")
                }

                Text(String(format: "%.2f", tracker.milesCovered))
                    .font(.system(size: tracker.isRunning ? 96 : 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text(milesLine(clock: clock))
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if tracker.isRunning && !tracker.hasFix {
                    Label("Waiting for GPS…", systemImage: "location")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }

                if let nextCheer {
                    Text(nextCheer)
                        .font(tracker.isRunning ? .title3.weight(.semibold) : .footnote)
                        .foregroundColor(tracker.isRunning ? .primary : .secondary)
                }

                if let last = tracker.lastCheer {
                    Text("Last: \(last.sender) · \(Course.label(last.mile))"
                         + (last.raceClock.map { " at \(RaceClock.text($0))" } ?? ""))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// "miles", or "miles · 8:34 /mi average" once there's a pace to show.
    private func milesLine(clock: TimeInterval?) -> String {
        guard let clock, let pace = RaceClock.pace(seconds: clock, miles: tracker.milesCovered) else {
            return "miles"
        }
        return "miles · \(pace) /mi average"
    }

    /// Stop and Reset each take a second, deliberate tap. One stray touch
    /// mid-race must not cost anything: a stop loses the distance run while
    /// stopped, so every later cheer plays late, and a reset replays them all
    /// from mile 1.
    private var startStop: some View {
        HStack(spacing: 12) {
            if tracker.isRunning {
                Button("Stop") { confirmingStop = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .confirmationDialog("Stop tracking?", isPresented: $confirmingStop,
                                        titleVisibility: .visible) {
                        Button("Stop tracking", role: .destructive) { tracker.stop() }
                        Button("Keep going", role: .cancel) {}
                    } message: {
                        Text("Distance isn't counted while stopped, so every cheer after this would play late. Only stop at the finish.")
                    }
            } else {
                Button(tracker.milesCovered > 0 ? "Resume" : "Start") { tracker.start() }
                    .buttonStyle(.borderedProminent)
            }

            if !tracker.isRunning && tracker.milesCovered > 0 {
                Button("Reset", role: .destructive) { confirmingReset = true }
                    .buttonStyle(.bordered)
                    .confirmationDialog("Reset to 0 miles?", isPresented: $confirmingReset,
                                        titleVisibility: .visible) {
                        Button("Reset distance and cheers", role: .destructive) { tracker.reset() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Clears the distance and marks every cheer as not yet played, so they all play again from mile 1. For training runs only — never mid-race.")
                    }
            }
        }
    }

    /// One line saying whether the phone is ready, opening the full checklist.
    private var readiness: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let summary = Readiness.summary(of: Readiness.check(
                .current(tracker: tracker, library: library, sync: sync, now: context.date)))
            Button {
                showingReadiness = true
            } label: {
                Label(summary.text, systemImage: summary.status.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(summary.status.color)
            }
            .buttonStyle(.bordered)
        }
    }

    private var miles: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(library.count) recordings, \(library.claimedMiles.count) spots")
                Spacer()
                Text(library.sourceDescription)
            }
            .font(.footnote)
            .foregroundColor(.secondary)

            if let syncStatus {
                Text(syncStatus)
                    .font(.footnote)
                    .foregroundColor(isFailure ? .red : .secondary)
            }

            // Every one of these is a supporter whose recording would not play.
            if !library.missingAudio.isEmpty {
                Label("\(library.missingAudio.count) not downloaded yet",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }

            List {
                ForEach(library.claimedMiles, id: \.self) { mile in
                    HStack {
                        Text(Course.label(mile))
                            .font(.headline)
                            .frame(width: 100, alignment: .leading)

                        VStack(alignment: .leading) {
                            ForEach(library.cheers(forMile: mile)) { cheer in
                                Text(cheer.label)
                                    .font(.subheadline)
                                    .foregroundColor(cheer.isReadyForRace ? .primary : .orange)
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
                                player.play(library.readyCheers(forMile: mile))
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
