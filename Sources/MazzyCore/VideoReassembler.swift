import Foundation

// MARK: - Relay protocol (mirrors daemon/src/net.c)
//
// TCP control channel (50001) - JSON lines:
//   <- {"type":"welcome","video_w":..,"video_h":..,"session":".."}
//   -> {"type":"ctrl","buttons":..,"lx":..,...}
//   -> {"type":"connect"} / {"type":"disconnect"}
//
// UDP video (50002) - H.264 AU fragments:
//   [u8 magic=0xC1][u32 BE counter][u8 frag_id][u8 frag_count][u16 BE size][payload]
//
// UDP audio (50003) - decoded PCM s16le:
//   [u8 magic=0xC2][u32 BE counter][u16 BE size][payload]

public enum RelayProtocol {
    public static let videoMagic: UInt8 = 0xC1
    public static let audioMagic: UInt8 = 0xC2
    public static let tcpPort: UInt16 = 50001
    public static let videoPort: UInt16 = 50002
    public static let audioPort: UInt16 = 50003
}

public struct FragmentHeader {
    public let magic: UInt8
    public let counter: UInt32
    public let fragID: UInt8
    public let fragCount: UInt8
    public let size: UInt16

    /// Parses [magic][counter u32 BE][frag_id u8][frag_count u8][size u16 BE]
    /// Returns nil when the packet is too short or the magic doesn't match.
    public init?(packet: Data) {
        guard packet.count >= 9 else { return nil }
        let bytes = [UInt8](packet.prefix(9))
        magic = bytes[0]
        guard magic == RelayProtocol.videoMagic else { return nil }
        counter = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
        fragID = bytes[5]
        fragCount = bytes[6]
        size = UInt16(bytes[7]) << 8 | UInt16(bytes[8])
        guard fragCount > 0, fragID < fragCount, Int(size) + 9 <= packet.count else { return nil }
    }
}

/// Reassembles fragmented H.264 access units out of UDP video packets,
/// tracking loss and dup statistics along the way. Thread-safe.
public final class VideoReassembler {
    public struct Stats {
        public var fragmentsReceived = 0
        public var fragmentsDropped = 0
        public var accessUnits = 0
        public var accessUnitsLost = 0      // incomplete AUs evicted
        public var accessUnitsCorrupt = 0   // AUs completed with missing fragments
        public var bytesDelivered = 0

        /// Fragments dropped + fragments missing from corrupt AUs, over all received.
        public var lossRate: Double {
            let lost = fragmentsDropped + accessUnitsCorrupt
            let total = fragmentsReceived + fragmentsDropped
            guard total > 0 else { return 0 }
            return Double(lost) / Double(total)
        }
    }

    public struct AccessUnit {
        public let counter: UInt32
        public let data: Data
        /// Number of fragments that never arrived before completion.
        public let missingFragments: Int
    }

    private final class AUBuffer {
        var chunks: [Data?]
        var received: Int = 0
        init(fragCount: Int) { chunks = [Data?](repeating: nil, count: fragCount) }
    }

    private var buffers: [UInt32: AUBuffer] = [:]
    private var highestCounter: UInt32 = 0
    private var completedCounters = Set<UInt32>()  // finished/dropped AUs (dup guard)
    private let lock = NSLock()
    public private(set) var stats = Stats()

    /// - Parameters:
    ///   - maxWindow: how many AU counters to keep before evicting stale ones.
    ///   - deliverIncomplete: deliver an AU as soon as a later AU starts when
    ///     fragments are missing (lets the decoder conceal instead of stalling).
    public init(maxWindow: Int = 256, deliverIncomplete: Bool = true) {
        self.maxWindow = maxWindow
        self.deliverIncomplete = deliverIncomplete
    }

    private let maxWindow: Int
    private let deliverIncomplete: Bool

    /// Feed one raw UDP packet. Returns a completed AU when this fragment
    /// finished one (or when eviction forces an incomplete one out).
    public func feed(packet: Data) -> AccessUnit? {
        guard let h = FragmentHeader(packet: packet) else {
            lock.lock(); stats.fragmentsDropped += 1; lock.unlock()
            return nil
        }
        let payload = packet.subdata(in: 9..<(9 + Int(h.size)))
        return feed(header: h, payload: payload)
    }

    public func feed(header h: FragmentHeader, payload: Data) -> AccessUnit? {
        lock.lock(); defer { lock.unlock() }

        // AU already finished (all fragments arrived before) -> this is a dup
        if completedCounters.contains(h.counter) {
            stats.fragmentsDropped += 1
            return nil
        }

        stats.fragmentsReceived += 1

        // loss detection: any completed counter below this one that we never
        // finished counts as lost
        noteLosses(below: h.counter)

        let buf = buffers[h.counter] ?? AUBuffer(fragCount: Int(h.fragCount))
        buffers[h.counter] = buf
        if buf.chunks[Int(h.fragID)] == nil {
            buf.chunks[Int(h.fragID)] = payload
            buf.received += 1
        } else {
            stats.fragmentsDropped += 1  // duplicate fragment within the AU
            return nil
        }

        if buf.received == buf.chunks.count {
            buffers.removeValue(forKey: h.counter)
            stats.accessUnits += 1
            markCompleted(h.counter)
            let data = buf.chunks.compactMap { $0 }.reduce(Data(), +)
            stats.bytesDelivered += data.count
            return AccessUnit(counter: h.counter, data: data, missingFragments: 0)
        }
        return nil
    }

    /// Track finished counters for dup detection, bounding memory.
    private func markCompleted(_ counter: UInt32) {
        completedCounters.insert(counter)
        if completedCounters.count > maxWindow {
            // drop the oldest half by numeric distance from the newest
            let cutoff = counter &- UInt32(maxWindow / 2)
            completedCounters.subtract(Set(completedCounters.filter { ($0 &- cutoff) & 0x8000_0000 == 0 }))
        }
    }

    /// Evict incomplete AUs whose counter is far behind the newest arrival.
    /// Called on every feed; returns the flushed AU if incomplete delivery is on.
    private func noteLosses(below newCounter: UInt32) {
        // wraparound-safe distance
        func dist(_ a: UInt32, _ b: UInt32) -> Int { // a behind b
            let d = b &- a
            return d > 0xFFFF_FFFF / 2 ? Int(~d &+ 1) : Int(d)
        }
        highestCounter = newCounter
        for (counter, buf) in buffers where dist(counter, newCounter) > 64 {
            buffers.removeValue(forKey: counter)
            let missing = buf.chunks.count - buf.received
            if deliverIncomplete, buf.received > 0, missing < buf.chunks.count {
                stats.accessUnitsCorrupt += 1
                // deliver what we have stitched together in order; decoder will
                // conceal. H.264 decoders can usually ride out a corrupt slice.
                var data = Data()
                for case let c? in buf.chunks { data.append(c) }
                pendingEvictions.append(AccessUnit(counter: counter, data: data, missingFragments: missing))
            } else {
                stats.accessUnitsLost += 1
            }
            markCompleted(counter)
        }
    }

    private var pendingEvictions: [AccessUnit] = []

    /// Pop an AU that was evicted incomplete (call right after feed returned nil).
    public func drainEviction() -> AccessUnit? {
        lock.lock(); defer { lock.unlock() }
        guard !pendingEvictions.isEmpty else { return nil }
        return pendingEvictions.removeFirst()
    }

    public func resetStats() {
        lock.lock(); defer { lock.unlock() }
        stats = Stats()
    }
}
