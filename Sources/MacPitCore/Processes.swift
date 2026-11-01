import Foundation

// CPU·메모리 상위 프로세스.
// 사용자 권한으로는 proc_pidinfo 로 root 프로세스를 못 읽어서 setuid 인 /bin/ps 를 사용한다.

public struct ProcUsage: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    public var cpu: Double       // % (코어 1개 = 100%)
    public var mem: UInt64       // RSS bytes
    public var id: Int32 { pid }
    public init(pid: Int32, name: String, cpu: Double, mem: UInt64) {
        self.pid = pid; self.name = name; self.cpu = cpu; self.mem = mem
    }
}

public struct TopProcesses: Sendable, Equatable {
    public var byCPU: [ProcUsage]
    public var byMem: [ProcUsage]
    public init(byCPU: [ProcUsage] = [], byMem: [ProcUsage] = []) { self.byCPU = byCPU; self.byMem = byMem }
}

/// `ps -axo pid=,pcpu=,rss=,comm=` 출력 파싱. comm 은 공백 포함 경로일 수 있어 앞 3필드 이후 전부를 이름으로.
public func parsePS(_ out: String) -> [ProcUsage] {
    out.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rssKB = UInt64(parts[2]) else { return nil }
        let comm = String(parts[3]).trimmingCharacters(in: .whitespaces)
        // 앱 번들 실행 파일이면 번들 이름이 더 알아보기 쉬움: /Applications/Foo.app/Contents/MacOS/Foo → Foo
        var name = (comm as NSString).lastPathComponent
        if name.isEmpty { name = comm }
        return ProcUsage(pid: pid, name: name, cpu: cpu, mem: rssKB * 1024)
    }
}

public func topProcesses(limit: Int = 5) -> TopProcesses {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "pid=,pcpu=,rss=,comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return TopProcesses() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let all = parsePS(String(decoding: data, as: UTF8.self))
    return TopProcesses(byCPU: Array(all.sorted { $0.cpu > $1.cpu }.prefix(limit)),
                        byMem: Array(all.sorted { $0.mem > $1.mem }.prefix(limit)))
}
