import Foundation
import SQLite3

// 메트릭 히스토리.
// 앱이 10초 평균을 SQLite 에 기록, 30일 보관. 조회 시 버킷 평균으로 다운샘플.

public struct HistoryPoint: Sendable, Equatable {
    public var ts: Int64            // unix 초 (버킷 시작)
    public var cpu: Double?         // %
    public var temp: Double?        // CPU 최고 °C
    public var gpu: Double?         // °C
    public var fan: Double?         // 최대 팬 rpm (팬리스면 nil)
    public var mem: Double?         // %
    public var netIn: Double?       // bytes/s
    public var netOut: Double?
    public var diskFree: Double?    // bytes
    public var battery: Double?     // %
    public init(ts: Int64, cpu: Double? = nil, temp: Double? = nil, gpu: Double? = nil, fan: Double? = nil, mem: Double? = nil,
                netIn: Double? = nil, netOut: Double? = nil, diskFree: Double? = nil, battery: Double? = nil) {
        self.ts = ts; self.cpu = cpu; self.temp = temp; self.gpu = gpu; self.fan = fan; self.mem = mem
        self.netIn = netIn; self.netOut = netOut; self.diskFree = diskFree; self.battery = battery
    }
}

public enum HistoryRange: String, CaseIterable, Sendable {
    case hour = "1h", day = "24h", week = "7d", month = "30d"
    public var seconds: Int64 { switch self { case .hour: 3600; case .day: 86400; case .week: 7 * 86400; case .month: 30 * 86400 } }
    public var label: String { switch self { case .hour: "1시간"; case .day: "24시간"; case .week: "7일"; case .month: "30일" } }
    /// 차트 점 ~360개 목표
    public var bucket: Int64 { max(10, seconds / 360) }
}

public let historyDBPath: String = ProcessInfo.processInfo.environment["MACPIT_HISTORY"]
    ?? (NSHomeDirectory() + "/Library/Application Support/MacPit/history.sqlite")

/// 0.1.x(MacMon) 히스토리 DB 를 새 경로로 이동. 새 DB 가 이미 있으면 아무것도 안 함. 이동했으면 true
@discardableResult
public func migrateLegacyHistory(from oldDir: String, to newPath: String) -> Bool {
    let fm = FileManager.default
    let old = oldDir + "/history.sqlite"
    guard fm.fileExists(atPath: old), !fm.fileExists(atPath: newPath) else { return false }
    try? fm.createDirectory(atPath: (newPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    guard (try? fm.moveItem(atPath: old, toPath: newPath)) != nil else { return false }
    for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: old + suffix) {
        try? fm.moveItem(atPath: old + suffix, toPath: newPath + suffix)
    }
    if (try? fm.contentsOfDirectory(atPath: oldDir))?.isEmpty == true { try? fm.removeItem(atPath: oldDir) }
    return true
}

public final class HistoryStore: @unchecked Sendable {
    public static let retention: Int64 = 30 * 86400
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let cols = ["cpu", "temp", "gpu", "fan", "mem", "net_in", "net_out", "disk_free", "battery"]

    public init?(path: String = historyDBPath) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return nil }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("CREATE TABLE IF NOT EXISTS samples (ts INTEGER PRIMARY KEY, " + Self.cols.map { "\($0) REAL" }.joined(separator: ", ") + ")")
        // 센서 그룹 온도: 기기마다 그룹 수가 달라 세로형 테이블
        exec("CREATE TABLE IF NOT EXISTS group_samples (ts INTEGER NOT NULL, gid TEXT NOT NULL, avg REAL, PRIMARY KEY (ts, gid))")
    }

    public func insertGroups(ts: Int64, _ groups: [String: Double]) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO group_samples (ts, gid, avg) VALUES (?, ?, ?)", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        exec("BEGIN")
        for (gid, v) in groups where v.isFinite {
            sqlite3_reset(st)
            sqlite3_bind_int64(st, 1, ts)
            sqlite3_bind_text(st, 2, gid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))   // SQLITE_TRANSIENT
            sqlite3_bind_double(st, 3, v)
            sqlite3_step(st)
        }
        exec("COMMIT")
    }

    /// gid → [(버킷 ts, 평균)]
    public func queryGroups(from: Int64, to: Int64, bucket: Int64) -> [String: [(Int64, Double)]] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let b = max(1, bucket)
        let sql = "SELECT (ts / \(b)) * \(b) AS b, gid, avg(avg) FROM group_samples WHERE ts >= ? AND ts < ? GROUP BY b, gid ORDER BY b"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, from)
        sqlite3_bind_int64(st, 2, to)
        var out: [String: [(Int64, Double)]] = [:]
        while sqlite3_step(st) == SQLITE_ROW {
            guard let c = sqlite3_column_text(st, 1) else { continue }
            out[String(cString: c), default: []].append((sqlite3_column_int64(st, 0), sqlite3_column_double(st, 2)))
        }
        return out
    }

    public func queryGroups(_ r: HistoryRange, now: Int64 = Int64(Date().timeIntervalSince1970)) -> [String: [(Int64, Double)]] {
        queryGroups(from: now - r.seconds, to: now + 1, bucket: r.bucket)
    }

    deinit { sqlite3_close(db) }

    @discardableResult private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    public func insert(_ p: HistoryPoint) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO samples (ts, " + Self.cols.joined(separator: ", ") + ") VALUES (?" + String(repeating: ", ?", count: Self.cols.count) + ")"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, p.ts)
        for (i, v) in [p.cpu, p.temp, p.gpu, p.fan, p.mem, p.netIn, p.netOut, p.diskFree, p.battery].enumerated() {
            if let v, v.isFinite { sqlite3_bind_double(st, Int32(i + 2), v) } else { sqlite3_bind_null(st, Int32(i + 2)) }
        }
        sqlite3_step(st)
    }

    /// [from, to) 구간을 bucket 초 단위로 평균
    public func query(from: Int64, to: Int64, bucket: Int64) -> [HistoryPoint] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        let b = max(1, bucket)
        let sql = "SELECT (ts / \(b)) * \(b) AS b, " + Self.cols.map { "avg(\($0))" }.joined(separator: ", ")
            + " FROM samples WHERE ts >= ? AND ts < ? GROUP BY b ORDER BY b"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, from)
        sqlite3_bind_int64(st, 2, to)
        var out: [HistoryPoint] = []
        func col(_ i: Int32) -> Double? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i) }
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(HistoryPoint(ts: sqlite3_column_int64(st, 0), cpu: col(1), temp: col(2), gpu: col(3), fan: col(4), mem: col(5),
                                    netIn: col(6), netOut: col(7), diskFree: col(8), battery: col(9)))
        }
        return out
    }

    public func query(_ r: HistoryRange, now: Int64 = Int64(Date().timeIntervalSince1970)) -> [HistoryPoint] {
        query(from: now - r.seconds, to: now + 1, bucket: r.bucket)
    }

    public func prune(now: Int64 = Int64(Date().timeIntervalSince1970)) {
        lock.lock(); defer { lock.unlock() }
        exec("DELETE FROM samples WHERE ts < \(now - Self.retention)")
        exec("DELETE FROM group_samples WHERE ts < \(now - Self.retention)")
    }

    public func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM samples", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }
}

