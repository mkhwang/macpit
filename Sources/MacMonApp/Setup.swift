import AppKit
import MacMonCore
import ServiceManagement

/// 앱 번들에 동봉된 데몬을 관리자 권한으로 설치/제거한다.
/// 유료 Developer ID 없이 동작해야 해서 SMAppService.daemon 대신 osascript 의 관리자 권한 실행을 쓴다.
@MainActor
enum DaemonSetup {
    enum Action { case install, uninstall }

    /// 번들에 동봉된 파일 경로 (소스 빌드가 아닌 swift run 등에서는 nil)
    static var bundled: (daemon: String, ctl: String, install: String, uninstall: String)? {
        let b = Bundle.main.bundleURL
        let d = b.appendingPathComponent("Contents/MacOS/macmond").path
        let c = b.appendingPathComponent("Contents/MacOS/macmonctl").path
        let i = b.appendingPathComponent("Contents/Resources/install-daemon.sh").path
        let u = b.appendingPathComponent("Contents/Resources/uninstall-daemon.sh").path
        let fm = FileManager.default
        guard [d, c, i, u].allSatisfy(fm.fileExists) else { return nil }
        return (d, c, i, u)
    }

    static var available: Bool { bundled != nil }

    /// 관리자 암호 창을 띄우고 실행. 완료 시 (성공, 메시지)
    static func run(_ action: Action, done: @escaping @MainActor (Bool, String) -> Void) {
        guard let p = bundled else { done(false, "앱 번들에 데몬이 없음 — scripts/build.sh 로 만든 앱에서 실행"); return }
        let cmd: String
        switch action {
        case .install: cmd = [p.install, p.daemon, p.ctl, String(getuid())].map(shellQuote).joined(separator: " ")
        case .uninstall: cmd = shellQuote(p.uninstall)
        }
        let prompt = action == .install ? "MacMon 팬 제어 데몬을 설치합니다." : "MacMon 팬 제어 데몬을 제거합니다."
        let script = "do shell script \(appleQuote(cmd)) with prompt \(appleQuote(prompt)) with administrator privileges"
        DispatchQueue.global().async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            let err = Pipe()
            proc.standardError = err
            proc.standardOutput = FileHandle.nullDevice
            var ok = false, msg = ""
            do {
                try proc.run(); proc.waitUntilExit()
                ok = proc.terminationStatus == 0
                msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if msg.contains("-128") { msg = "취소됨" }
            } catch { msg = error.localizedDescription }
            Task { @MainActor in done(ok, ok ? (action == .install ? "설치됨" : "제거됨") : msg) }
        }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// 로그인 시 실행. 소스 설치(install.sh)가 만든 LaunchAgent 도 같은 설정으로 취급한다.
@MainActor
enum LoginItem {
    static var agentPath: String { NSHomeDirectory() + "/Library/LaunchAgents/com.mkhwang.macmon.plist" }

    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: agentPath)
    }

    /// 실패 시 에러 메시지
    static func set(_ on: Bool) -> String? {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                try? FileManager.default.removeItem(atPath: agentPath)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

enum Links {
    static let repo = URL(string: "https://github.com/mkhwang/macmon")!
    static let deviceReport = URL(string: "https://github.com/mkhwang/macmon/issues/new?template=device-report.yml")!
}
