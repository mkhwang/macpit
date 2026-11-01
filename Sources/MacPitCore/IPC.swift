import Foundation

public let daemonSocketPath = ProcessInfo.processInfo.environment["MACPIT_SOCKET"] ?? "/var/run/macpitd.sock"
public let daemonConfigPath = ProcessInfo.processInfo.environment["MACPIT_CONFIG"] ?? "/Library/Application Support/MacPit/config.json"

public struct DaemonRequest: Codable, Sendable {
    public var cmd: String               // "status" | "setConfig"
    public var config: FanConfig?
    public init(cmd: String, config: FanConfig? = nil) { self.cmd = cmd; self.config = config }
}

public struct DaemonStatus: Codable, Sendable {
    public var version: String
    public var config: FanConfig
    public var appliedPercent: Double?
    public var reason: String
    public var controlTemp: Double?
    public var thermal: ThermalSnapshot
    public var lastError: String?
    /// 제어 가능한 팬 수. 0 이면 팬리스(또는 제어 불가) → 모니터링만.
    public var controllableFans: Int
    public init(version: String, config: FanConfig, appliedPercent: Double?, reason: String, controlTemp: Double?, thermal: ThermalSnapshot, lastError: String?, controllableFans: Int) {
        self.version = version; self.config = config; self.appliedPercent = appliedPercent; self.reason = reason
        self.controlTemp = controlTemp; self.thermal = thermal; self.lastError = lastError; self.controllableFans = controllableFans
    }
}

public struct DaemonResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: DaemonStatus?
    public init(ok: Bool, error: String?, status: DaemonStatus?) { self.ok = ok; self.error = error; self.status = status }
}

/// 한 요청 = 한 연결. 요청 JSON 한 줄 → 응답 JSON 한 줄.
public enum DaemonClient {
    public static func send(_ req: DaemonRequest, path: String = daemonSocketPath, timeout: Int = 2) throws -> DaemonResponse {
        guard path.utf8.count < 104 else { throw POSIXError(.ENAMETOOLONG) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let p = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: p)
            buf[p.count] = 0
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }
        var data = try JSONEncoder().encode(req)
        data.append(0x0a)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        let line = readLine(fd: fd)
        return try JSONDecoder().decode(DaemonResponse.self, from: line)
    }

    /// deadline: 연결 전체 읽기 시간 상한 (SO_RCVTIMEO 는 read 1회 단위라 느린 송신자를 못 끊음)
    public static func readLine(fd: Int32, limit: Int = 1 << 20, deadline: Date? = nil) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < limit {
            if let deadline, Date() >= deadline { return Data() }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0a) { break }
        }
        if let i = out.firstIndex(of: 0x0a) { out = out.prefix(upTo: i) }
        return out
    }
}
