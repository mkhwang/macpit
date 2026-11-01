import AppKit
import Charts
import MacPitCore
import SwiftUI

@MainActor
final class HistoryModel: ObservableObject {
    static let shared = HistoryModel()
    @Published var range: HistoryRange = .day { didSet { if timer != nil { start() } else { reload() } } }
    @Published var points: [HistoryPoint] = []
    @Published var groups: [String: [(Int64, Double)]] = [:]
    @Published var rows = 0
    private let store = HistoryStore()
    private let q = DispatchQueue(label: "macpit.history")
    private var timer: Timer?

    func reload() {
        guard let store else { return }
        let r = range
        q.async {
            let p = store.query(r), g = store.queryGroups(r), n = store.count()
            Task { @MainActor in self.points = p; self.groups = g; self.rows = n }
        }
    }

    func start() {
        reload()
        timer?.invalidate()
        // 30d 범위(버킷 2시간)를 30초마다 재집계할 필요 없음 → 버킷 길이에 맞춤 (최소 30초)
        timer = Timer.scheduledTimer(withTimeInterval: Double(max(30, range.bucket)), repeats: true) { [weak self] _ in Task { @MainActor in self?.reload() } }
    }
    /// 창이 닫히면 차트 데이터도 버린다 (다시 열면 reload)
    func stop() { timer?.invalidate(); timer = nil; points = []; groups = [:] }
}

@MainActor
enum HistoryWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "히스토리"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HistoryView())
            w.center()
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                Task { @MainActor in
                    HistoryModel.shared.stop()
                    // 닫힌 창의 NSHostingView·Charts 뷰 트리를 붙잡고 있지 않도록 창째 해제
                    if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
                    closeObserver = nil; window = nil
                }
            }
            window = w
        }
        HistoryModel.shared.start()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// 차트 1개에 그릴 계열
struct Series {
    var name: String
    var color: Color
    var points: [(Int64, Double)]
    /// HistoryPoint 열 하나에서 계열 생성
    init(name: String, color: Color, from pts: [HistoryPoint], _ value: (HistoryPoint) -> Double?) {
        self.name = name; self.color = color
        self.points = pts.compactMap { p in value(p).map { (p.ts, $0) } }
    }
    init(name: String, color: Color, points: [(Int64, Double)]) {
        self.name = name; self.color = color; self.points = points
    }
}

/// 센서 그룹 차트 색 (sensorGroupDefs 순서와 무관하게 id 고정)
let groupColors: [String: Color] = ["cpu": .orange, "gpu": .pink, "mem": .teal, "ssd": .indigo, "battery": .yellow,
                                    "airflow": .blue, "palm": .brown, "wifi": .green, "charger": .purple]

struct HistoryView: View {
    @ObservedObject var h = HistoryModel.shared
    var scrollable = true   // 스냅샷(ImageRenderer)은 ScrollView 를 못 그려서 false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $h.range) {
                    ForEach(HistoryRange.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                Spacer()
                Text("\(h.rows) 샘플 · 10초 평균 · 30일 보관").font(.caption).foregroundStyle(.secondary)
                Button { h.reload() } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(12)
            Divider()
            if h.points.isEmpty {
                Text("기록 없음 — 앱이 실행되는 동안 10초마다 기록됩니다.").foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                if scrollable { ScrollView { charts } } else { charts }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    var charts: some View {
                    VStack(spacing: 14) {
                        chart("CPU 사용률", unit: "%", [Series(name: "CPU", color: .purple, from: h.points) { $0.cpu }], domain: 0...100)
                        chart("온도", unit: "°C", [Series(name: "CPU 최고", color: .orange, from: h.points) { $0.temp },
                                                   Series(name: "GPU", color: .pink, from: h.points) { $0.gpu }])
                        let gs = sensorGroupDefs.filter { h.groups[$0.id]?.isEmpty == false }
                        if !gs.isEmpty {
                            chart("센서 온도 (그룹 평균)", unit: "°C", gs.map { d in
                                Series(name: d.name, color: groupColors[d.id] ?? .gray, points: h.groups[d.id] ?? [])
                            }, height: 180)
                        }
                        if h.points.contains(where: { $0.fan != nil }) {
                            chart("팬", unit: "rpm", [Series(name: "최대 팬", color: .blue, from: h.points) { $0.fan }])
                        }
                        chart("메모리", unit: "%", [Series(name: "메모리", color: .teal, from: h.points) { $0.mem }], domain: 0...100)
                        chart("네트워크", unit: "MB/s", [Series(name: "↓ 수신", color: .green, from: h.points) { $0.netIn.map { $0 / 1e6 } },
                                                      Series(name: "↑ 송신", color: .red, from: h.points) { $0.netOut.map { $0 / 1e6 } }])
                        chart("디스크 여유", unit: "GB", [Series(name: "여유", color: .indigo, from: h.points) { $0.diskFree.map { $0 / 1e9 } }])
                        if h.points.contains(where: { $0.battery != nil }) {
                            chart("배터리", unit: "%", [Series(name: "배터리", color: .yellow, from: h.points) { $0.battery }], domain: 0...100)
                        }
                    }
                    .padding(12)
    }

    /// 앱이 꺼져 있던 구간은 선을 끊는다 (버킷 3배 이상 공백) → 점마다 구간 번호
    func segments(_ pts: [(Int64, Double)]) -> [Int] {
        var seg = 0, out: [Int] = []
        var prev: Int64?
        let gap = h.range.bucket * 3
        for p in pts {
            if let pr = prev, p.0 - pr > gap { seg += 1 }
            out.append(seg); prev = p.0
        }
        return out
    }

    func chart(_ title: String, unit: String, _ series: [Series], domain: ClosedRange<Double>? = nil, height: CGFloat = 120) -> some View {
        let all = series.flatMap { $0.points.map(\.1) }
        let stats = all.isEmpty ? "" : String(format: "최소 %.1f · 평균 %.1f · 최대 %.1f %@",
                                              all.min()!, all.reduce(0, +) / Double(all.count), all.max()!, unit)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(stats).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Chart {
                ForEach(series, id: \.name) { s in
                    let segs = segments(s.points)
                    ForEach(Array(s.points.enumerated()), id: \.offset) { i, p in
                        LineMark(x: .value("시각", Date(timeIntervalSince1970: TimeInterval(p.0))),
                                 y: .value(unit, p.1),
                                 series: .value("계열", "\(s.name)#\(segs[i])"))
                            .foregroundStyle(s.color)
                            .interpolationMethod(.monotone)
                    }
                }
            }
            .chartYScale(domain: domain ?? .automaticDomain(all))
            .chartXScale(domain: Date(timeIntervalSinceNow: -Double(h.range.seconds))...Date())
            .frame(height: height)
            if series.count > 1 {
                HStack(spacing: 12) {
                    ForEach(series, id: \.name) { s in
                        HStack(spacing: 4) { Circle().fill(s.color).frame(width: 7, height: 7); Text(s.name).font(.caption2) }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }
}

extension ClosedRange where Bound == Double {
    /// 데이터 범위 + 여유 10%
    static func automaticDomain(_ v: [Double]) -> ClosedRange<Double> {
        guard let lo = v.min(), let hi = v.max() else { return 0...1 }
        let pad = Swift.max((hi - lo) * 0.1, 0.5)
        return Swift.max(0, lo - pad)...(hi + pad)
    }
}
