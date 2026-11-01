import Foundation

// 개발자 캐시·Docker 스토리지 스캔/정리.
// 원칙: 화이트리스트 경로만, home 하위만, 디렉터리 자체는 남기고 내용만 삭제. 사용자 권한으로 동작(root 불필요).

public enum CleanRisk: String, Codable, Sendable {
    case safe       // 다음 빌드/설치 때 자동으로 다시 받는 순수 캐시
    case caution    // 데이터 손실·재작업 가능 (볼륨, 중지 컨테이너, 로컬 설치 아티팩트 등)
}

public enum CleanAction: Sendable {
    case removeContents                 // paths 안의 내용 삭제
    case shell(String)                  // 로그인 셸에서 명령 실행 (사용자 PATH 사용). 실패 시 에러
    case shellOrRemove(String, tool: String) // tool 이 있으면 명령, 없으면 내용 삭제
    case docker([String])               // docker CLI 인자
}

public struct CleanTarget: Identifiable, Sendable {
    public let id: String
    public let group: String
    public let name: String
    public let detail: String
    public let risk: CleanRisk
    public let paths: [String]          // home 기준 상대경로 (크기 측정 + removeContents 대상)
    public let action: CleanAction
    public let dockerType: String?      // `docker system df` 의 Type
}

/// 정리 대상을 쓰는 중인 프로세스 (pgrep -f 확장 정규식). 자동 정리는 실행 중이면 건너뛴다.
public let cleanTargetUsers: [String: (label: String, pattern: String)] = [
    "gradle": ("Gradle", "GradleDaemon|GradleWrapperMain|GradleMain"),
    "jetbrains": ("JetBrains IDE", "\\.app/Contents/MacOS/(idea|pycharm|webstorm|goland|clion|rider|datagrip|phpstorm|rubymine|rustrover|studio)( |$)"),
    "xcode": ("Xcode", "Xcode\\.app/Contents/MacOS/Xcode"),
    "vscode": ("VS Code", "Visual Studio Code\\.app/Contents/MacOS/"),
    "maven": ("Maven", "org\\.codehaus\\.plexus\\.classworlds"),
]

