import Foundation
import MazzyCore
import VideoToolbox
import CoreMedia

/// The whole receive pipeline: control channel + UDP streams + hardware
/// decode. Rendering hooks are closures so a Metal layer can attach later.
final class Receiver {
    private let config: ReceiverConfig
    private let queue = DispatchQueue(label: "mazzy.receiver")
    private let reassembler: VideoReassembler
    private let videoBitrate = BitrateMeter()
    private let lineBuffer = ControlProtocol.LineBuffer()

    // stats
    private var lastStatsPrint = Date()
    private var auCount = 0
    private var decodeCount = 0
    private var decodeMsTotal: Double = 0
    private var decodeMsMax: Double = 0

    // VideoToolbox
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?

    /// Called with every decoded frame (IOSurface-backed CVPixelBuffer).
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called with PCM audio chunks (s16le interleaved stereo 48k).
    var onAudio: ((Data) -> Void)?
    /// Called with session state changes from the daemon.
    var onSessionState: ((String) -> Void)?

    init(config: ReceiverConfig) {
        self.config = config
        self.reassembler = VideoReassembler(
            maxWindow: config.reassembleWindow,
            deliverIncomplete: config.deliverIncompleteAUs)
    }

    func run() {
        startTCP()
        startVideoUDP()
        startAudioUDP()
        dispatchMain()
    }

    // MARK: - TCP control

    private var tcp: Socket?

    private func startTCP() {
        queue.async {
            guard let sock = Socket(host: self.config.host, port: Int(self.config.tcpPort)) else {
                print("[tcp] connect failed, retrying in 3s")
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { self.startTCP() }
                return
            }
            self.tcp = sock
            print("[tcp] connected to daemon")
            sock.onData = { [weak self] data in self?.handleTCP(data) }
            sock.startReading()
            sock.sendLine(ControlProtocol.connectMessage())
        }
    }

    private func handleTCP(_ data: Data) {
        for line in lineBuffer.feed(data) {
            guard let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            switch type {
            case "welcome":
                let w = obj["video_w"] as? Int ?? 0
                let h = obj["video_h"] as? Int ?? 0
                let session = obj["session"] as? String ?? "?"
                print("[tcp] welcome \(w)x\(h) session=\(session)")
                onSessionState?(session)
            case "session_started":
                print("[tcp] session started")
                onSessionState?("connected")
            case "session_ended":
                print("[tcp] session ended")
                onSessionState?("disconnected")
            default: break
            }
        }
    }

    // MARK: - UDP video

    private var videoSock: Socket?

    private func startVideoUDP() {
        guard let sock = Socket.udpListen(port: 0, rcvBuf: config.sockBufBytes) else {
            print("[video] udp bind failed"); return
        }
        videoSock = sock
        let vPort = sock.localPort
        print("[video] udp bound on \(vPort)")
        let probe = ControlProtocol.probeMessage(videoPort: vPort, audioPort: vPort)
        // keep punching so the daemon always knows where to send
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: .milliseconds(config.probeIntervalMs))
        timer.setEventHandler { [weak self, weak sock] in
            guard let self, let sock else { return }
            sock.sendLineTo(probe, host: self.config.host, port: Int(self.config.videoPort))
        }
        timer.resume()
        print("[video] probing daemon at \(config.host):\(config.videoPort) every \(config.probeIntervalMs)ms")

