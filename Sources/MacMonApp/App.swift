import AppKit
import MacMonCore
import SwiftUI

@MainActor
final class Monitor: ObservableObject {
    @Published var thermal = ThermalSnapshot(cpuAvg: nil, cpuMax: nil, gpuAvg: nil, fans: [])
    @Published var sys = SystemSample()
    @Published var daemon: DaemonStatus?
    @Published var daemonError: String?
    @Published var tempHistory: [Double] = []
    @Published var cpuHistory: [Double] = []
    @Published var config = FanConfig()
    @Published var configDirty = false
    @Published var top = TopProcesses()
    /// 패널이 열려 있을 때만 상위 프로세스 수집 (ps 실행 비용 절약)
    /// MenuBarExtra(.window) 는 닫혀도 onDisappear 가 안 와서 창의 isVisible 로 판단
    weak var panelWindow: NSWindow?
    var forcePanelVisible = false     // 스냅샷용
    var panelVisible: Bool { forcePanelVisible || panelWindow?.isVisible == true }
    /// 메뉴바 라벨 전용 — 문자열이 바뀔 때만 publish 해서 상태 아이템 재그리기 최소화
    let label = MenuLabel()
    /// 메뉴바에 표시할 항목 (UserDefaults 저장)
    @Published var barItems: [BarItem] = BarItem.load() {
        didSet { BarItem.save(barItems); updateLabel() }
    }
    private var tick = 0

    private let sensors = Sensors()
    private let stats = SystemStats()
    private var timer: Timer?
    private let io = DispatchQueue(label: "macmon.io")
    let history = HistoryStore()
    private var acc = HistoryAccumulator()
    private var inserts = 0

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let sensors = self.sensors, stats = self.stats
        tick += 1
        let wantTop = panelVisible && tick % 2 == 1      // 패널 열림 + 4초마다
        io.async {
            if wantTop {
                let tp = topProcesses()
                Task { @MainActor in self.top = tp }
            }
            let t = sensors.snapshot()
            let s = stats.sample()
            var st: DaemonStatus?, err: String?
            do {
                let r = try DaemonClient.send(DaemonRequest(cmd: "status"), timeout: 1)
                st = r.status; err = r.error
            } catch { err = "데몬 미설치/중지 — 팬 제어 불가 (모니터링만)" }
            Task { @MainActor in self.apply(t, s, st, err) }
        }
    }

    private func apply(_ t: ThermalSnapshot, _ s: SystemSample, _ st: DaemonStatus?, _ err: String?) {
        thermal = t; sys = s; daemon = st; daemonError = err
        if let c = st?.config, !configDirty { config = c }
        if let v = t.cpuMax { tempHistory.append(v); if tempHistory.count > 90 { tempHistory.removeFirst() } }
        cpuHistory.append((s.cpuUser + s.cpuSystem) * 100); if cpuHistory.count > 90 { cpuHistory.removeFirst() }
        record(t, s)
        updateLabel()
    }

    private func updateLabel() {
        let title = menuTitle
        if label.title != title { label.title = title }
    }

    /// 2초 샘플 → 10초 평균을 SQLite 에 기록
    private func record(_ t: ThermalSnapshot, _ s: SystemSample) {
        guard let history else { return }
        let p = HistoryPoint(
            ts: Int64(Date().timeIntervalSince1970),
            cpu: (s.cpuUser + s.cpuSystem) * 100, temp: t.cpuMax, gpu: t.gpuAvg,
            fan: t.fans.isEmpty ? nil : t.fans.map(\.actual).max(),
            mem: s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) * 100 : nil,
            netIn: s.netIn, netOut: s.netOut, diskFree: Double(s.diskFree),
            battery: s.batteryPercent.map(Double.init))
        guard let row = acc.add(p, groups: Dictionary(t.groups.map { ($0.id, $0.avg) }, uniquingKeysWith: { a, _ in a })) else { return }
        let groups = acc.flushedGroups
        inserts += 1
        let prune = inserts % 360 == 1      // 시작 직후 + 약 1시간마다
        io.async {
            history.insert(row)
            history.insertGroups(ts: row.ts, groups)
            if prune { history.prune() }
        }
    }

    func push(_ c: FanConfig) {
        config = c; configDirty = true
        io.async {
            let r = try? DaemonClient.send(DaemonRequest(cmd: "setConfig", config: c))
            Task { @MainActor in
                self.configDirty = false
                if let s = r?.status { self.daemon = s; self.config = s.config }
                if r == nil { self.daemonError = "설정 전송 실패" }
            }
        }
    }

    var menuTitle: String {
        BarItem.allCases.filter(barItems.contains).compactMap { item -> String? in
            switch item {
            case .cpu: return "\(Int(((sys.cpuUser + sys.cpuSystem) * 100).rounded()))%"
            case .temp: return thermal.cpuMax.map { "\(Int($0.rounded()))°" } ?? "--°"
            case .mem:
                guard sys.memTotal > 0 else { return nil }
                return "M\(Int((Double(sys.memUsed) / Double(sys.memTotal) * 100).rounded()))%"
            case .gpu: return thermal.gpuAvg.map { "G\(Int($0.rounded()))°" }
            case .fan:
                guard !thermal.fans.isEmpty else { return nil }   // 팬리스면 생략
                let rpm = thermal.fans.map(\.actual).max() ?? 0
                return rpm < 1 ? "0" : String(format: "%.1fk", rpm / 1000)
            case .net: return "↓" + compactRate(sys.netIn)
            }
        }.joined(separator: " ")
    }
}