public let cleanTargets: [CleanTarget] = [
    // Node
    .init(id: "npm", group: "Node", name: "npm 캐시", detail: "~/.npm (_cacache·_npx·_logs)", risk: .safe,
          paths: [".npm/_cacache", ".npm/_npx", ".npm/_logs", ".npm/_prebuilds"], action: .removeContents, dockerType: nil),
    .init(id: "pnpm", group: "Node", name: "pnpm store", detail: "pnpm store prune (pnpm 없으면 store 삭제 → 다음 install 때 재다운로드)", risk: .safe,
          paths: ["Library/pnpm/store", ".pnpm-store", ".local/share/pnpm/store"], action: .shellOrRemove("pnpm store prune", tool: "pnpm"), dockerType: nil),
    .init(id: "yarn", group: "Node", name: "Yarn 캐시", detail: "~/Library/Caches/Yarn, ~/.yarn/berry/cache", risk: .safe,
          paths: ["Library/Caches/Yarn", ".yarn/berry/cache"], action: .removeContents, dockerType: nil),
    .init(id: "bun", group: "Node", name: "Bun 캐시", detail: "~/.bun/install/cache", risk: .safe,
          paths: [".bun/install/cache"], action: .removeContents, dockerType: nil),
    .init(id: "node-gyp", group: "Node", name: "node-gyp 헤더", detail: "~/Library/Caches/node-gyp", risk: .safe,
          paths: ["Library/Caches/node-gyp"], action: .removeContents, dockerType: nil),
    .init(id: "browsers", group: "Node", name: "Playwright·Puppeteer 브라우저", detail: "다음 테스트 실행 때 재다운로드", risk: .safe,
          paths: ["Library/Caches/ms-playwright", ".cache/puppeteer"], action: .removeContents, dockerType: nil),
    // JVM
    .init(id: "gradle", group: "JVM", name: "Gradle 캐시", detail: "~/.gradle/caches·wrapper/dists·daemon — 빌드 중엔 피할 것", risk: .safe,
          paths: [".gradle/caches", ".gradle/wrapper/dists", ".gradle/daemon"], action: .removeContents, dockerType: nil),
    .init(id: "maven", group: "JVM", name: "Maven 로컬 저장소", detail: "~/.m2/repository — mvn install 한 로컬 아티팩트도 지워짐", risk: .caution,
          paths: [".m2/repository"], action: .removeContents, dockerType: nil),
    .init(id: "jetbrains", group: "JVM", name: "JetBrains 캐시·로그", detail: "인덱스 재생성됨 — IDE 종료 후 권장", risk: .safe,
          paths: ["Library/Caches/JetBrains", "Library/Logs/JetBrains"], action: .removeContents, dockerType: nil),
    // Apple
    .init(id: "xcode", group: "Apple", name: "Xcode DerivedData", detail: "~/Library/Developer/Xcode/DerivedData", risk: .safe,
          paths: ["Library/Developer/Xcode/DerivedData"], action: .removeContents, dockerType: nil),
    .init(id: "xcode-device", group: "Apple", name: "iOS DeviceSupport", detail: "기기 연결 시 다시 생성", risk: .safe,
          paths: ["Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/CoreSimulator/Caches"], action: .removeContents, dockerType: nil),
    .init(id: "spm", group: "Apple", name: "SwiftPM·CocoaPods 캐시", detail: "~/Library/Caches/org.swift.swiftpm, CocoaPods", risk: .safe,
          paths: ["Library/Caches/org.swift.swiftpm", "Library/Caches/CocoaPods"], action: .removeContents, dockerType: nil),
    // 기타 언어/도구
    .init(id: "python", group: "기타", name: "pip·uv 캐시", detail: "~/Library/Caches/pip, ~/.cache/uv", risk: .safe,
          paths: ["Library/Caches/pip", ".cache/uv"], action: .removeContents, dockerType: nil),
    .init(id: "go", group: "기타", name: "Go 빌드 캐시", detail: "~/Library/Caches/go-build", risk: .safe,
          paths: ["Library/Caches/go-build"], action: .removeContents, dockerType: nil),
    .init(id: "cargo", group: "기타", name: "Cargo 레지스트리 캐시", detail: "~/.cargo/registry/cache", risk: .safe,
          paths: [".cargo/registry/cache"], action: .removeContents, dockerType: nil),
    .init(id: "brew", group: "기타", name: "Homebrew 다운로드", detail: "brew cleanup --prune=all", risk: .safe,
          paths: ["Library/Caches/Homebrew"], action: .shellOrRemove("brew cleanup --prune=all -s", tool: "brew"), dockerType: nil),
    .init(id: "vscode", group: "기타", name: "VS Code 캐시", detail: "Code/Cache·CachedData — VS Code 종료 후 권장", risk: .safe,
          paths: ["Library/Application Support/Code/Cache", "Library/Application Support/Code/CachedData"], action: .removeContents, dockerType: nil),
    .init(id: "trash", group: "기타", name: "휴지통", detail: "~/.Trash — 복구 불가", risk: .caution,
          paths: [".Trash"], action: .removeContents, dockerType: nil),
    // Docker — 크기는 `docker system df` 의 회수 가능량
    .init(id: "docker-build", group: "Docker", name: "빌드 캐시", detail: "docker builder prune -a", risk: .safe,
          paths: [], action: .docker(["builder", "prune", "-a", "-f"]), dockerType: "Build Cache"),
    .init(id: "docker-images", group: "Docker", name: "미사용 이미지", detail: "docker image prune -a — 컨테이너가 안 쓰는 이미지 전부 (push 안 한 로컬 빌드 이미지도 삭제)", risk: .caution,
          paths: [], action: .docker(["image", "prune", "-a", "-f"]), dockerType: "Images"),
    .init(id: "docker-containers", group: "Docker", name: "중지된 컨테이너", detail: "docker container prune — 컨테이너 내부 변경분 손실", risk: .caution,
          paths: [], action: .docker(["container", "prune", "-f"]), dockerType: "Containers"),
    .init(id: "docker-volumes", group: "Docker", name: "미사용 볼륨", detail: "docker volume prune -a — DB 데이터 등 영구 삭제", risk: .caution,
          paths: [], action: .docker(["volume", "prune", "-a", "-f"]), dockerType: "Local Volumes"),
]

public struct ScanEntry: Codable, Sendable, Equatable {
    public var id: String
    public var bytes: Int64          // 디렉터리: 실사용량, Docker: 회수 가능량
    public var available: Bool       // 경로 존재 / Docker 동작 중
    public var note: String?         // Docker: "13.58GB 중 5.04GB 회수 가능" 등
}