/// 2초 샘플을 모아 10초 평균 1행으로 만든다
public struct HistoryAccumulator {
    public let interval: Int64
    private var bucketStart: Int64 = 0
    private var sums: [Double?] = []
    private var counts: [Int] = []
    private var gsum: [String: (Double, Int)] = [:]
    /// 직전 flush 의 센서 그룹 평균
    public private(set) var flushedGroups: [String: Double] = [:]
    public init(interval: Int64 = 10) { self.interval = interval }

    /// 버킷이 바뀌면 직전 버킷의 평균을 반환
    public mutating func add(_ p: HistoryPoint, groups: [String: Double] = [:]) -> HistoryPoint? {
        let b = (p.ts / interval) * interval
        var flushed: HistoryPoint?
        if b != bucketStart, !counts.isEmpty { flushed = flush() }
        if counts.isEmpty { bucketStart = b; sums = Array(repeating: nil, count: 9); counts = Array(repeating: 0, count: 9) }
        for (k, v) in groups where v.isFinite { let o = gsum[k] ?? (0, 0); gsum[k] = (o.0 + v, o.1 + 1) }
        for (i, v) in Self.values(p).enumerated() {
            if let v, v.isFinite { sums[i] = (sums[i] ?? 0) + v; counts[i] += 1 }
        }
        return flushed
    }

    public mutating func flush() -> HistoryPoint? {
        guard !counts.isEmpty else { return nil }
        let avg = (0..<9).map { i in counts[i] > 0 ? sums[i].map { $0 / Double(counts[i]) } : nil }
        counts = []; sums = []
        flushedGroups = gsum.mapValues { $0.0 / Double($0.1) }
        gsum = [:]
        return HistoryPoint(ts: bucketStart, cpu: avg[0], temp: avg[1], gpu: avg[2], fan: avg[3], mem: avg[4],
                            netIn: avg[5], netOut: avg[6], diskFree: avg[7], battery: avg[8])
    }

    static func values(_ p: HistoryPoint) -> [Double?] {
        [p.cpu, p.temp, p.gpu, p.fan, p.mem, p.netIn, p.netOut, p.diskFree, p.battery]
    }
}
