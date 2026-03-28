/// SkyHook NFS Filter Proxy
/// Blocks ._* (Apple Double) and .DS_Store file creation at the NFS RPC level.
/// Usage: skyhook-nfs-proxy <listen-port> <target-port>
import Foundation

signal(SIGPIPE, SIG_IGN)

final class NFSFilterProxy {
    let listenPort: Int
    let targetPort: Int
    private var serverFd: Int32 = -1
    private var running = false

    // NFS v3 procedure numbers that create files
    static let createProcs: Set<UInt32> = [8, 9, 10, 11, 14, 15]

    init(listenPort: Int, targetPort: Int) {
        self.listenPort = listenPort
        self.targetPort = targetPort
    }

    func start() -> Bool {
        serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(listenPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let b = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard b == 0 else { close(serverFd); return false }
        guard listen(serverFd, 128) == 0 else { close(serverFd); return false }
        running = true
        DispatchQueue.global(qos: .userInitiated).async { self.acceptLoop() }
        return true
    }

    func stop() {
        running = false
        if serverFd >= 0 { close(serverFd); serverFd = -1 }
    }

    private func acceptLoop() {
        while running {
            var ca = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &ca) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(serverFd, $0, &len) }
            }
            guard cfd >= 0 else { continue }
            DispatchQueue.global(qos: .userInitiated).async { self.handleClient(cfd) }
        }
    }

    private func handleClient(_ clientFd: Int32) {
        let rcloneFd = socket(AF_INET, SOCK_STREAM, 0)
        guard rcloneFd >= 0 else { close(clientFd); return }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(targetPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(rcloneFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { close(clientFd); close(rcloneFd); return }

        let alive = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        alive.pointee = true

        // Server → Client: pure relay
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [UInt8](repeating: 0, count: 65536)
            while alive.pointee {
                let n = read(rcloneFd, &buf, buf.count)
                guard n > 0 else { break }
                buf.withUnsafeBufferPointer { ptr in
                    var s = 0
                    while s < n {
                        let w = write(clientFd, ptr.baseAddress! + s, n - s)
                        guard w > 0 else { alive.pointee = false; return }
                        s += w
                    }
                }
            }
            alive.pointee = false
            close(rcloneFd)
            close(clientFd)
            alive.deallocate()
        }

        // Client → Server: inspect NFS RPCs
        DispatchQueue.global(qos: .userInitiated).async {
            while alive.pointee {
                // Read NFS record marking header (4 bytes)
                guard let rmHeader = Self.readExact(clientFd, count: 4) else { break }
                let rmWord = UInt32(rmHeader[0]) << 24 | UInt32(rmHeader[1]) << 16 |
                             UInt32(rmHeader[2]) << 8 | UInt32(rmHeader[3])
                let fragLen = Int(rmWord & 0x7FFFFFFF)
                guard fragLen > 0, fragLen < 10_000_000 else { break }
                guard let payload = Self.readExact(clientFd, count: fragLen) else { break }

                if self.shouldBlock(payload) {
                    let reply = self.fakeReply(payload)
                    let rm = Self.buildRM(data: reply, last: true)
                    var full = rm
                    full.append(reply)
                    full.withUnsafeBytes { ptr in
                        var s = 0
                        while s < full.count {
                            let w = write(clientFd, ptr.baseAddress! + s, full.count - s)
                            guard w > 0 else { alive.pointee = false; return }
                            s += w
                        }
                    }
                    continue
                }

                // Forward to rclone
                var msg = rmHeader
                msg.append(contentsOf: payload)
                msg.withUnsafeBytes { ptr in
                    var s = 0
                    while s < msg.count {
                        let w = write(rcloneFd, ptr.baseAddress! + s, msg.count - s)
                        guard w > 0 else { alive.pointee = false; return }
                        s += w
                    }
                }
            }
            alive.pointee = false
        }
    }

    private func shouldBlock(_ p: Data) -> Bool {
        guard p.count >= 24 else { return false }
        guard u32(p, 4) == 0 else { return false }       // CALL only
        guard u32(p, 12) == 100003 else { return false }  // NFS program
        let proc = u32(p, 20)
        guard Self.createProcs.contains(proc) else { return false }

        // Parse past credentials + verifier to get filename
        guard p.count >= 32 else { return false }
        let credLen = Int(u32(p, 28))
        let credEnd = 32 + credLen
        guard p.count >= credEnd + 8 else { return false }
        let verifLen = Int(u32(p, credEnd + 4))
        let argsStart = credEnd + 8 + verifLen

        // Args: file handle (4+len padded) + filename (4+len)
        guard p.count >= argsStart + 4 else { return false }
        let fhLen = Int(u32(p, argsStart))
        let fhPad = (fhLen + 3) & ~3
        let nameOff = argsStart + 4 + fhPad
        guard p.count >= nameOff + 4 else { return false }
        let nameLen = Int(u32(p, nameOff))
        guard nameLen > 0, p.count >= nameOff + 4 + nameLen else { return false }

        let nameData = p[(nameOff + 4)..<(nameOff + 4 + nameLen)]
        guard let name = String(data: nameData, encoding: .utf8) else { return false }

        return name.hasPrefix("._") || name == ".DS_Store"
    }

    private func fakeReply(_ p: Data) -> Data {
        let xid = u32(p, 0)
        var r = Data()
        a32(&r, xid)      // XID
        a32(&r, 1)        // REPLY
        a32(&r, 0)        // MSG_ACCEPTED
        a32(&r, 0)        // AUTH_NONE verifier
        a32(&r, 0)        // verifier length
        a32(&r, 0)        // accept_stat = SUCCESS
        a32(&r, 1)        // NFS3ERR_PERM — permission denied
        return r
    }

    private func u32(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.startIndex + o
        return UInt32(d[i]) << 24 | UInt32(d[i+1]) << 16 | UInt32(d[i+2]) << 8 | UInt32(d[i+3])
    }

    private func a32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8((v >> 24) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF))
        d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8(v & 0xFF))
    }

    static func readExact(_ fd: Int32, count: Int) -> Data? {
        var d = Data(count: count)
        var o = 0
        while o < count {
            let n = d.withUnsafeMutableBytes { read(fd, $0.baseAddress! + o, count - o) }
            guard n > 0 else { return nil }
            o += n
        }
        return d
    }

    static func buildRM(data: Data, last: Bool) -> Data {
        var rm = Data(count: 4)
        var l = UInt32(data.count)
        if last { l |= 0x80000000 }
        rm[0] = UInt8((l >> 24) & 0xFF)
        rm[1] = UInt8((l >> 16) & 0xFF)
        rm[2] = UInt8((l >> 8) & 0xFF)
        rm[3] = UInt8(l & 0xFF)
        return rm
    }
}

// Entry point
guard CommandLine.arguments.count >= 3,
      let listenPort = Int(CommandLine.arguments[1]),
      let targetPort = Int(CommandLine.arguments[2]) else {
    fputs("Usage: skyhook-nfs-proxy <listen-port> <target-port>\n", stderr)
    exit(1)
}

let proxy = NFSFilterProxy(listenPort: listenPort, targetPort: targetPort)
guard proxy.start() else {
    fputs("Failed to start proxy on port \(listenPort)\n", stderr)
    exit(1)
}

dispatchMain()
