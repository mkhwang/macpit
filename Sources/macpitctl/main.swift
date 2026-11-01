import Foundation
import MacPitCore

// macpitctl — CLI. 센서 읽기(권한 불필요) + 데몬 제어.
//   macpitctl sensors            현재 온도·팬
//   macpitctl keys [prefix]      SMC 키 덤프
//   macpitctl status             데몬 상태
//   macpitctl system             팬을 macOS 에 반납
//   macpitctl manual <0-100>     고정 %
//   macpitctl target <°C>        목표 온도 유지
//   macpitctl curve quiet|balanced|performance

func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }

func printThermal(_ t: ThermalSnapshot) {
    print("CPU avg \(f(t.cpuAvg))°C  max \(f(t.cpuMax))°C  GPU \(f(t.gpuAvg))°C")
    for g in t.groups {
        print(String(format: "  %@ 평균 %.1f°C 최고 %.1f°C (%d개)", g.name, g.avg, g.max, g.count))
    }
    if t.fans.isEmpty { print("Fans: none (팬리스 — 모니터링 전용)") }
    for fan in t.fans {
        print("Fan\(fan.index): \(Int(fan.actual)) rpm (target \(Int(fan.target)), \(Int(fan.min))–\(Int(fan.max)), mode \(fan.mode)\(fan.controllable ? "" : ", 제어 불가"))")
    }
}

func daemon(_ req: DaemonRequest) {
    do {
        let r = try DaemonClient.send(req)
        guard r.ok, let s = r.status else { print("error: \(r.error ?? "?")"); exit(1) }
        print("daemon \(s.version) fans=\(s.thermal.fans.count) controllable=\(s.controllableFans) mode=\(s.config.mode.rawValue) reason=\(s.reason) applied=\(s.appliedPercent.map { String(format: "%.0f%%", $0) } ?? "system")")
        if let e = s.lastError { print("lastError: \(e)") }
        printThermal(s.thermal)
    } catch {
        print("daemon unreachable (\(daemonSocketPath)): \(error)"); exit(2)
    }
}

