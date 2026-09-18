import Foundation
import Combine
import AVFoundation

/// Plays a mile's recordings over whatever else is running, ducking music or
/// Runna's cues for the few seconds each one lasts.
///
/// A mile can hold more than one recording once all 26 are claimed, so these
/// queue rather than talk over each other.
final class CheerPlayer: NSObject, ObservableObject {

    @Published private(set) var nowPlaying: String?
    @Published private(set) var problem: String?

    private var player: AVAudioPlayer?
    private var queue: [(audio: URL, sender: String)] = []

    override init() {
        super.init()
        configureSession(ducking: false)
    }

    /// Takes cheers rather than bare files so the screen can say who is
    /// speaking: synced recordings are named by id, not by sender.
    func play(_ cheers: [Cheer]) {
        let playable = cheers.compactMap { cheer in
            cheer.localURL.map { (audio: $0, sender: cheer.label) }
        }
        guard !playable.isEmpty else { return }
        queue.append(contentsOf: playable)
        if player == nil {
            playNext()
        }
    }

    private func playNext() {
        guard !queue.isEmpty else {
            finish()
            return
        }

        let next = queue.removeFirst()
        do {
            configureSession(ducking: true)
            let audio = try AVAudioPlayer(contentsOf: next.audio)
            audio.delegate = self
            audio.prepareToPlay()
            audio.play()
            player = audio
            nowPlaying = next.sender
            problem = nil
        } catch {
            // One unreadable file must not stop the rest of the race.
            problem = "Couldn't play \(next.sender)'s cheer: \(error.localizedDescription)"
            playNext()
        }
    }

    private func finish() {
        player = nil
        nowPlaying = nil
        configureSession(ducking: false)
    }

    private func configureSession(ducking: Bool) {
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers]
        if ducking {
            options.insert(.duckOthers)
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: options)
            try session.setActive(true)
        } catch {
            problem = "Audio setup failed: \(error.localizedDescription)"
        }
    }
}

extension CheerPlayer: AVAudioPlayerDelegate {

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playNext()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        problem = "Playback error: \(error?.localizedDescription ?? "unknown")"
        playNext()
    }
}
