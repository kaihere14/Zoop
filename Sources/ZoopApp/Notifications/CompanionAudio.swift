import AVFoundation
import Foundation

@MainActor
final class CompanionAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

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

    func stop() { player?.stop(); engine?.stop() }
}
