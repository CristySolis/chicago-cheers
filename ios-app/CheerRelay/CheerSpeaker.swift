import Foundation
import Combine
import AVFoundation
import NaturalLanguage

/// Reads cheers aloud through whatever audio route is active, ducking music or
/// Runna's cues for the few seconds it takes.
///
/// This is also what keeps the app alive for a whole marathon. iOS suspends a
/// backgrounded app and its timers with it, which would stop SheetPoller dead
/// once the phone is in an armband with the screen off. An app registered for
/// background audio keeps running while it has something to play, so a looping
/// silent buffer holds the process open between cheers.
final class CheerSpeaker: NSObject, ObservableObject {

    @Published private(set) var lastSpoken: String?
    @Published private(set) var audioError: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var keepAlive: AVAudioPlayer?

    /// Twenty seconds of someone's paragraph at mile 20 is an irritation, not
    /// encouragement.
    private static let maxSpokenCharacters = 200

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func start() {
        do {
            try configureSession(ducking: false)
            let player = try AVAudioPlayer(data: Self.silentClip())
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            keepAlive = player
            audioError = nil
        } catch {
            audioError = "Audio setup failed — cheers won't be spoken: \(error.localizedDescription)"
        }
    }

    func speak(_ message: CheerMessage) {
        let body = Self.sanitize(message.text)
        guard !body.isEmpty else { return }

        let language = Self.language(of: body)
        let sender = Self.sanitize(message.sender)
        let spoken = sender.isEmpty ? body : "\(sender) \(language.saysVerb) \(body)"

        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = AVSpeechSynthesisVoice(language: language.voiceCode)
        utterance.postUtteranceDelay = 0.2
        synthesizer.speak(utterance)
        lastSpoken = spoken
    }

    // MARK: - Text preparation

    private enum SpokenLanguage {
        case english, spanish

        var voiceCode: String {
            switch self {
            case .english: return "en-US"
            case .spanish: return "es-MX"
            }
        }

        /// Matching the message's own language avoids "Tete says ya merito"
        /// read by an English voice, which is unintelligible.
        var saysVerb: String {
            switch self {
            case .english: return "says"
            case .spanish: return "dice"
            }
        }
    }

    /// Constrained to the two languages that actually turn up, because
    /// unconstrained detection is wrong on short cheers: "Ya merito!!!" comes
    /// back as Indonesian at 0.81 confidence, "GOOOOO" as Italian. Narrowed to
    /// this pair, both land correctly.
    private static func language(of text: String) -> SpokenLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish]
        recognizer.processString(text)

        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let spanish = hypotheses[.spanish] ?? 0
        let english = hypotheses[.english] ?? 0
        return spanish > english ? .spanish : .english
    }

    /// Strips emoji — otherwise "GO CRISTY GO 🎉" is read as "...party popper"
    /// — and caps the length.
    private static func sanitize(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            if scalar.properties.isEmojiPresentation { return false }
            if scalar.properties.isEmojiModifier || scalar.properties.isEmojiModifierBase { return false }
            if scalar.value == 0xFE0F || scalar.value == 0x200D { return false }
            return true
        }

        let cleaned = String(String.UnicodeScalarView(scalars))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return cleaned.count <= maxSpokenCharacters
            ? cleaned
            : String(cleaned.prefix(maxSpokenCharacters))
    }

    // MARK: - Audio session

    private func configureSession(ducking: Bool) throws {
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers]
        if ducking {
            options.insert(.duckOthers)
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: options)
        try session.setActive(true)
    }

    /// A silent WAV built in memory, so there's no asset to add to the target.
    private static func silentClip(seconds: Double = 1) -> Data {
        let sampleRate = 8000
        let frameCount = Int(Double(sampleRate) * seconds)
        let dataSize = frameCount * 2 // 16-bit mono

        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF");  u32(UInt32(36 + dataSize)); ascii("WAVE")
        ascii("fmt ");  u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data");  u32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }
}

extension CheerSpeaker: AVSpeechSynthesizerDelegate {

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didStart utterance: AVSpeechUtterance) {
        try? configureSession(ducking: true)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        // Stay ducked while more cheers are still queued behind this one.
        if !synthesizer.isSpeaking {
            try? configureSession(ducking: false)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking {
            try? configureSession(ducking: false)
        }
    }
}
