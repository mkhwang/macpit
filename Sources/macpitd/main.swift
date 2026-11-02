import Foundation
import MacPitCore

// macpitd — root LaunchDaemon. SMC 쓰기(팬 제어) 전담.
// 1초 제어 루프 구조:
//   주기적으로 F{n}Md=1(강제) + F{n}Tg(목표 RPM) 재기록, 안전 온도·센서 실패 시 system 반납, 종료 시 반납.

let version = macpitDaemonVersion
setvbuf(stdout, nil, _IOLBF, 0)
// 응답 전에 끊긴 클라이언트에 write → SIGPIPE 기본 동작(종료)이면 팬 반납 없이 죽는다
signal(SIGPIPE, SIG_IGN)

let logPath = "/var/log/macpitd.log"
/// launchd 가 stdout 을 로그 파일로 열어준 경우에만 회전 추적 (터미널 실행 시 stdout 을 가로채지 않음)
let logFollowsFile: Bool = {
    var a = stat(), b = stat()
    return fstat(1, &a) == 0 && stat(logPath, &b) == 0 && a.st_ino == b.st_ino && a.st_dev == b.st_dev
}()

/// newsyslog 가 파일을 rename·압축하면 stdout/stderr fd 는 옛 inode 를 가리킨 채 남는다 → 경로의 inode 가 바뀌면 다시 연다
func reopenLogIfRotated() {
    guard logFollowsFile else { return }
    var a = stat(), b = stat()
    if fstat(1, &a) == 0, stat(logPath, &b) == 0, a.st_ino == b.st_ino, a.st_dev == b.st_dev { return }
    let fd = open(logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    fflush(stdout)
    dup2(fd, 1); dup2(fd, 2)   // stderr(크래시 메시지 등)도 새 파일로
    close(fd)
}

let logLock = NSLock()
func log(_ s: String) {
    logLock.lock(); defer { logLock.unlock() }
    reopenLogIfRotated()
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(s)")
}

let dryRun = ProcessInfo.processInfo.environment["MACPIT_DRYRUN"] == "1"
guard getuid() == 0 || dryRun else {
    FileHandle.standardError.write("macpitd must run as root\n".data(using: .utf8)!)
    exit(1)
}

let smc = SMC.shared
let sensors = Sensors()
let ctlFans = sensors.controllableFans
let fanControlAvailable = !ctlFans.isEmpty
log("macpitd \(version) start — fans=\(sensors.fans.map { "F\($0.index)(\(Int($0.min))-\(Int($0.max))\($0.controllable ? "" : ",ro"))" }) cpuKeys=\(sensors.cpuKeys.count) gpuKeys=\(sensors.gpuKeys.count)")
if !fanControlAvailable {
    log(sensors.fans.isEmpty ? "팬 없음(팬리스) — 모니터링 전용으로 동작" : "제어 가능한 팬 없음 — 모니터링 전용으로 동작")
}

final class State: @unchecked Sendable {
    let lock = NSLock()
    var config = FanConfig()
    var engine = FanPolicyEngine()
    /// SMC 팬 상태를 바꿨을 수 있음(쓰기 시도 포함) → 반납이 끝까지 성공해야 false
    var forced = false
    /// Ftst(진단 잠금) 해제를 요청한 시각. M3+ 에서 Md 쓰기가 허용되기까지 수 초 걸림
    var unlockSince: Date?
    /// 종료 중: tick 이 반납 이후 다시 강제 모드를 쓰지 않도록
    var shuttingDown = false
    var lastDecision = FanDecision(percent: nil, reason: "init")
    var controlTemp: Double?
    var snapshot = ThermalSnapshot(cpuAvg: nil, cpuMax: nil, gpuAvg: nil, fans: [])
    var lastError: String?
}
let state = State()
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

if let d = FileManager.default.contents(atPath: daemonConfigPath), let c = try? JSONDecoder().decode(FanConfig.self, from: d) {
    state.config = c.sanitized()
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

// M3 이상(Mac15,6 등)은 시스템 관리 중 Md=3 이고, 그 상태의 Md 쓰기는 0x82(→0x1082)로 거부된다.
// Ftst=1(진단 잠금 해제)을 쓰면 수 초 뒤 Md 가 0 으로 내려오고 그때부터 Md=1 쓰기가 허용된다.
// 반납은 Md=3 직접 쓰기가 거부되므로 Md=0 → Ftst=0 순서로 쓰고, 시스템이 스스로 Md=3 으로 회수한다.
let hasFtst = smc.double("Ftst") != nil
/// Ftst=1 이후 Md 쓰기가 허용될 때까지 기다리는 상한 (Mac15,6 실측 ~5.6초)
let unlockGrace: TimeInterval = 15

func isNotWritable(_ e: Error) -> Bool {
    if case let SMCError.code(c, _) = e { return c == 0x1082 }
    return false
}

/// lastError 갱신 + 변화가 있을 때만 로그 (매 틱 재시도해도 로그가 넘치지 않게). lock 보유 상태에서 호출
func setError(_ e: String?) {
    if e != state.lastError {
        if let e { log("error: \(e)") } else if state.lastError != nil { log("error cleared") }
    }
    state.lastError = e
}

/// lock 보유 상태에서 호출. 전부 성공해야 forced=false — 실패하면 다음 틱에 다시 시도
func releaseFans() {
    var errs: [String] = []
    if hasFtst && (state.unlockSince != nil || smc.double("Ftst") == 1) {
        for f in ctlFans { try? smc.write("F\(f.index)Md", value: 0) }
        do {
            try smc.write("Ftst", value: 0)
            log(state.unlockSince != nil ? "Ftst=0 — 팬 제어 시스템 반납" : "Ftst=1 잔재(이전 비정상 종료) 정리 — 시스템 반납")
            state.unlockSince = nil
        } catch { errs.append("release Ftst: \(error)") }
    } else {
        for f in ctlFans {
            let i = f.index
            let orig = originalModes[i] ?? 0
            if smc.double("F\(i)Md") == orig { continue }   // 이미 원래 모드 (쓰기 거부 기기에서 헛된 실패 방지)
            do { try smc.write("F\(i)Md", value: orig) } catch { errs.append("release F\(i): \(error)") }
        }
    }
    state.forced = !errs.isEmpty
    setError(errs.isEmpty ? nil : errs.joined(separator: "; "))
}

/// lock 보유 상태에서 호출
func applyPercent(_ p: Double) {
    // 쓰기를 시도하는 순간부터 반납 대상 (일부 팬만 바뀌었거나 Ftst 만 바뀐 상태도 되돌려야 함)
    state.forced = true
    var errs: [String] = []
    // 팬마다 Mn/Mx 가 다르므로 같은 % 를 팬별 RPM 으로 환산
    for f in ctlFans {
        let i = f.index
        let mn = smc.double("F\(i)Mn") ?? f.min
        let mx = smc.double("F\(i)Mx") ?? f.max
        guard mn > 0, mx > mn else { continue }   // Mn 일시 읽기 실패 시 Tg=0(정지) 강제 방지
        let rpm = percentToRPM(p, min: mn, max: mx)
        do {
            // thermalmonitord 가 모드를 되돌릴 수 있어서 매 틱 확인 후 재기록
            if (smc.double("F\(i)Md") ?? -1) != 1 {
                do {
                    try smc.write("F\(i)Md", value: 1)
                } catch where hasFtst && isNotWritable(error) {
                    let now = Date()
                    // 쓴 직후엔 Ftst 읽기가 늦게 반영돼(실측) 같은 틱의 다음 팬이 중복으로 쓰지 않게 2초 유예.
                    // 오래전에 해제했는데 시스템이 Ftst 를 되돌린 경우엔 다시 요청하고 대기 시간도 새로 잰다
                    if state.unlockSince.map({ now.timeIntervalSince($0) > 2 }) ?? true, smc.double("Ftst") != 1 {
                        try smc.write("Ftst", value: 1)
                        log("Ftst=1 — 팬 제어 잠금 해제 요청")
                        state.unlockSince = now
                    }
                    let since = state.unlockSince ?? now
                    state.unlockSince = since
                    if Date().timeIntervalSince(since) < unlockGrace { continue }   // 해제 대기 중: 다음 틱에 재시도
                    throw error
                }
            }
            try smc.write("F\(i)Tg", value: rpm)
        } catch {
            errs.append("apply F\(i): \(error)")
        }
    }
    setError(errs.isEmpty ? nil : errs.joined(separator: "; "))
}

func tick() {
    state.lock.lock(); defer { state.lock.unlock() }
    guard !state.shuttingDown else { return }
    let snap = sensors.snapshot()
    state.snapshot = snap
    state.controlTemp = snap.cpuMax
    guard fanControlAvailable else {
        state.lastDecision = FanDecision(percent: nil, reason: "no-fans")
        return
    }
    let gpuMax = snap.groups.first { $0.id == "gpu" }?.max ?? snap.gpuAvg
    let hottest = [snap.cpuMax, gpuMax].compactMap { $0 }.max()
    let d = state.engine.decide(config: state.config, temp: snap.cpuMax, hottest: hottest)
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
        // 락을 쥔 채로 종료: 반납 직후 대기 중이던 tick 이 강제 모드를 다시 쓰는 경합 방지
        state.lock.lock()
        state.shuttingDown = true
        releaseFans()
        unlink(daemonSocketPath)
        exit(0)
    }
    src.resume()
    signalSources.append(src)
}

// 이전 크래시로 남은 강제 모드 정리
state.lock.lock(); releaseFans(); state.lock.unlock()

let tickQueue = DispatchQueue(label: "macpitd.tick")
let timer = DispatchSource.makeTimerSource(queue: tickQueue)
timer.schedule(deadline: .now(), repeating: 1.0)
timer.setEventHandler { tick() }
timer.resume()

// --- 소켓 서버 ---
func handle(_ fd: Int32) {
    defer { close(fd) }
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let line = DaemonClient.readLine(fd: fd, limit: 64 * 1024, deadline: Date().addingTimeInterval(3))
    var resp = DaemonResponse(ok: true, error: nil, status: nil)
    do {
        let req = try JSONDecoder().decode(DaemonRequest.self, from: line)
        state.lock.lock()
        switch req.cmd {
        case "setConfig":
            if let c = req.config, c.mode != .system, !fanControlAvailable {
                resp.ok = false
                resp.error = sensors.fans.isEmpty ? "이 Mac 은 팬이 없습니다 (팬리스) — 팬 제어 불가" : "제어 가능한 팬이 없습니다"
            } else if let raw = req.config {
                let c = raw.sanitized()
                if c != state.config {   // 같은 설정 반복 전송 시 디스크 쓰기·로그 생략
                    if c.mode != state.config.mode { state.engine.reset() }
                    state.config = c
                    saveConfig(c)
                    log("config set: mode=\(c.mode.rawValue) manual=\(c.manualPercent) target=\(c.targetTemp) systemSafety=\(c.systemSafety)")
                }
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
// 소켓 접근: root + 설치 시 지정한 사용자(MACPIT_OWNER_UID)만
let ownerUID = ProcessInfo.processInfo.environment["MACPIT_OWNER_UID"].flatMap { uid_t($0) } ?? getuid()
chown(daemonSocketPath, ownerUID, 0)
chmod(daemonSocketPath, 0o600)
log("listening \(daemonSocketPath) owner uid=\(ownerUID)")

let connSlots = DispatchSemaphore(value: 4)
DispatchQueue.global().async {
    var lastAcceptErrno: Int32 = 0
    while true {
        let cfd = accept(sfd, nil, nil)
        if cfd < 0 {
            // EMFILE 등 지속 실패 시 busy loop(CPU 100%) 방지
            let e = errno
            if e != EINTR && e != ECONNABORTED {
                if e != lastAcceptErrno { log("accept failed errno=\(e)") }
                lastAcceptErrno = e
                usleep(200_000)
            }
            continue
        }
        lastAcceptErrno = 0
        var one: Int32 = 1
        setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // 동시 처리 상한: 느린/악성 클라이언트가 GCD 스레드를 고갈시키지 못하게. 초과분은 즉시 닫음
        guard connSlots.wait(timeout: .now()) == .success else { close(cfd); continue }
        DispatchQueue.global().async { handle(cfd); connSlots.signal() }
    }
}

dispatchMain()
