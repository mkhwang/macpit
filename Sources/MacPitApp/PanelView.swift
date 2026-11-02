import MacPitCore
import SwiftUI

func tempColor(_ t: Double?) -> Color {
    guard let t else { return .secondary }
    switch t {
    case ..<60: return .green
    case ..<75: return .yellow
    case ..<88: return .orange
    default: return .red
    }
}

struct Sparkline: View {
    var values: [Double]
    var range: ClosedRange<Double>
    var color: Color
    var body: some View {
        GeometryReader { g in
            Path { p in
                guard values.count > 1 else { return }
                let span = max(range.upperBound - range.lowerBound, 0.001)
                for (i, v) in values.enumerated() {
                    let x = g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
                    let y = g.size.height * (1 - CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span))
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(color, lineWidth: 1.5)
        }
    }
}

final class Flag: ObservableObject { @Published var on = false }
final class PanelLayout: ObservableObject { @Published var contentHeight: CGFloat = 0 }

struct Section<Content: View>: View {
    var title: String
    var icon: String
    /// 있으면 섹션 전체가 클릭 영역 (헤더 오른쪽에 안내 표시)
    var hint: String? = nil
    var onTap: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @StateObject private var hover = Flag()
    private var hovering: Bool { hover.on }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let hint {
                    Spacer()
                    Label(hint, systemImage: "arrow.up.forward.app")
                        .font(.caption2).foregroundStyle(hovering ? Color.accentColor : .secondary)
                }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(hovering ? 0.9 : 0.5)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onTap?() }
        .onHover { h in if onTap != nil, hover.on != h { hover.on = h } }
        .help(hint ?? "")
    }
}

struct Bar: View {
    var fraction: Double
    var color: Color = .accentColor
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: g.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }.frame(height: 6)
    }
}

struct PanelView: View {
    @EnvironmentObject var m: Monitor
    @StateObject private var layout = PanelLayout()
    @State private var confirmTakeover = false
    @State private var confirmQuit = false
    private var contentHeight: CGFloat { layout.contentHeight }

    var sections: some View {
        VStack(spacing: 8) {
            thermalSection
            fanSection
            // 팬리스·제어 불가 기기는 제어 UI 자체를 숨김
            if m.thermal.fans.contains(where: \.controllable) { controlSection }
            systemSection
            StorageSummarySection()
        }
        .padding(10)
    }

