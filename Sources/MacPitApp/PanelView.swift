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

struct Section<Content: View>: View {
    var title: String
    var icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
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

    var body: some View {
        VStack(spacing: 8) {
            thermalSection
            fanSection
            // 팬리스·제어 불가 기기는 제어 UI 자체를 숨김
            if m.thermal.fans.contains(where: \.controllable) { controlSection }
            systemSection
            StorageSummarySection()
            footer
        }
        .padding(10)
        .frame(width: 340)
        .background {
            // 스냅샷(ImageRenderer)은 NSView 를 못 그려서 제외
            if !m.forcePanelVisible { WindowAccessor { w in if m.panelWindow !== w { m.panelWindow = w } } }
        }
    }

    // MARK: 온도
    var thermalSection: some View {
        Section(title: "온도", icon: "thermometer.medium") {
            HStack(alignment: .firstTextBaseline) {
                Text(m.thermal.cpuMax.map { String(format: "%.0f°", $0) } ?? "--")
                    .font(.system(size: 34, weight: .semibold, design: .rounded)).foregroundStyle(tempColor(m.thermal.cpuMax))
                VStack(alignment: .leading) {
                    Text("CPU 최고 코어").font(.caption)
                    Text("평균 \(fmt(m.thermal.cpuAvg))°  ·  GPU \(fmt(m.thermal.gpuAvg))°").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Sparkline(values: m.tempHistory, range: 30...100, color: tempColor(m.thermal.cpuMax)).frame(height: 36)
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
                        Text(f.mode == 1 ? "강제" : "자동").font(.caption2).padding(.horizontal, 4)
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
                Text("곡선").tag(FanMode.curve)
                Text("목표온도").tag(FanMode.target)
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(m.daemon == nil)

            switch m.config.mode {
            case .system:
                Text("macOS 가 팬을 관리합니다.").font(.caption).foregroundStyle(.secondary)
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
                HStack {
                    ForEach([("조용", FanConfig.quietCurve), ("균형", FanConfig.balancedCurve), ("성능", FanConfig.performanceCurve)], id: \.0) { name, curve in
                        Button(name) { var c = m.config; c.curve = curve; m.push(c) }
                            .buttonStyle(.bordered).tint(m.config.curve == curve ? .accentColor : .gray)
                    }
                }
                Text(m.config.curve.map { "\(Int($0.temp))°→\(Int($0.percent))%" }.joined(separator: "  ")).font(.caption2).foregroundStyle(.secondary)
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
                Text("적용: \(d.appliedPercent.map { "\(Int($0))%" } ?? "시스템") · \(d.reason) · 안전 \(Int(d.config.safetyTemp))°C 이상 100%")
                    .font(.caption2).foregroundStyle(d.reason == "safety" ? .red : .secondary)
                if let e = d.lastError { Text(e).font(.caption2).foregroundStyle(.red) }
            } else if let e = m.daemonError {
                Text(e).font(.caption2).foregroundStyle(.orange)
            }
            setupRow
        }
    }

    /// 데몬 미설치·구버전 → 설치 버튼, 미검증 기종 → 제보 링크
    @ViewBuilder var setupRow: some View {
        if m.daemon == nil || m.daemonOutdated {
            HStack {
                Button(m.daemon == nil ? "팬 제어 설치…" : "데몬 업데이트 (\(m.daemon?.version ?? "") → \(macpitVersion))…") {
                    m.setupDaemon(.install)
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
        Section(title: "시스템", icon: "cpu") {
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
        HStack {
            Text(m.daemon.map { "macpitd \($0.version)" } ?? "macpitd 없음").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Menu("설정") {
                Text("메뉴바 표시")
                ForEach(BarItem.allCases) { item in
                    Toggle(item.label, isOn: Binding(
                        get: { m.barItems.contains(item) },
                        set: { on in
                            if on { if !m.barItems.contains(item) { m.barItems.append(item) } }
                            else { m.barItems.removeAll { $0 == item } }
                        }))
                }
                Divider()
                Button("기본값 (CPU·온도·메모리·팬)") { m.barItems = BarItem.defaults }
                Divider()
                Toggle("로그인 시 실행", isOn: Binding(get: { m.loginEnabled }, set: { m.setLogin($0) }))
                if m.daemon != nil {
                    Button("팬 제어 데몬 제거…") { m.setupDaemon(.uninstall) }.disabled(m.setupBusy || !DaemonSetup.available)
                }
                Divider()
                Link("GitHub · 문제 제보", destination: Links.repo)
            }
            .menuStyle(.borderlessButton).fixedSize().font(.caption)
            Button("히스토리…") { HistoryWindow.show() }.buttonStyle(.borderless).font(.caption)
            Button("종료") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.caption)
        }
    }

    func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "--" }
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