public struct CleanOutcome: Sendable {
    public var id: String
    public var freed: Int64
    public var error: String?
}

public final class StorageCleaner: @unchecked Sendable {
    public let home: String
    private let fm = FileManager.default

    /// MACPIT_HOME: 검증용 가짜 home
    public init(home: String? = nil) {
        self.home = home ?? ProcessInfo.processInfo.environment["MACPIT_HOME"] ?? NSHomeDirectory()
    }

    // MARK: 경로 안전

    /// 존재하는 경로만 반환. realpath 기준으로 home 하위(home 자체 제외)여야 함 → home 밖 가리키는 심볼릭 링크 거부.
    /// nil + rejected=true 면 안전 검사 실패, rejected=false 면 단순히 없음.
    func safeURL(_ rel: String) -> URL? { resolve(rel).url }

    func resolve(_ rel: String) -> (url: URL?, rejected: Bool) {
        guard !rel.isEmpty, !rel.hasPrefix("/"), !rel.split(separator: "/").contains("..") else { return (nil, true) }
        let url = URL(fileURLWithPath: home).appendingPathComponent(rel)
        guard fm.fileExists(atPath: url.path) else { return (nil, false) }
        guard let real = realpath(url.path, nil), let realHome = realpath(home, nil) else { return (nil, true) }
        defer { free(real); free(realHome) }
        let r = String(cString: real), h = String(cString: realHome) + "/"
        guard r.hasPrefix(h), r.count > h.count else { return (nil, true) }
        // 중간 경로가 home 안의 다른 곳을 가리키는 심링크면(예: ~/.m2/repository → ~/work/shared) 거부
        guard r.hasSuffix("/" + rel) else { return (nil, true) }
        return (url, false)
    }

