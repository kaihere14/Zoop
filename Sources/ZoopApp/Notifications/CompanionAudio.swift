import AVFoundation
import Foundation

@MainActor
final class CompanionAudio: NSObject, AVAudioPlayerDelegate {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var voice: AVAudioPlayer?
    private var voicePlaybackChanged: ((Bool) -> Void)?
    var isSpeaking: Bool { voice?.isPlaying == true }

    @discardableResult
    func completion(onPlaybackChanged: @escaping (Bool) -> Void) -> TimeInterval {
        // The app bundle has a direct copy; `swift run` uses the SwiftPM resource bundle.
        guard let url = Bundle.main.url(forResource: "completion", withExtension: "mp3")
                ?? Bundle.module.url(forResource: "completion", withExtension: "mp3"),
              let clip = try? AVAudioPlayer(contentsOf: url) else { return 1.8 }
        stopVoice()
        voice = clip
        voicePlaybackChanged = onPlaybackChanged
        clip.delegate = self
        clip.prepareToPlay()
        if clip.play() { voicePlaybackChanged?(true) }
        return clip.duration
    }

    func stopVoice() {
        voice?.stop(); voice = nil
        voicePlaybackChanged?(false); voicePlaybackChanged = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishVoice(ObjectIdentifier(player))
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        finishVoice(ObjectIdentifier(player))
    }

    private nonisolated func finishVoice(_ identity: ObjectIdentifier) {
        Task { @MainActor [weak self] in
            guard let self, let voice = self.voice, ObjectIdentifier(voice) == identity else { return }
            self.stopVoice()
        }
    }

    func chime() {
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        if engine == nil {
            let audioEngine = AVAudioEngine()
            let audioPlayer = AVAudioPlayerNode()
            audioEngine.attach(audioPlayer)
            audioEngine.connect(audioPlayer, to: audioEngine.mainMixerNode, format: format)
            do { try audioEngine.start() } catch { return }
            engine = audioEngine
            player = audioPlayer
        }
        let frames = AVAudioFrameCount(sampleRate * 0.26)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        var phase = 0.0
        for index in 0..<Int(frames) {
            let time = Double(index) / sampleRate
            let frequency = 880 * pow(1.5, min(1, time / 0.13))
            phase += 2 * .pi * frequency / sampleRate
            let attack = min(1, time / 0.012)
            let release = pow(max(0, 1 - time / 0.26), 2)
            channel[index] = Float(sin(phase) * attack * release * 0.07)
        }
        player?.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player?.play()
    }

    func stop() { stopVoice(); player?.stop(); engine?.stop() }
}
