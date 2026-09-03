import Foundation

/// Runtime-tunable options. Everything the user asked to control lives here;
/// loaded from JSON so it can be tweaked without recompiling.
public struct ReceiverConfig: Codable {
    // connection
    public var host: String = "192.168.8.243"   // OrangePi
    public var tcpPort: UInt16 = 50001
    public var videoPort: UInt16 = 50002
    public var audioPort: UInt16 = 50003
    public var sockBufBytes: Int = 4 * 1024 * 1024
    /// Send our address via PROBE1 every N ms so the daemon learns where to
    /// send video/audio (and re-learns after daemon restarts).
    public var probeIntervalMs: Int = 1000

    // video pipeline
    public var reassembleWindow: Int = 256
    /// Deliver incomplete AUs (decoder conceals) instead of dropping them.
    public var deliverIncompleteAUs: Bool = true
    /// Drop everything until SPS/PPS + IDR arrives after a (re)connect.
    public var waitForKeyframe: Bool = true
    /// Max in-flight decode surfaces before we start dropping frames.
    public var maxDecodeQueueDepth: Int = 4

    // latency options
    /// Render as soon as a frame is decoded (no vsync wait) - Metal frame pacing
    /// is handled by CAMetalLayer anyway; this gates extra buffering only.
    public var zeroCopyIOSurface: Bool = true
    /// MetalFX spatial upscaling: off / toWidth x toHeight
    public var upscale: Bool = false
    public var upscaleWidth: Int = 2560
    public var upscaleHeight: Int = 1440
    /// MetalFX temporal interpolation (frame generation) - requires MetalFX 3.
    public var frameGeneration: Bool = false

    // audio
    public var audioVolume: Float = 1.0
    /// Target output buffer in seconds. Lower = less latency, riskier.
    public var audioBufferSeconds: Double = 0.02

    // input -> controller mapping toggles
    public var sendKeyboardAsButtons: Bool = true

    // stats overlay
    public var showStatsOverlay: Bool = true
    public var statsOverlayIntervalMs: Int = 500

    public init() {}

    public static func load(path: String) -> ReceiverConfig {
        guard let data = FileManager.default.contents(atPath: path) else { return ReceiverConfig() }
        return (try? JSONDecoder().decode(ReceiverConfig.self, from: data)) ?? ReceiverConfig()
    }

    public func save(to path: String) {
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// JSON-lines codec for the daemon TCP control channel. Pure and unit-tested.
public enum ControlProtocol {
    public struct Welcome: Codable {
        public let type: String
        public let video_w: Int?
        public let video_h: Int?
        public let audio_channels: Int?
        public let audio_rate: Int?
        public let session: String?
    }

    public static func ctrlMessage(buttons: UInt32, lx: Int, ly: Int, rx: Int, ry: Int, l2: Int, r2: Int) -> String {
        let obj: [String: Any] = ["type": "ctrl", "buttons": Int(buttons), "lx": lx, "ly": ly, "rx": rx, "ry": ry, "l2": l2, "r2": r2]
        if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) { return s }
        return "{}"
    }

    public static func connectMessage() -> String { "{\"type\":\"connect\"}" }
    public static func disconnectMessage() -> String { "{\"type\":\"disconnect\"}" }
    public static func probeMessage(videoPort: UInt16, audioPort: UInt16) -> String { "PROBE1 \(videoPort) \(audioPort)" }

    /// Splits a TCP byte stream into complete JSON lines.
    public final class LineBuffer {
        private var buf = Data()
        public init() {}
        public func feed(_ data: Data) -> [String] {
            buf.append(data)
            var lines: [String] = []
            while let idx = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<idx)
                buf.removeSubrange(buf.startIndex...idx)
                if let s = String(data: line, encoding: .utf8), !s.isEmpty { lines.append(s) }
            }
            return lines
        }
    }
}

/// chiaki DualSense button bitmask (lib/include/chiaki/controller.h).
public enum ControllerButton: UInt32, CaseIterable {
    case cross = 1 << 0, moon = 1 << 1, box = 1 << 2, pyramid = 1 << 3
    case dpadLeft = 1 << 4, dpadRight = 1 << 5, dpadUp = 1 << 6, dpadDown = 1 << 7
    case l1 = 1 << 8, r1 = 1 << 9, l3 = 1 << 10, r3 = 1 << 11
    case options = 1 << 12, share = 1 << 13, touchpad = 1 << 14, ps = 1 << 15
}
