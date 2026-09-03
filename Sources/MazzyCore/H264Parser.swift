import Foundation

/// Parses H.264 Annex B access units: identifies NAL types, extracts
/// SPS/PPS for decoder format description, flags IDR keyframes.
public enum H264Parser {
    public enum NALType: UInt8 {
        case slice = 1, idr = 5, sei = 6, sps = 7, pps = 8, aud = 9
    }

    public struct NAL {
        public let type: UInt8
        public let payloadRange: Range<Int> // includes the start code
    }

    /// Splits an Annex B buffer into NAL units (leading start code included).
    public static func splitNALs(_ data: Data) -> [NAL] {
        let bytes = [UInt8](data)
        var nals: [NAL] = []
        var i = 0
        while i + 3 < bytes.count {
            // find start code
            var scLen = 0
            if bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 1 { scLen = 3 }
            else if i + 4 < bytes.count, bytes[i] == 0, bytes[i+1] == 0, bytes[i+2] == 0, bytes[i+3] == 1 { scLen = 4 }
            guard scLen > 0 else { i += 1; continue }
            // find next start code
            var j = i + scLen
            var end = bytes.count
            while j + 3 < bytes.count {
                if bytes[j] == 0, bytes[j+1] == 0, bytes[j+2] == 1 { end = j; break }
                if j + 4 < bytes.count, bytes[j] == 0, bytes[j+1] == 0, bytes[j+2] == 0, bytes[j+3] == 1 { end = j; break }
                j += 1
            }
            let nalStart = i
            let headerIdx = i + scLen
            if headerIdx < bytes.count {
                nals.append(NAL(type: bytes[headerIdx] & 0x1F, payloadRange: nalStart..<min(end, bytes.count)))
            }
            i = end
        }
        return nals
    }

    public static func containsNAL(_ data: Data, type: UInt8) -> Bool {
        splitNALs(data).contains { $0.type == type }
    }

    public static func isIDR(_ data: Data) -> Bool { containsNAL(data, type: NALType.idr.rawValue) }
    public static func containsSPS(_ data: Data) -> Bool { containsNAL(data, type: NALType.sps.rawValue) }

    /// Extracts the SPS and PPS NALs (with start codes) so VideoToolbox can
    /// build a CMVideoFormatDescription. Returns nil unless both are present.
    public static func extractSPSPPS(_ data: Data) -> (sps: Data, pps: Data)? {
        var sps: Data?, pps: Data?
        for nal in splitNALs(data) {
            let chunk = data.subdata(in: nal.payloadRange)
            switch nal.type {
            case NALType.sps.rawValue: sps = chunk
            case NALType.pps.rawValue: pps = chunk
            default: break
            }
        }
        guard let s = sps, let p = pps else { return nil }
        return (s, p)
    }

    /// Converts Annex B (start-code delimited) to AVCC (4-byte length prefixed).
    /// VideoToolbox decode samples must be in AVCC when the format description
    /// was built from parameter sets.
    public static func annexBToAVCC(_ data: Data) -> Data {
        var out = Data(capacity: data.count)
        for nal in splitNALs(data) {
            let chunk = data.subdata(in: nal.payloadRange)
            // strip start code (3 or 4 bytes)
            let sc = chunk.prefix(4).last == 1 && chunk.count >= 4 && chunk[chunk.startIndex+3] == 1 ? 4 : 3
            let body = chunk.dropFirst(sc)
            var len = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(body)
        }
        return out
    }
}

/// Rates a stream of byte counts into a moving average bitrate.
public final class BitrateMeter {
    private var window: [(t: Double, bytes: Int)] = []
    private let windowSeconds: Double
    public init(windowSeconds: Double = 1.0) { self.windowSeconds = windowSeconds }

    public func add(bytes: Int, at time: Double = Date().timeIntervalSince1970) {
        window.append((time, bytes))
        trim(to: time)
    }

    public var bitsPerSecond: Double {
        guard let first = window.first, let last = window.last, last.t > first.t else { return 0 }
        let dt = last.t - first.t
        guard dt > 0 else { return 0 }
        let bytes = window.reduce(0) { $0 + $1.bytes }
        return Double(bytes) * 8 / dt
    }

    private func trim(to now: Double) {
        let cutoff = now - windowSeconds
        if let idx = window.firstIndex(where: { $0.t >= cutoff }) {
            window.removeFirst(min(idx, window.count))
        } else {
            window.removeAll()
        }
    }
}