        var waitingKeyframe = config.waitForKeyframe
        sock.onData = { [weak self] data in
            guard let self else { return }
            self.videoBitrate.add(bytes: data.count)
            if let au = self.reassembler.feed(packet: data) ?? self.reassembler.drainEviction() {
                self.handleAU(au, waitingKeyframe: &waitingKeyframe)
            }
        }
        sock.startReading()
    }

    // MARK: - UDP audio

    private var audioSock: Socket?

    private func startAudioUDP() {
        guard let sock = Socket.udpListen(port: 0, rcvBuf: config.sockBufBytes) else {
            print("[audio] udp bind failed"); return
        }
        audioSock = sock
        sock.onData = { [weak self] data in
            guard data.count > 7, data[0] == RelayProtocol.audioMagic else { return }
            let size = Int(data[5]) << 8 | Int(data[6])
            guard size + 7 <= data.count else { return }
            self?.onAudio?(data.subdata(in: 7..<(7 + size)))
        }
        // audio arrives on the same socket as video (daemon sends both to the
        // port we declared in PROBE1); no separate listener needed.
    }

    // MARK: - AU handling / decode

    private func handleAU(_ au: VideoReassembler.AccessUnit, waitingKeyframe: inout Bool) {
        auCount += 1
        if waitingKeyframe {
            guard H264Parser.containsSPS(au.data), H264Parser.isIDR(au.data) else { return }
            waitingKeyframe = false
        }
        maybeSetupDecoder(with: au.data)
        decode(au.data)
    }

    private func maybeSetupDecoder(with annexB: Data) {
        guard formatDesc == nil, let spspps = H264Parser.extractSPSPPS(annexB) else { return }
        // strip start codes for the parameter sets passed to VideoToolbox
        func stripSC(_ d: Data) -> Data {
            guard d.count >= 4 else { return d }
            if d[d.startIndex+2] == 1 { return d.dropFirst(3) }
            return d.dropFirst(4)
        }
        let sps = stripSC(spspps.sps)
        let pps = stripSC(spspps.pps)
        var status: OSStatus = -1
        var newDesc: CMVideoFormatDescription?
        sps.withUnsafeBytes { (spsRaw: UnsafeRawBufferPointer) in
            pps.withUnsafeBytes { (ppsRaw: UnsafeRawBufferPointer) in
                guard let spsBase = spsRaw.baseAddress, let ppsBase = ppsRaw.baseAddress else { return }
                status = spsBase.withMemoryRebound(to: UInt8.self, capacity: spsRaw.count) { spsPtr in
                    ppsBase.withMemoryRebound(to: UInt8.self, capacity: ppsRaw.count) { ppsPtr in
                var ptrs: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                return ptrs.withUnsafeBufferPointer { ptrBuf in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil,
                        parameterSetCount: 2,
                        parameterSetPointers: ptrBuf.baseAddress!,
                        parameterSetSizes: [spsRaw.count, ppsRaw.count],
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &newDesc)
                }
                    }
                }
            }
        }
        guard status == noErr, let fd = newDesc else {
            print("[decode] format description failed \(status)"); return
        }
        formatDesc = fd
        let attrs: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey as NSString: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as NSString: true,
            kCVPixelBufferIOSurfacePropertiesKey as NSString: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: fd,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            decompressionSessionOut: &s)
        guard status == noErr, let session = s else {
            print("[decode] session create failed \(status)"); return
        }
        self.session = session
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        print("[decode] VideoToolbox ready \(dims.width)x\(dims.height)")
    }

    private func decode(_ annexB: Data) {
        guard let session, let fd = formatDesc else { return }
        let avcc = H264Parser.annexBToAVCC(annexB)
        let t0 = Date()

        // AVCC bytes -> CMBlockBuffer -> CMSampleBuffer
        var block: CMBlockBuffer?
        let bufStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &block)
        guard bufStatus == kCMBlockBufferNoErr, let block else { return }
        let copyStatus: OSStatus = avcc.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return kCMBlockBufferStructureAllocationFailedErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: avcc.count)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        var sample: CMSampleBuffer?
        var timing = [CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 600),
            presentationTimeStamp: CMTime(value: 1, timescale: 600),
            decodeTimeStamp: .invalid)]
        var sizes: [Int] = [avcc.count]
        let sbStatus = timing.withUnsafeMutableBufferPointer { timingBuf in
            sizes.withUnsafeMutableBufferPointer { sizesBuf in
                CMSampleBufferCreate(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: block,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: fd,
                    sampleCount: 1,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: timingBuf.baseAddress,
                    sampleSizeEntryCount: 1,
                    sampleSizeArray: sizesBuf.baseAddress,
                    sampleBufferOut: &sample)
            }
        }
        guard sbStatus == noErr, let sample else { return }

        VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
        ) { [weak self] decodeStatus, _, imageBuffer, _, _, _ in
            guard let self, decodeStatus == noErr, let buf = imageBuffer else { return }
            // VideoToolbox hands back a CVPixelBuffer as CVImageBuffer
            let pix = unsafeBitCast(buf, to: CVPixelBuffer.self)
            let ms = -t0.timeIntervalSinceNow * 1000
            self.queue.async {
                self.decodeCount += 1
                self.decodeMsTotal += ms
                self.decodeMsMax = max(self.decodeMsMax, ms)
                self.onFrame?(pix)
                self.maybePrintStats()
            }
        }
    }

    // MARK: - stats

    private func maybePrintStats() {
        guard config.showStatsOverlay else { return }
        let now = Date()
        guard now.timeIntervalSince(lastStatsPrint) >= Double(config.statsOverlayIntervalMs) / 1000.0 else { return }
        lastStatsPrint = now
        let s = reassembler.stats
        let mbps = videoBitrate.bitsPerSecond / 1e6
        let avgDecode = decodeCount > 0 ? decodeMsTotal / Double(decodeCount) : 0
        print(String(format: "[stats] loss=%.2f%% au=%d decoded=%d decode=%.1fms(max %.1f) bitrate=%.1fMbps frags=%d drop=%d corrupt=%d",
                     s.lossRate * 100, auCount, decodeCount, avgDecode, decodeMsMax, mbps,
                     s.fragmentsReceived, s.fragmentsDropped, s.accessUnitsCorrupt))
    }
}
