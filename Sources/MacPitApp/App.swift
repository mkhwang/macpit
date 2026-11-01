import AppKit
import MacPitCore
import SwiftUI

@MainActor
final class Monitor: ObservableObject {
    @Published var thermal = ThermalSnapshot(cpuAvg: nil, cpuMax: nil, gpuAvg: nil, fans: [])
    @Published var sys = SystemSample()
    @Published var daemon: DaemonStatus?
    @Published var daemonError: String?
    /// 데몬 설치/제거 진행 상태
    @Published var setupBusy = false
    @Published var setupMessage: String?
    @Published var loginEnabled = LoginItem.enabled
    let model = hardwareModel()
    var modelTested: Bool { fanControlTestedModels.contains(model) }
    /// 데몬이 앱과 다른 버전이면 재설치 권장
    var daemonOutdated: Bool { daemon.map { $0.version != macpitDaemonVersion } ?? false }
    @Published var tempHistory: [Double] = []
    @Published var cpuHistory: [Double] = []
    @Published var config = FanConfig()
    @Published var configDirty = false
    @Published var top = TopProcesses()
    /// 패널이 열려 있을 때만 상위 프로세스 수집 (ps 실행 비용 절약)
    /// MenuBarExtra(.window) 는 닫혀도 onDisappear 가 안 와서 창의 isVisible 로 판단
    weak var panelWindow: NSWindow? {
        didSet {
            guard panelWindow !== oldValue else { return }
            if let o = visObserver { NotificationCenter.default.removeObserver(o); visObserver = nil }
            guard let w = panelWindow else { return }
            // 패널이 다시 보이는 순간 숨겨져 있던 동안의 최신 값을 반영
            visObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.panelVisible == true { self?.flushPending() } }
            }
            if panelVisible { flushPending() }   // 첫 오픈: 창을 알게 된 시점에 이미 보이는 중
        }
    }
    private var visObserver: NSObjectProtocol?
    /// 패널이 닫혀 있는 동안 받은 최신 샘플 (화면 갱신 없이 보관)
    private var pending: (ThermalSnapshot, SystemSample, DaemonStatus?, String?)?
    private var curT = ThermalSnapshot(cpuAvg: nil, cpuMax: nil, gpuAvg: nil, fans: [])
    private var curS = SystemSample()
    private var bgTemp: [Double] = [], bgCPU: [Double] = []
    var forcePanelVisible = false     // 스냅샷용
    var panelVisible: Bool { forcePanelVisible || panelWindow?.isVisible == true }
    /// 메뉴바 라벨 전용 — 문자열이 바뀔 때만 publish 해서 상태 아이템 재그리기 최소화
    let label = MenuLabel()
    /// 메뉴바에 표시할 항목 (UserDefaults 저장)
    @Published var barItems: [BarItem] = BarItem.load() {
        didSet { BarItem.save(barItems); updateLabel() }
    }
    /// 메뉴바 항목 표시 순서 (꺼진 항목 포함, 설정 창에서 드래그로 변경)
    @Published var barOrder: [BarItem] = BarItem.loadOrder() {
        didSet { BarItem.saveOrder(barOrder); barItems = barOrder.filter(barItems.contains) }
    }
    func setBarItem(_ item: BarItem, _ on: Bool) {
        var s = Set(barItems)
        if on { s.insert(item) } else { s.remove(item) }
        barItems = barOrder.filter(s.contains)
    }
    func resetBarItems() { barOrder = BarItem.allCases; barItems = BarItem.defaults }
    private var tick = 0

    private let sensors = Sensors()
    private let stats = SystemStats()
    private var timer: Timer?
    private let io = DispatchQueue(label: "macpit.io")
    let history = HistoryStore()
    private var acc = HistoryAccumulator()
    private var inserts = 0

    init() {
        barItems = barOrder.filter(barItems.contains)
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

    func setupDaemon(_ action: DaemonSetup.Action) {
        setupBusy = true; setupMessage = nil
        DaemonSetup.run(action) { ok, msg in
            self.setupBusy = false
            self.setupMessage = ok ? nil : msg
            self.refresh()
        }
    }

    func setLogin(_ on: Bool) {
        setupMessage = LoginItem.set(on)
        loginEnabled = LoginItem.enabled
    }

    private func apply(_ t: ThermalSnapshot, _ s: SystemSample, _ st: DaemonStatus?, _ err: String?) {
        curT = t; curS = s
        if let v = t.cpuMax { bgTemp.append(v); if bgTemp.count > 90 { bgTemp.removeFirst() } }
        bgCPU.append((s.cpuUser + s.cpuSystem) * 100); if bgCPU.count > 90 { bgCPU.removeFirst() }
        // 패널이 닫혀 있으면 @Published 를 건드리지 않음 → 숨은 SwiftUI 트리 재계산 0
        if panelVisible { publish(t, s, st, err) } else { pending = (t, s, st, err) }
        record(t, s)
        updateLabel()
    }

    private func publish(_ t: ThermalSnapshot, _ s: SystemSample, _ st: DaemonStatus?, _ err: String?) {
        pending = nil
        thermal = t; sys = s; daemon = st; daemonError = err
        if let c = st?.config, !configDirty { config = c }
        tempHistory = bgTemp; cpuHistory = bgCPU
    }

    func flushPending() { if let p = pending { publish(p.0, p.1, p.2, p.3) } }

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
        barItems.compactMap { item -> String? in
            switch item {
            case .cpu: return "\(Int(((curS.cpuUser + curS.cpuSystem) * 100).rounded()))%"
            case .temp: return curT.cpuMax.map { "\(Int($0.rounded()))°" } ?? "--°"
            case .mem:
                guard curS.memTotal > 0 else { return nil }
                return "M\(Int((Double(curS.memUsed) / Double(curS.memTotal) * 100).rounded()))%"
            case .gpu: return curT.gpuAvg.map { "G\(Int($0.rounded()))°" }
            case .fan:
                guard !curT.fans.isEmpty else { return nil }   // 팬리스면 생략
                let rpm = curT.fans.map(\.actual).max() ?? 0
                return rpm < 1 ? "0" : String(format: "%.1fk", rpm / 1000)
            case .net: return "↓" + compactRate(curS.netIn)
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
    private static let orderKey = "menuBarOrder"
    /// 저장된 순서 + 새로 생긴 항목은 뒤에 (구버전은 기본 순서)
    static func loadOrder() -> [BarItem] {
        var order: [BarItem] = []
        for i in (UserDefaults.standard.stringArray(forKey: orderKey) ?? []).compactMap(BarItem.init(rawValue:)) where !order.contains(i) { order.append(i) }
        return order + allCases.filter { !order.contains($0) }
    }
    static func saveOrder(_ v: [BarItem]) { UserDefaults.standard.set(v.map(\.rawValue), forKey: orderKey) }
}

/// 메뉴바용 짧은 속도 표기: 512K, 1.2M
func compactRate(_ bps: Double) -> String {
    if bps >= 1e9 { return String(format: "%.1fG", bps / 1e9) }
    if bps >= 1e6 { return String(format: "%.1fM", bps / 1e6) }
    return "\(Int((bps / 1e3).rounded()))K"
}

/// 검증용: `MacPit --snapshot out.png` → 패널을 PNG 로 렌더링 후 종료 (스토리지 첫 스캔 완료까지 대기)
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

/// 검증용: `MacPit --history-snapshot out.png [range]` → 히스토리 창 렌더링
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

/// 검증용: `MacPit --ui-test <dir>` → 실제 NSWindow 에 패널을 띄우고 팬 모드를 바꿔가며 창 높이 추적 + 실제 컨트롤 캡처
@MainActor func runUITest(_ dir: String) {
    let m = Monitor()
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 1400), styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = NSHostingView(rootView: PanelView().environmentObject(m))
    w.setFrameTopLeftPoint(NSPoint(x: 0, y: (NSScreen.main?.visibleFrame.maxY ?? 1000)))
    w.orderFrontRegardless()
    func cap(_ v: NSView, _ name: String) {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
    let modes: [FanMode] = [.system, .system, .curve, .system, .curve, .manual]
    var i = 0
    Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { t in
        MainActor.assumeIsolated {
            if i > 0, let v = w.contentView {
                print("mode=\(modes[i - 1].rawValue) window=\(Int(w.frame.height)) fitting=\(Int(v.fittingSize.height)) top=\(Int(w.frame.maxY))")
                cap(v, "panel-\(i)-\(modes[i - 1].rawValue)")
            }
            if i == modes.count {
                t.invalidate()
                let saved = (m.barOrder, m.barItems)
                print("bar before: \(m.barOrder.map(\.rawValue)) title=\(m.menuTitle)")
                m.barOrder.move(fromOffsets: IndexSet(integer: m.barOrder.firstIndex(of: .fan)!), toOffset: 0)
                m.setBarItem(.net, true)
                print("bar after:  \(m.barOrder.map(\.rawValue)) title=\(m.menuTitle) saved=\(UserDefaults.standard.stringArray(forKey: "menuBarOrder") ?? [])")
                m.barOrder = saved.0; m.barItems = saved.1
                let sw = NSWindow(contentRect: NSRect(x: 400, y: 200, width: 380, height: 460), styleMask: [.titled], backing: .buffered, defer: false)
                sw.contentView = NSHostingView(rootView: SettingsView().environmentObject(m))
                sw.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { cap(sw.contentView!, "settings"); exit(0) }
                return
            }
            m.panelWindow = w
            m.configDirty = true; m.config.mode = modes[i]
            i += 1
        }
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
struct MacPitEntry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            _ = NSApplication.shared
            MainActor.assumeIsolated { runSnapshot(args[i + 1]) }
            RunLoop.main.run()
        } else if let i = args.firstIndex(of: "--ui-test"), i + 1 < args.count {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            MainActor.assumeIsolated { runUITest(args[i + 1]) }
            RunLoop.main.run()
        } else if let i = args.firstIndex(of: "--history-snapshot"), i + 1 < args.count {
            _ = NSApplication.shared
            MainActor.assumeIsolated { runHistorySnapshot(args[i + 1], i + 2 < args.count ? args[i + 2] : nil) }
            RunLoop.main.run()
        } else {
            Legacy.migrate()
            MacPitApp.main()
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

struct MacPitApp: App {
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