/// 메뉴바 표시 항목. 순서는 case 순서 고정.
enum BarItem: String, CaseIterable, Identifiable {
    case cpu, temp, mem, gpu, fan, net
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cpu: "CPU 사용률 (17%)"
        case .temp: "CPU 온도 (67°)"
        case .mem: "메모리 사용률 (M74%)"
        case .gpu: "GPU 온도 (G55°)"
        case .fan: "팬 RPM (3.2k)"
        case .net: "네트워크 수신 (↓1.2M)"
        }
    }
    static let defaults: [BarItem] = [.cpu, .temp, .mem, .fan]
    private static let key = "menuBarItems"
    static func load() -> [BarItem] {
        guard let raw = UserDefaults.standard.stringArray(forKey: key) else { return defaults }
        return raw.compactMap(BarItem.init(rawValue:))
    }
    static func save(_ v: [BarItem]) { UserDefaults.standard.set(v.map(\.rawValue), forKey: key) }
}

/// 메뉴바용 짧은 속도 표기: 512K, 1.2M
func compactRate(_ bps: Double) -> String {
    if bps >= 1e9 { return String(format: "%.1fG", bps / 1e9) }
    if bps >= 1e6 { return String(format: "%.1fM", bps / 1e6) }
    return "\(Int((bps / 1e3).rounded()))K"
}

/// 검증용: `MacMon --snapshot out.png` → 패널을 PNG 로 렌더링 후 종료 (스토리지 첫 스캔 완료까지 대기)
@MainActor func runSnapshot(_ path: String) {
    let m = Monitor()
    m.forcePanelVisible = true
    StorageModel.shared.scan()
    func render() {
        writePNG(PanelView().environmentObject(m).background(Color(nsColor: .windowBackgroundColor)), path)
        print("snapshot: \(path) title=\(m.menuTitle)")
        exit(0)
    }
    var waited = 0.0
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        MainActor.assumeIsolated {
            waited += 0.5
            if waited >= 4, !StorageModel.shared.scanning || waited > 90 { render() }
        }
    }
}

/// 검증용: `MacMon --history-snapshot out.png [range]` → 히스토리 창 렌더링
@MainActor func runHistorySnapshot(_ path: String, _ range: String?) {
    let h = HistoryModel.shared
    if let r = range.flatMap(HistoryRange.init(rawValue:)) { h.range = r }
    h.reload()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        writePNG(HistoryView(scrollable: false).frame(width: 760, height: 1150).background(Color(nsColor: .windowBackgroundColor)), path)
        print("history snapshot: \(path) points=\(h.points.count) rows=\(h.rows)")
        exit(0)
    }
}

@MainActor func writePNG<V: View>(_ v: V, _ path: String) {
    let r = ImageRenderer(content: v)
    r.scale = 2
    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

@main
struct MacMonEntry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            _ = NSApplication.shared
            MainActor.assumeIsolated { runSnapshot(args[i + 1]) }
            RunLoop.main.run()
        } else if let i = args.firstIndex(of: "--history-snapshot"), i + 1 < args.count {
            _ = NSApplication.shared
            MainActor.assumeIsolated { runHistorySnapshot(args[i + 1], i + 2 < args.count ? args[i + 2] : nil) }
            RunLoop.main.run()
        } else {
            MacMonApp.main()
        }
    }
}

@MainActor
final class MenuLabel: ObservableObject {
    @Published var title = "--"
}

struct MenuLabelView: View {
    @ObservedObject var label: MenuLabel
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "fanblades")
            if !label.title.isEmpty { Text(label.title).monospacedDigit() }
        }
    }
}

struct MacMonApp: App {
    // @StateObject 로 두면 Monitor 의 모든 변경마다 Scene(=메뉴바 라벨)이 다시 그려진다 → 관찰하지 않는 상수로 보관
    private let m = Monitor()
    init() { _ = StorageModel.shared }   // 패널을 안 열어도 주기 스캔·자동 정리가 돌도록
    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(m)
        } label: {
            MenuLabelView(label: m.label)
        }
        .menuBarExtraStyle(.window)
    }
}
