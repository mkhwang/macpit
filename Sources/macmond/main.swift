import Foundation
import MacMonCore

// macmond — root LaunchDaemon. SMC 쓰기(팬 제어) 전담.
// 1초 제어 루프 구조:
//   주기적으로 F{n}Md=1(강제) + F{n}Tg(목표 RPM) 재기록, 안전 온도·센서 실패 시 system 반납, 종료 시 반납.

let version = macmonVersion
setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(s)")
}

let dryRun = ProcessInfo.processInfo.environment["MACMON_DRYRUN"] == "1"
guard getuid() == 0 || dryRun else {
    FileHandle.standardError.write("macmond must run as root\n".data(using: .utf8)!)
    exit(1)
}

let smc = SMC.shared
let sensors = Sensors()
let ctlFans = sensors.controllableFans
let fanControlAvailable = !ctlFans.isEmpty
log("macmond \(version) start — fans=\(sensors.fans.map { "F\($0.index)(\(Int($0.min))-\(Int($0.max))\($0.controllable ? "" : ",ro"))" }) cpuKeys=\(sensors.cpuKeys.count) gpuKeys=\(sensors.gpuKeys.count)")
if !fanControlAvailable {
    log(sensors.fans.isEmpty ? "팬 없음(팬리스) — 모니터링 전용으로 동작" : "제어 가능한 팬 없음 — 모니터링 전용으로 동작")
}

final class State: @unchecked Sendable {
    let lock = NSLock()
    var config = FanConfig()
    var engine = FanPolicyEngine()
    var forced = false
    var lastDecision = FanDecision(percent: nil, reason: "init")
    var controlTemp: Double?
    var snapshot = ThermalSnapshot(cpuAvg: nil, cpuMax: nil, gpuAvg: nil, fans: [])
    var lastError: String?
}
let state = State()
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

if let d = FileManager.default.contents(atPath: daemonConfigPath), let c = try? JSONDecoder().decode(FanConfig.self, from: d) {
    state.config = c
    log("config loaded: mode=\(c.mode.rawValue)")
}
// 팬리스 기기로 옮겨온 설정 등: 제어 불가하면 system 강제
if !fanControlAvailable { state.config.mode = .system }

