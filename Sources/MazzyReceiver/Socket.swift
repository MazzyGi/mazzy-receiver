import Foundation

/// Minimal BSD socket wrapper used by the receiver.
final class Socket {
    private let fd: Int32
    private var source: DispatchSourceRead?
    var onData: ((Data) -> Void)?

    init?(host: String, port: Int) {
        let hints = addrinfo()
        var info: UnsafeMutablePointer<addrinfo>?
        let r = getaddrinfo(host, String(port), nil, &info)
        guard r == 0, let first = info?.pointee else { return nil }
        defer { freeaddrinfo(info) }
        let s = socket(first.ai_family, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        guard connect(s, first.ai_addr, first.ai_addrlen) == 0 else {
            close(s); return nil
        }
        fd = s
        configureTCP()
    }

    static func udpListen(port: UInt16, rcvBuf: Int) -> Socket? {
        let s = socket(AF_INET, SOCK_DGRAM, 0)
        guard s >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var buf = rcvBuf
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &buf, socklen_t(MemoryLayout<Int>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOK else { close(s); return nil }
        let sock = Socket(fd: s)
        return sock
    }

    private init(fd: Int32) { self.fd = fd }
    deinit { try? source?.cancel(); close(fd) }

    var localPort: UInt16 {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return rc == 0 ? UInt16(bigEndian: addr.sin_port) : 0
    }

    private func configureTCP() {
        var yes: Int32 = 1
        setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    func startReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = recv(self.fd, &buf, buf.count, 0)
            if n > 0 { self.onData?(Data(buf[0..<n])) }
            else {
                // EOF or error: stop the source so it doesn't spin
                print("[socket] closed (\(n))")
                src.cancel()
            }
        }
        src.resume()
        source = src
    }

    func sendLine(_ line: String) {
        var data = Array(line.utf8); data.append(0x0A)
        data.withUnsafeBufferPointer { buf in
            _ = send(fd, buf.baseAddress, buf.count, 0)
        }
    }

    func sendLineTo(_ line: String, host: String, port: Int) {
        // force IPv4: our UDP sockets are AF_INET; resolving "localhost" via
        // getaddrinfo can yield ::1 which silently fails on sendto
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var info: UnsafeMutablePointer<addrinfo>?
        let gai = getaddrinfo(host, String(port), &hints, &info)
        guard gai == 0, let first = info?.pointee else {
            print("[socket] getaddrinfo(\(host):\(port)) failed: \(gai)")
            return
        }
        defer { freeaddrinfo(info) }
        var data = Array(line.utf8)
        let sent = data.withUnsafeBufferPointer { buf in
            sendto(fd, buf.baseAddress, buf.count, 0, first.ai_addr, first.ai_addrlen)
        }
        if sent < 0 {
            print("[socket] sendto(\(host):\(port)) errno=\(errno) \(String(cString: strerror(errno)))")
        }
    }
}
