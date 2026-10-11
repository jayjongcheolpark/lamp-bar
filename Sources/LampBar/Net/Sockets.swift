import Darwin
import Foundation

enum SocketError: Error, CustomStringConvertible {
    case system(String, Int32)
    case timeout
    case closed

    var description: String {
        switch self {
        case let .system(call, code): return "\(call) failed: \(String(cString: strerror(code)))"
        case .timeout: return "timed out"
        case .closed: return "connection closed"
        }
    }
}

/// Small blocking BSD-socket helpers. Callers run them off the main actor.
enum Sockets {
    static func address(_ host: String, _ port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        return addr
    }

    static func hostString(_ addr: sockaddr_in) -> String {
        var a = addr.sin_addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    static func setTimeout(_ fd: Int32, _ seconds: Double, option: Int32) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func setFlag(_ fd: Int32, _ option: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, option, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// A UDP socket bound to `port` (0 for any port).
    static func udp(bindPort port: UInt16 = 0, reusePort: Bool = false) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        setFlag(fd, SO_BROADCAST)
        if reusePort {
            setFlag(fd, SO_REUSEADDR)
            setFlag(fd, SO_REUSEPORT)
        }
        var addr = address("0.0.0.0", port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let code = errno
            close(fd)
            throw SocketError.system("bind", code)
        }
        return fd
    }

    static func send(_ fd: Int32, _ data: Data, to host: String, port: UInt16) throws {
        var addr = address(host, port)
        let sent = data.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent >= 0 else { throw SocketError.system("sendto", errno) }
    }

    /// Receives datagrams until `deadline`, passing each one to `handle`.
    /// `handle` returns true to stop early.
    static func receive(_ fd: Int32, until deadline: Date, handle: (Data, String) -> Bool) {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return }
            setTimeout(fd, max(remaining, 0.01), option: SO_RCVTIMEO)
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                return
            }
            if handle(Data(buf[0..<n]), hostString(from)) { return }
        }
    }

    /// Opens a TCP connection with a connect timeout.
    static func tcpConnect(_ host: String, _ port: UInt16, timeout: Double) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        setFlag(fd, SO_NOSIGPIPE)
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = address(host, port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 && errno != EINPROGRESS {
            let code = errno
            close(fd)
            throw SocketError.system("connect", code)
        }
        if rc != 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(timeout * 1000))
            if ready <= 0 {
                close(fd)
                throw SocketError.timeout
            }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 {
                close(fd)
                throw SocketError.system("connect", err)
            }
        }
        _ = fcntl(fd, F_SETFL, flags)
        setTimeout(fd, timeout, option: SO_RCVTIMEO)
        setTimeout(fd, timeout, option: SO_SNDTIMEO)
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
            if n <= 0 { throw n == 0 ? SocketError.closed : (errno == EAGAIN ? SocketError.timeout : SocketError.system("write", errno)) }
            offset += n
        }
    }

    static func readExactly(_ fd: Int32, _ count: Int) throws -> Data {
        var out = Data(capacity: count)
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < count {
            let n = read(fd, &buf, min(buf.count, count - out.count))
            if n == 0 { throw SocketError.closed }
            if n < 0 { throw errno == EAGAIN ? SocketError.timeout : SocketError.system("read", errno) }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }
}
