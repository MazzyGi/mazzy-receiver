import Foundation
import MazzyCore
import AVFoundation

/// Plays s16le interleaved stereo 48kHz PCM chunks from the daemon with a
/// small ring buffer to absorb UDP jitter.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private var ring: [Int16] = []
    private var ringLock = NSLock()
    private let rate: Double
    private let channels = 2

    /// target buffered duration; lower = less latency, riskier
    private var bufferSamples: Int

    init(config: ReceiverConfig) {
        rate = 48000
        bufferSamples = max(1, Int(rate * config.audioBufferSeconds)) * channels
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: rate, channels: 2, interleaved: true)!
        let tap = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let out = abl[0].mData!.assumingMemoryBound(to: Float32.self)
            self.ringLock.lock()
            let avail = self.ring.count / 2  // frames in ring
            let frames = min(Int(frameCount), avail)
            if frames > 0 {
                for i in 0..<frames {
                    let l = Float32(self.ring[i * 2]) / 32768.0
                    let r = Float32(self.ring[i * 2 + 1]) / 32768.0
                    out[i * 2] = l
                    out[i * 2 + 1] = r
                }
                self.ring.removeFirst(frames * 2)
                // zero-fill any shortfall
                for i in frames..<Int(frameCount) {
                    out[i * 2] = 0; out[i * 2 + 1] = 0
                }
            } else {
                for i in 0..<Int(frameCount) * 2 { out[i] = 0 }
            }
            self.ringLock.unlock()
            return noErr
        }
        engine.attach(tap)
        engine.connect(tap, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = config.audioVolume
    }

    func start() {
        do { try engine.start() } catch { print("[audio] engine start failed: \(error)") }
    }

    /// Feed raw s16le stereo bytes from UDP.
    func feed(_ data: Data) {
        ringLock.lock()
        // cap the ring at ~100ms to bound latency
        let maxSamples = Int(rate * 0.1) * 2
        if ring.count > maxSamples { ring.removeFirst(ring.count - maxSamples) }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let samples = raw.count / MemoryLayout<Int16>.stride
            let ptr = base.assumingMemoryBound(to: Int16.self)
            ring.append(contentsOf: UnsafeBufferPointer(start: ptr, count: samples))
        }
        ringLock.unlock()
    }
}
