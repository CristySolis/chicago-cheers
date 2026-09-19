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

    /// Called as each cheer actually starts — which can be a little after its
    /// mile is passed, if another is still playing. Not called for the sound check.
    var onCheerStarted: ((_ sender: String, _ mile: Double) -> Void)?

    private var player: AVAudioPlayer?
    private var queue: [(audio: URL, sender: String, mile: Double?)] = []

    override init() {
        super.init()
        configureSession(ducking: false)
    }

    /// Takes cheers rather than bare files so the screen can say who is
    /// speaking: synced recordings are named by id, not by sender.
    func play(_ cheers: [Cheer]) {
        let playable = cheers.compactMap { cheer in
            cheer.localURL.map { (audio: $0, sender: cheer.label, mile: Optional(cheer.mile)) }
        }
        guard !playable.isEmpty else { return }
        queue.append(contentsOf: playable)
        if player == nil {
            playNext()
        }
    }

    /// Three short beeps, played exactly the way a cheer is — same queue, same
    /// ducking — so the headphones and volume can be checked before the start.
    func playSoundCheck() {
        guard let chime = Self.soundCheck() else { return }
        queue.append((audio: chime, sender: "Sound check", mile: nil))
        if player == nil {
            playNext()
        }
    }

    private nonisolated static func soundCheck() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sound-check.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let rate = 16_000
        var samples: [Int16] = []
        for _ in 0..<3 {
            let beep = rate * 15 / 100
            for i in 0..<beep {
                // Eased in and out so the beeps don't click.
                let envelope = sin(Double.pi * Double(i) / Double(beep))
                let value = sin(2 * Double.pi * 880 * Double(i) / Double(rate)) * envelope * 0.6
                samples.append(Int16(value * Double(Int16.max)))
            }
            samples += Array(repeating: 0, count: rate / 10)
        }

        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        wav.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))                    // PCM, mono
        append(UInt32(rate)); append(UInt32(rate * 2))
        append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        samples.forEach { append($0) }

        return (try? wav.write(to: url)) != nil ? url : nil
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
            if let mile = next.mile {
                onCheerStarted?(next.sender, mile)
            }
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