    var body: some View {
        if m.forcePanelVisible {
            // 스냅샷(ImageRenderer)은 ScrollView·NSView 를 못 그려서 평면 배치
            VStack(spacing: 0) { sections; footer }.frame(width: 340)
        } else {
            VStack(spacing: 0) {
                ScrollView(.vertical) {
                    sections.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in if abs(layout.contentHeight - h) > 0.5 { layout.contentHeight = h } }
                }
                .scrollIndicators(contentHeight > scrollMax ? .automatic : .never)
                .frame(height: contentHeight > 0 ? min(contentHeight, scrollMax) : nil)
                footer
            }
            .frame(width: 340)
            .background { WindowAccessor { w in if m.panelWindow !== w { m.panelWindow = w } } }
            // MenuBarExtra 창은 내용이 줄어도 스스로 작아지지 않아 위·아래 여백이 생김 → 직접 맞춤
            .onChange(of: contentHeight) { fitWindow() }
        }
    }

    /// 화면보다 길면 스크롤 (푸터 높이·여유분 제외)
    var scrollMax: CGFloat {
        let screen = m.panelWindow?.screen ?? NSScreen.main
        return max(300, (screen?.visibleFrame.height ?? 900) - 70)
    }

    func fitWindow() {
        DispatchQueue.main.async {
            guard let w = m.panelWindow, let v = w.contentView else { return }
            let h = v.fittingSize.height
            guard h > 0, abs(w.frame.height - h) > 0.5 else { return }
            var f = w.frame
            f.origin.y += f.height - h   // 위쪽(메뉴바) 고정
            f.size.height = h
            w.setFrame(f, display: true)
        }
    }

    // MARK: 온도
    var thermalSection: some View {
        Section(title: "온도", icon: "thermometer.medium") {
            HStack(alignment: .firstTextBaseline) {
                Text(m.thermal.cpuMax.map { String(format: "%.0f°", $0) } ?? "--")
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(tempColor(m.thermal.cpuMax))
                VStack(alignment: .leading) {
                    Text("CPU 핫스팟\(cpuSensorCount.map { " · 센서 \($0)개 중 최고" } ?? "")").font(.caption)
                    Text("평균 \(fmt(m.thermal.cpuAvg))°  ·  GPU \(fmt(m.thermal.gpuAvg))°").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .help("CPU 온도 센서 중 가장 뜨거운 지점입니다. Apple Silicon 은 부하 시 100°C 이상도 정상 범위이고, 팬 제어·안전 온도도 이 값을 기준으로 합니다.")
            // 100°C 넘는 구간(M3 Pro 부하 시 정상)이 잘리지 않게 관측 최대에 맞춰 상한을 10° 단위로 올림
            Sparkline(values: m.tempHistory, range: 30...sparkTop(m.tempHistory), color: tempColor(m.thermal.cpuMax)).frame(height: 36)
            // CPU 외 센서 그룹 (기기에 있는 것만)
            let others = m.thermal.groups.filter { $0.id != "cpu" }
            if !others.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(others, id: \.id) { g in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(g.name).font(.caption2).foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text("\(Int(g.avg.rounded()))°").font(.callout.weight(.medium)).monospacedDigit()
                                    .foregroundStyle(tempColor(g.max))
                                if g.count > 1 { Text("↑\(Int(g.max.rounded()))").font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: 팬
    var fanSection: some View {
        Section(title: "팬", icon: "fanblades") {
            if m.thermal.fans.isEmpty {
                Text("이 Mac 은 팬이 없습니다 (팬리스). 온도만 모니터링합니다 — 과열 시 macOS 가 성능을 낮춰 식힙니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(m.thermal.fans, id: \.index) { f in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(m.thermal.fans.count == 1 ? "Fan" : "Fan \(f.index + 1)").font(.callout)
                        if !f.controllable { Text("읽기 전용").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Text("\(Int(f.actual)) rpm").monospacedDigit().font(.callout.weight(.medium))
                        Text(f.mode == 1 ? "MacPit" : "macOS").font(.caption2).padding(.horizontal, 4)
                            .background(Capsule().fill(f.mode == 1 ? Color.orange.opacity(0.3) : Color.green.opacity(0.25)))
                    }
                    Bar(fraction: f.max > 0 ? f.actual / f.max : 0, color: .blue)
                    Text("범위 \(Int(f.min))–\(Int(f.max)) rpm\(f.mode == 1 ? " · 목표 \(Int(f.target))" : "")").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 제어
    var controlSection: some View {
        Section(title: "팬 제어", icon: "slider.horizontal.3") {
            Picker("", selection: Binding(get: { m.config.mode }, set: { var c = m.config; c.mode = $0; m.push(c) })) {
                Text("시스템").tag(FanMode.system)
                Text("수동").tag(FanMode.manual)
                Text("프로필").tag(FanMode.curve)
                Text("목표온도").tag(FanMode.target)
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(m.daemon == nil)
            // 지금 실제로 무엇을 하고 있는지 (설정이 아니라 데몬의 마지막 결정)
            if let d = m.daemon { FanStatusCard(status: d) }

            switch m.config.mode {
            case .system:
                Toggle(isOn: Binding(get: { m.config.systemSafety }, set: { var c = m.config; c.systemSafety = $0; m.push(c) })) {
                    Text("안전 온도 \(Int(m.config.safetyTemp))°C 이상이면 개입").font(.caption)
                }
                .toggleStyle(.checkbox).disabled(m.daemon == nil)
                Text(m.config.systemSafety
                     ? "평소엔 macOS 가 팬을 관리합니다. macOS 는 고온에서 팬 대신 성능을 낮춰 식히므로, 안전 온도를 넘으면 MacPit 이 팬을 올렸다가 식으면 돌려줍니다."
                     : "macOS 가 팬을 관리합니다. 고온에서도 팬을 거의 올리지 않고 성능을 낮춰 식힐 수 있습니다.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .manual:
                HStack {
                    Slider(value: Binding(get: { m.config.manualPercent }, set: { m.config.manualPercent = $0; m.configDirty = true }),
                           in: 0...100, step: 5) { editing in if !editing { m.push(m.config) } }
                    Text("\(Int(m.config.manualPercent))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                }
                let ctl = m.thermal.fans.filter(\.controllable)
                if !ctl.isEmpty {
                    Text(ctl.map { f in
                        let rpm = Int(percentToRPM(m.config.manualPercent, min: f.min, max: f.max))
                        return ctl.count == 1 ? "≈ \(rpm) rpm" : "Fan \(f.index + 1) ≈ \(rpm)"
                    }.joined(separator: " · ") + (ctl.count > 1 ? " rpm" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                }
            case .curve:
                // 선택 상태가 확실히 보이도록 세그먼트. 프리셋과 다른 곡선이면 아무것도 선택 안 됨 + "사용자 정의" 표기
                Picker("", selection: Binding(get: { FanPreset.matching(m.config.curve) },
                                              set: { if let p = $0 { var c = m.config; c.curve = p.curve; m.push(c) } })) {
                    ForEach(FanPreset.allCases) { Text($0.name).tag(Optional($0)) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(m.daemon == nil)
                ProfileChart(curve: m.config.curve, temp: m.daemon?.controlTemp ?? m.thermal.cpuMax,
                             applied: m.daemon?.config.mode == .curve ? m.daemon?.appliedPercent : nil)
                Text((FanPreset.matching(m.config.curve) == nil ? "사용자 정의 · " : "")
                     + "온도에 따라 팬 속도를 정합니다. 그래프 시작점(0%) 아래 온도에서는 macOS 에 맡깁니다.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .target:
                HStack {
                    Slider(value: Binding(get: { m.config.targetTemp }, set: { m.config.targetTemp = $0; m.configDirty = true }),
                           in: 50...90, step: 1) { editing in if !editing { m.push(m.config) } }
                    Text("\(Int(m.config.targetTemp))°C").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text("CPU 최고 코어를 목표 온도 근처로 유지 (PI 제어). 목표보다 3° 이상 낮고 출력 0이면 macOS 에 반납.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let d = m.daemon {
                if let e = d.lastError { Text(e).font(.caption2).foregroundStyle(.red) }
            } else if let e = m.daemonError {
                Text(e).font(.caption2).foregroundStyle(.orange)
            }
            if let e = m.configError { Text(e).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            setupRow
        }
    }

    /// 데몬 미설치·구버전 → 설치 버튼, 미검증 기종 → 제보 링크
    @ViewBuilder var setupRow: some View {
        if m.daemon == nil || m.daemonOutdated {
            HStack {
                Button(m.daemon == nil ? "팬 제어 설치…" : "데몬 업데이트 (\(m.daemon?.version ?? "") → \(macpitDaemonVersion))…") {
                    // 다른 사용자 소유 데몬을 덮어쓰면 그 사용자의 제어권이 조용히 사라진다 → 확인 후 진행
                    if m.foreignDaemonOwner != nil { confirmTakeover = true } else { m.setupDaemon(.install) }
                }
                .alert("다른 사용자의 팬 제어를 가져올까요?", isPresented: $confirmTakeover) {
                    Button("이 계정으로 설치", role: .destructive) { m.setupDaemon(.install) }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("현재 데몬은 uid \(m.foreignDaemonOwner.map(String.init) ?? "?") 사용자가 설치했습니다. 설치하면 그 사용자의 앱에서는 팬 제어가 끊깁니다.")
                }
                .disabled(m.setupBusy || !DaemonSetup.available)
                if m.setupBusy { ProgressView().controlSize(.small) }
            }
            .font(.caption)
            Text(Legacy.daemonInstalled ? "구버전(MacMon) 데몬 감지 — 설치하면 자동으로 교체됩니다."
                 : DaemonSetup.available ? "관리자 암호가 필요합니다. 모니터링·정리는 설치 없이 동작합니다."
                                       : "이 실행 파일에는 데몬이 동봉되어 있지 않습니다. scripts/install.sh 를 쓰세요.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let msg = m.setupMessage { Text(msg).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        if !m.modelTested && !m.thermal.fans.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("\(m.model) 은 팬 제어 미검증 기종").foregroundStyle(.secondary)
                Link("결과 제보", destination: Links.deviceReport)
            }
            .font(.caption2)
        }
    }

    // MARK: 시스템
    var systemSection: some View {
        Section(title: "시스템", icon: "cpu", hint: "활성 상태 보기", onTap: openActivityMonitor) {
            row("CPU", "\(Int((m.sys.cpuUser + m.sys.cpuSystem) * 100))%  (user \(Int(m.sys.cpuUser * 100)) · sys \(Int(m.sys.cpuSystem * 100)))",
                frac: m.sys.cpuUser + m.sys.cpuSystem, color: .purple)
            Sparkline(values: m.cpuHistory, range: 0...100, color: .purple).frame(height: 24)
            procList(m.top.byCPU) { String(format: "%.1f%%", $0.cpu) }
            row("메모리", "\(formatBytes(Double(m.sys.memUsed))) / \(formatBytes(Double(m.sys.memTotal)))",
                frac: m.sys.memTotal > 0 ? Double(m.sys.memUsed) / Double(m.sys.memTotal) : 0, color: .teal)
            procList(m.top.byMem) { formatBytes(Double($0.mem)) }
            row("디스크", "\(formatBytes(Double(m.sys.diskFree))) 남음",
                frac: m.sys.diskTotal > 0 ? 1 - Double(m.sys.diskFree) / Double(m.sys.diskTotal) : 0, color: .indigo)
            HStack {
                Text("네트워크").font(.callout)
                Spacer()
                Text("↓ \(formatBytes(m.sys.netIn))/s  ↑ \(formatBytes(m.sys.netOut))/s").monospacedDigit().font(.caption)
            }
            HStack {
                Text("부하").font(.callout); Spacer()
                Text(String(format: "%.2f", m.sys.load1)).monospacedDigit().font(.caption)
                if let b = m.sys.batteryPercent {
                    Text("· 배터리 \(b)%\(m.sys.batteryCharging ? " ⚡︎" : "")").font(.caption)
                }
            }
        }
    }

    /// 상위 프로세스 5개
    func procList(_ ps: [ProcUsage], value: @escaping (ProcUsage) -> String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(ps) { p in
                HStack {
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(value(p)).monospacedDigit()
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 6)
    }

    func row(_ name: String, _ value: String, frac: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(name).font(.callout); Spacer(); Text(value).monospacedDigit().font(.caption) }
            Bar(fraction: frac, color: color)
        }
    }

    var footer: some View {
        HStack(spacing: 6) {
            Text(m.daemon.map { "macpitd \($0.version)" } ?? "macpitd 없음").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button { SettingsWindow.show(m) } label: { Label("설정", systemImage: "gearshape") }
            Button { HistoryWindow.show() } label: { Label("히스토리", systemImage: "chart.xyaxis.line") }
            Button { if quitNeedsChoice { confirmQuit = true } else { NSApp.terminate(nil) } } label: { Label("종료", systemImage: "power") }
                .help("앱을 종료합니다. 팬 제어 데몬(macpitd)은 앱과 별개로 계속 실행됩니다.")
                .alert("팬 제어를 어떻게 할까요?", isPresented: $confirmQuit) {
                    Button("macOS 에 반납하고 종료") { m.releaseAndQuit() }
                    Button("제어 유지하고 종료") { NSApp.terminate(nil) }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("앱을 종료해도 팬 제어 데몬은 계속 실행되며 현재 설정(\(m.daemon.map { FanRunState(status: $0).title } ?? ""))을 유지합니다. 나중에 반납하려면 앱을 다시 열어 '시스템'을 고르거나 `macpitctl system` 을 실행하세요.")
                }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    /// 데몬이 macOS 가 아닌 MacPit 설정으로 팬을 제어 중이면 종료 시 유지/반납을 고르게 한다
    var quitNeedsChoice: Bool { (m.daemon?.config.mode ?? .system) != .system }

    func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "--" }

    var cpuSensorCount: Int? { m.thermal.groups.first { $0.id == "cpu" }?.count }
}

/// 스파크라인 상한: 최소 100°, 관측 최대 + 5° 를 10° 단위로 올림
func sparkTop(_ values: [Double]) -> Double {
    guard let mx = values.filter(\.isFinite).max() else { return 100 }
    return max(100, ((mx + 5) / 10).rounded(.up) * 10)
}

/// 이 뷰가 올라간 NSWindow 를 알려준다 (패널 열림 여부 판단용)
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(v.window) }
    }
}