func current() -> FanConfig {
    (try? DaemonClient.send(DaemonRequest(cmd: "status")))?.status?.config ?? FanConfig()
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "sensors" {
case "sensors":
    let s = Sensors()
    print("cpu keys: \(s.cpuKeys.count), gpu keys: \(s.gpuKeys.count), fans: \(s.fanCount) (controllable \(s.controllableFans.count))")
    printThermal(s.snapshot())
case "keys":
    let prefix = args.count > 1 ? args[1] : ""
    for k in SMC.shared.allKeys() where k.hasPrefix(prefix) {
        if let v = try? SMC.shared.read(k) { print(k, v.type, v.double.map { String(format: "%.2f", $0) } ?? v.bytes.map { String(format: "%02x", $0) }.joined()) }
    }
case "stats":
    let st = SystemStats(); _ = st.sample(); sleep(2); let x = st.sample()
    print(String(format: "cpu %.1f%%  mem %@/%@  net ↓%@/s ↑%@/s  disk free %@  batt %@", (x.cpuUser + x.cpuSystem) * 100,
                 formatBytes(Double(x.memUsed)), formatBytes(Double(x.memTotal)), formatBytes(x.netIn), formatBytes(x.netOut),
                 formatBytes(Double(x.diskFree)), x.batteryPercent.map { "\($0)%" } ?? "-"))
case "status": daemon(DaemonRequest(cmd: "status"))
case "system":
    var c = current(); c.mode = .system; daemon(DaemonRequest(cmd: "setConfig", config: c))
case "manual":
    guard args.count > 1, let p = Double(args[1]) else { print("usage: manual <0-100>"); exit(1) }
    var c = current(); c.mode = .manual; c.manualPercent = p; daemon(DaemonRequest(cmd: "setConfig", config: c))
case "target":
    guard args.count > 1, let t = Double(args[1]) else { print("usage: target <celsius>"); exit(1) }
    var c = current(); c.mode = .target; c.targetTemp = t; daemon(DaemonRequest(cmd: "setConfig", config: c))
case "curve":
    var c = current(); c.mode = .curve
    switch args.count > 1 ? args[1] : "balanced" {
    case "quiet": c.curve = FanConfig.quietCurve
    case "performance": c.curve = FanConfig.performanceCurve
    default: c.curve = FanConfig.balancedCurve
    }
    daemon(DaemonRequest(cmd: "setConfig", config: c))
case "storage":
    let c = StorageCleaner()
    let res = Dictionary(uniqueKeysWithValues: c.scan().map { ($0.id, $0) })
    var group = ""
    for t in cleanTargets {
        guard let e = res[t.id] else { continue }
        if t.group != group { group = t.group; print("[\(group)]") }
        let size = e.available ? formatBytes(Double(e.bytes)) : "-"
        func pad(_ s: String, _ n: Int, left: Bool = false) -> String {
            let sp = String(repeating: " ", count: max(0, n - s.count)); return left ? sp + s : s + sp
        }
        print("  \(pad(t.id, 18)) \(pad(size, 8, left: true))  \(t.risk == .safe ? "safe   " : "CAUTION")  \(t.name)\(e.note.map { " (\($0))" } ?? "")")
    }
    let safe = cleanTargets.filter { $0.risk == .safe }.compactMap { res[$0.id]?.bytes }.reduce(0, +)
    print("safe 합계: \(formatBytes(Double(safe)))")
case "bench":
    // 센서 읽기 비용 측정 (진단용)
    let s = Sensors()
    func ms(_ n: Int, _ f: () -> Void) -> Double {
        let t = DispatchTime.now().uptimeNanoseconds; for _ in 0..<n { f() }
        return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 / Double(n)
    }
    let keys = s.groups.flatMap(\.1).count + s.fans.count * 3
    print(String(format: "SMC 키 1개 읽기: %.3f ms", ms(200) { _ = SMC.shared.double("TB1T") }))
    print(String(format: "snapshot (키 약 %d개): %.1f ms", keys, ms(10) { _ = s.snapshot() }))
    let st = SystemStats(); _ = st.sample()
    print(String(format: "SystemStats.sample: %.1f ms", ms(10) { _ = st.sample() }))
    print(String(format: "topProcesses: %.1f ms", ms(5) { _ = topProcesses() }))
case "top":
    let t = topProcesses(limit: 10)
    print("CPU 상위"); for p in t.byCPU { print(String(format: "  %6.1f%%  %6d  %@", p.cpu, p.pid, p.name)) }
    print("메모리 상위"); for p in t.byMem { print("  \(formatBytes(Double(p.mem)).padding(toLength: 8, withPad: " ", startingAt: 0))  \(p.pid)  \(p.name)") }
case "history":
    // macpitctl history [1h|24h|7d|30d]
    let r = HistoryRange(rawValue: args.count > 1 ? args[1] : "1h") ?? .hour
    guard let h = HistoryStore() else { print("history db 열기 실패: \(historyDBPath)"); exit(1) }
    let pts = h.query(r)
    print("\(historyDBPath)  rows=\(h.count())  range=\(r.label) bucket=\(r.bucket)s points=\(pts.count)")
    let df = DateFormatter(); df.dateFormat = r == .hour ? "HH:mm:ss" : "MM-dd HH:mm"
    for p in pts.suffix(12) {
        print("  \(df.string(from: Date(timeIntervalSince1970: TimeInterval(p.ts))))  cpu \(f(p.cpu))%  temp \(f(p.temp))°  fan \(p.fan.map { "\(Int($0))" } ?? "-")  mem \(f(p.mem))%  ↓\(p.netIn.map { formatBytes($0) } ?? "-")/s")
    }
    if let mx = pts.compactMap(\.temp).max(), let avg = Optional(pts.compactMap(\.temp)), !avg.isEmpty {
        print(String(format: "temp 최고 %.1f° 평균 %.1f°", mx, avg.reduce(0, +) / Double(avg.count)))
    }
case "clean":
    // macpitctl clean <id...>|safe [--yes]   — --yes 없으면 미리보기
    let yes = args.contains("--yes")
    let ids = args.dropFirst().filter { $0 != "--yes" }
    let chosen = ids.contains("safe") ? cleanTargets.filter { $0.risk == .safe } : cleanTargets.filter { ids.contains($0.id) }
    guard !chosen.isEmpty else { print("usage: macpitctl clean <id...>|safe [--yes]  (id 는 macpitctl storage 참고)"); exit(1) }
    let c = StorageCleaner()
    let res = Dictionary(uniqueKeysWithValues: c.scan(chosen).map { ($0.id, $0) })
    for t in chosen { print("  \(t.id): \(formatBytes(Double(res[t.id]?.bytes ?? 0)))\(t.risk == .caution ? "  ⚠︎ \(t.detail)" : "")") }
    guard yes else { print("미리보기만 함. 실제 삭제: --yes"); exit(0) }
    var total: Int64 = 0
    for t in chosen {
        let o = c.clean(t); total += o.freed
        print("  ✓ \(t.id): \(formatBytes(Double(o.freed))) 확보\(o.error.map { "  ✘ \($0)" } ?? "")")
    }
    print("총 \(formatBytes(Double(total))) 확보")
default:
    print("usage: macpitctl sensors|keys [prefix]|status|system|manual <%>|target <°C>|curve <preset>|top|history [1h|24h|7d|30d]|storage|clean <id...>|safe [--yes]")
}