func saveConfig(_ c: FanConfig) {
    let dir = (daemonConfigPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(c) { FileManager.default.createFile(atPath: daemonConfigPath, contents: d) }
}

// 시작 시점 팬 모드(시스템 기본값) 기억. Apple Silicon M1 Pro 는 3. 이미 1(강제)이면 이전 크래시 잔재 → 0.
let originalModes: [Int: Double] = Dictionary(uniqueKeysWithValues: ctlFans.map { f in
    let m = smc.double("F\(f.index)Md") ?? 0
    return (f.index, m == 1 ? 0 : m)
})
log("original fan modes: \(originalModes)")

/// lock 보유 상태에서 호출
func releaseFans() {
    for f in ctlFans {
        let i = f.index
        do { try smc.write("F\(i)Md", value: originalModes[i] ?? 0) } catch { state.lastError = "release F\(i): \(error)" }
    }
    state.forced = false
}

/// lock 보유 상태에서 호출
func applyPercent(_ p: Double) {
    // 팬마다 Mn/Mx 가 다르므로 같은 % 를 팬별 RPM 으로 환산
    for f in ctlFans {
        let i = f.index
        let mn = smc.double("F\(i)Mn") ?? f.min
        let mx = smc.double("F\(i)Mx") ?? f.max
        guard mx > mn else { continue }
        let rpm = percentToRPM(p, min: mn, max: mx)
        do {
            // thermalmonitord 가 모드를 되돌릴 수 있어서 매 틱 확인 후 재기록
            if (smc.double("F\(i)Md") ?? -1) != 1 { try smc.write("F\(i)Md", value: 1) }
            try smc.write("F\(i)Tg", value: rpm)
            state.lastError = nil
        } catch {
            state.lastError = "apply F\(i): \(error)"
        }
    }
    state.forced = true
}

func tick() {
    state.lock.lock(); defer { state.lock.unlock() }
    let snap = sensors.snapshot()
    state.snapshot = snap
    state.controlTemp = snap.cpuMax
    guard fanControlAvailable else {
        state.lastDecision = FanDecision(percent: nil, reason: "no-fans")
        return
    }
    let d = state.engine.decide(config: state.config, temp: snap.cpuMax)
    if d.reason != state.lastDecision.reason {
        log("decision: \(d.reason) \(d.percent.map { String(format: "%.0f%%", $0) } ?? "-") temp=\(snap.cpuMax.map { String(format: "%.1f", $0) } ?? "-")")
    }
    state.lastDecision = d
    if let p = d.percent { applyPercent(p) } else if state.forced { releaseFans() }
}

// 종료 시 반드시 system 반납
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        log("signal \(sig) — releasing fans")
        state.lock.lock(); releaseFans(); state.lock.unlock()
        unlink(daemonSocketPath)
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

// 이전 크래시로 남은 강제 모드 정리
state.lock.lock(); releaseFans(); state.lock.unlock()

let tickQueue = DispatchQueue(label: "macmond.tick")
let timer = DispatchSource.makeTimerSource(queue: tickQueue)
timer.schedule(deadline: .now(), repeating: 1.0)
timer.setEventHandler { tick() }
timer.resume()

// --- 소켓 서버 ---
func handle(_ fd: Int32) {
    defer { close(fd) }
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let line = DaemonClient.readLine(fd: fd, limit: 64 * 1024)
    var resp = DaemonResponse(ok: true, error: nil, status: nil)
    do {
        let req = try JSONDecoder().decode(DaemonRequest.self, from: line)
        state.lock.lock()
        switch req.cmd {
        case "setConfig":
            if let c = req.config, c.mode != .system, !fanControlAvailable {
                resp.ok = false
                resp.error = sensors.fans.isEmpty ? "이 Mac 은 팬이 없습니다 (팬리스) — 팬 제어 불가" : "제어 가능한 팬이 없습니다"
            } else if var c = req.config {
                c.manualPercent = max(0, min(100, c.manualPercent))
                c.targetTemp = max(40, min(95, c.targetTemp))
                c.safetyTemp = max(60, min(105, c.safetyTemp))
                if c.mode != state.config.mode { state.engine.reset() }
                state.config = c
                saveConfig(c)
                log("config set: mode=\(c.mode.rawValue) manual=\(c.manualPercent) target=\(c.targetTemp)")
            } else { resp.ok = false; resp.error = "missing config" }
        case "status": break
        default: resp.ok = false; resp.error = "unknown cmd \(req.cmd)"
        }
        resp.status = DaemonStatus(version: version, config: state.config, appliedPercent: state.lastDecision.percent,
                                   reason: state.lastDecision.reason, controlTemp: state.controlTemp,
                                   thermal: state.snapshot, lastError: state.lastError,
                                   controllableFans: ctlFans.count)
        state.lock.unlock()
    } catch {
        resp.ok = false; resp.error = "bad request: \(error)"
    }
    if var d = try? JSONEncoder().encode(resp) {
        d.append(0x0a)
        _ = d.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

guard daemonSocketPath.utf8.count < 104 else { log("socket path too long"); exit(1) }
unlink(daemonSocketPath)
let sfd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    let p = Array(daemonSocketPath.utf8); buf.copyBytes(from: p); buf[p.count] = 0
}
let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard bound == 0, listen(sfd, 8) == 0 else { log("socket bind failed errno=\(errno)"); exit(1) }
// 소켓 접근: root + 설치 시 지정한 사용자(MACMON_OWNER_UID)만
let ownerUID = ProcessInfo.processInfo.environment["MACMON_OWNER_UID"].flatMap { uid_t($0) } ?? getuid()
chown(daemonSocketPath, ownerUID, 0)
chmod(daemonSocketPath, 0o600)
log("listening \(daemonSocketPath) owner uid=\(ownerUID)")

DispatchQueue.global().async {
    while true {
        let cfd = accept(sfd, nil, nil)
        if cfd < 0 { continue }
        DispatchQueue.global().async { handle(cfd) }
    }
}

dispatchMain()