    public func directorySize(_ url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func pathsSize(_ t: CleanTarget) -> (Int64, Bool) {
        var total: Int64 = 0, exists = false
        for p in t.paths {
            guard let u = safeURL(p) else { continue }
            exists = true
            total += directorySize(u)
        }
        return (total, exists)
    }

    // MARK: 스캔

    public func scan(_ targets: [CleanTarget] = cleanTargets) -> [ScanEntry] {
        let df = targets.contains { $0.dockerType != nil } ? dockerDF() : nil
        var out = [ScanEntry?](repeating: nil, count: targets.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: targets.count) { i in
            let t = targets[i]
            let e: ScanEntry
            if let type = t.dockerType {
                if let row = df?[type] {
                    e = ScanEntry(id: t.id, bytes: row.reclaimable, available: true,
                                  note: "전체 \(formatBytes(Double(row.size))) · \(row.count)개 중 회수 가능")
                } else {
                    e = ScanEntry(id: t.id, bytes: 0, available: false, note: dockerBinary() == nil ? "Docker 미설치" : "Docker 꺼짐")
                }
            } else {
                let (b, ok) = pathsSize(t)
                e = ScanEntry(id: t.id, bytes: b, available: ok, note: nil)
            }
            lock.lock(); out[i] = e; lock.unlock()
        }
        return out.compactMap { $0 }
    }

    // MARK: 정리

    /// 대상을 쓰는 프로세스가 실행 중이면 그 이름
    public func busyUser(_ t: CleanTarget) -> String? {
        guard let u = cleanTargetUsers[t.id] else { return nil }
        return run("/usr/bin/pgrep", ["-f", u.pattern], timeout: 5).status == 0 ? u.label : nil
    }

    public func clean(_ t: CleanTarget) -> CleanOutcome {
        switch t.action {
        case .docker(let args):
            let before = dockerDF()?[t.dockerType ?? ""]?.reclaimable ?? 0
            guard let bin = dockerBinary() else { return CleanOutcome(id: t.id, freed: 0, error: "Docker 미설치") }
            let r = run(bin, args, timeout: 600)
            if r.status != 0 { return CleanOutcome(id: t.id, freed: 0, error: "docker \(args.joined(separator: " ")): \(r.output.suffix(300))") }
            // prune 출력의 "Total reclaimed space: 1.2GB" 우선, 없으면 df 차이
            let reclaimed = r.output.components(separatedBy: "\n").last { $0.contains("reclaimed space") }
                .flatMap { $0.split(separator: ":").last }.map { parseDockerSize(String($0)) }
            let after = dockerDF()?[t.dockerType ?? ""]?.reclaimable ?? 0
            return CleanOutcome(id: t.id, freed: reclaimed ?? max(0, before - after), error: nil)
        case .shell(let cmd):
            return runShellClean(t, cmd)
        case .shellOrRemove(let cmd, let tool):
            if shell("command -v \(tool)", timeout: 10, exec: false).status == 0 { return runShellClean(t, cmd) }
            return removeContents(t)
        case .removeContents:
            return removeContents(t)
        }
    }

    private func runShellClean(_ t: CleanTarget, _ cmd: String) -> CleanOutcome {
        let (before, _) = pathsSize(t)
        let r = shell(cmd, timeout: 900)
        let (after, _) = pathsSize(t)
        return CleanOutcome(id: t.id, freed: max(0, before - after), error: r.status == 0 ? nil : "\(cmd): \(r.output.suffix(300))")
    }

    private func removeContents(_ t: CleanTarget) -> CleanOutcome {
        var freed: Int64 = 0
        var errors: [String] = []
        for p in t.paths {
            let (u, rejected) = resolve(p)
            if rejected { errors.append("거부된 경로(home 밖): \(p)") }
            guard let root = u else { continue }
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: []) else { continue }
            for item in items {
                let size = directorySize(item)
                do { try fm.removeItem(at: item); freed += size }   // 심볼릭 링크는 링크만 삭제됨
                catch { errors.append("\(item.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        let err = errors.isEmpty ? nil : "\(errors.count)개 실패: " + errors.prefix(3).joined(separator: "; ")
        return CleanOutcome(id: t.id, freed: freed, error: err)
    }

    // MARK: Docker

    public struct DockerRow: Sendable { public var size: Int64; public var reclaimable: Int64; public var count: Int }

    public func dockerBinary() -> String? {
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "\(home)/.orbstack/bin/docker",
                          "\(home)/.docker/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// nil = Docker 미설치 또는 데몬 꺼짐
    public func dockerDF() -> [String: DockerRow]? {
        guard let bin = dockerBinary() else { return nil }
        let r = run(bin, ["system", "df", "--format", "{{json .}}"], timeout: 20)
        guard r.status == 0 else { return nil }
        var out: [String: DockerRow] = [:]
        for line in r.output.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let type = o["Type"] as? String else { continue }
            let recl = (o["Reclaimable"] as? String).map { String($0.split(separator: " ").first ?? "") } ?? "0B"
            out[type] = DockerRow(size: parseDockerSize(o["Size"] as? String ?? "0B"),
                                  reclaimable: parseDockerSize(recl),
                                  count: Int(o["TotalCount"] as? String ?? "") ?? 0)
        }
        return out
    }

    // MARK: 프로세스

    struct RunResult { var status: Int32; var output: String }

    func run(_ exe: String, _ args: [String], timeout: TimeInterval) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        // GUI 앱 PATH 는 최소값 → docker credential helper 등 탐색용으로 보강
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(home)/.docker/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return RunResult(status: -1, output: "\(error)") }
        // 출력 버퍼가 차서 막히지 않게 별도 스레드에서 수집. data 는 done 신호 이후에만 읽는다
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { box.data = pipe.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            return RunResult(status: -2, output: "timeout")
        }
        guard done.wait(timeout: .now() + 5) == .success else { return RunResult(status: p.terminationStatus, output: "") }
        return RunResult(status: p.terminationStatus, output: String(decoding: box.data, as: UTF8.self))
    }

    /// 로그인 셸 → nvm/volta/brew 등 사용자 PATH 적용
    func shell(_ cmd: String, timeout: TimeInterval, exec: Bool = true) -> RunResult {
        // exec: zsh 가 명령으로 대체돼 타임아웃 시 terminate 가 실제 작업 프로세스에 닿는다 (손자 프로세스 잔존 방지)
        run("/bin/zsh", ["-lc", exec ? "exec " + cmd : cmd], timeout: timeout)
    }
}

/// Docker 크기 문자열("13.58GB", "167.9kB", "0B") → bytes. Docker 는 10진 단위.
public func parseDockerSize(_ s: String) -> Int64 {
    let t = s.trimmingCharacters(in: .whitespaces)
    let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
    for (u, m) in units where t.hasSuffix(u) {
        if let v = Double(t.dropLast(u.count).trimmingCharacters(in: .whitespaces)) { return Int64(v * m) }
    }
    return 0
}
