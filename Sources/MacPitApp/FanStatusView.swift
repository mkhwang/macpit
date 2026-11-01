import Charts
import MacPitCore
import SwiftUI

/// 온도 → 팬% 프로필 프리셋
enum FanPreset: String, CaseIterable, Identifiable {
    case quiet, balanced, performance
    var id: String { rawValue }
    var name: String { switch self { case .quiet: "조용"; case .balanced: "균형"; case .performance: "성능" } }
    var curve: [CurvePoint] {
        switch self {
        case .quiet: FanConfig.quietCurve
        case .balanced: FanConfig.balancedCurve
        case .performance: FanConfig.performanceCurve
        }
    }
    static func matching(_ curve: [CurvePoint]) -> FanPreset? { allCases.first { $0.curve == curve } }
}

/// 데몬이 지금 무엇을, 왜 하고 있는지 한 줄로
struct FanRunState {
    enum Tone { case idle, active, warning, danger }
    var title: String
    var detail: String
    var tone: Tone

    init(status d: DaemonStatus) {
        let temp = d.controlTemp.map { "CPU \(Int($0.rounded()))°C" } ?? "CPU 온도 없음"
        let pct = d.appliedPercent.map { "\(Int($0.rounded()))%" } ?? ""
        let preset = FanPreset.matching(d.config.curve)?.name ?? "사용자 정의"
        switch d.reason {
        case "safety":
            self.init(title: "안전 모드 · 팬 100%", detail: "\(temp) — 안전 온도 \(Int(d.config.safetyTemp))°C 이상", tone: .danger)
        case "sensor-unavailable":
            self.init(title: "센서 오류 · macOS 에 반납", detail: "온도를 읽지 못해 macOS 가 팬을 관리합니다", tone: .warning)
        case "invalid":
            self.init(title: "비정상 값 · 팬 100%", detail: "설정 값을 확인하세요", tone: .danger)
        case "system":
            self.init(title: "macOS 자동 제어", detail: "\(temp) — MacPit 은 관여하지 않습니다", tone: .idle)
        case "manual":
            self.init(title: "수동 \(pct) 고정", detail: "\(temp) — 온도와 무관하게 고정 (안전 온도 초과 시 100%)", tone: .active)
        case "curve":
            self.init(title: "\(preset) 프로필 · 팬 \(pct)", detail: "\(temp) 에 맞춰 팬 속도를 조절 중", tone: .active)
        case "curve-idle":
            self.init(title: "\(preset) 프로필 · 대기", detail: "\(temp) — 팬이 필요 없는 온도라 macOS 에 맡김 (팬 정지 가능)", tone: .idle)
        case "target":
            self.init(title: "목표 \(Int(d.config.targetTemp))°C 유지 · 팬 \(pct)", detail: "\(temp) — 목표 온도에 맞춰 조절 중", tone: .active)
        case "target-idle":
            self.init(title: "목표 \(Int(d.config.targetTemp))°C 유지 · 대기", detail: "\(temp) — 목표보다 충분히 낮아 macOS 에 맡김", tone: .idle)
        default:
            self.init(title: "준비 중", detail: d.reason, tone: .idle)
        }
    }

    init(title: String, detail: String, tone: Tone) { self.title = title; self.detail = detail; self.tone = tone }

    var color: Color {
        switch tone { case .idle: .green; case .active: .blue; case .warning: .orange; case .danger: .red }
    }
}

struct FanStatusCard: View {
    let status: DaemonStatus
    var body: some View {
        let s = FanRunState(status: status)
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(s.color).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title).font(.callout.weight(.semibold))
                Text(s.detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(s.color.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}

/// 프로필 그래프 + 현재 위치 점
struct ProfileChart: View {
    let curve: [CurvePoint]
    let temp: Double?
    let applied: Double?

    var body: some View {
        let pts = curve.sorted { $0.temp < $1.temp }
        let lo = min(35, pts.first?.temp ?? 35), hi = max(100, pts.last?.temp ?? 100)
        // 양 끝을 수평 연장해 그래프 범위 전체에서 동작을 보여줌
        let line = [CurvePoint(lo, pts.first?.percent ?? 0)] + pts + [CurvePoint(hi, pts.last?.percent ?? 100)]
        Chart {
            ForEach(Array(line.enumerated()), id: \.offset) { _, p in
                LineMark(x: .value("온도", p.temp), y: .value("팬", p.percent))
                    .foregroundStyle(.blue.opacity(0.7))
            }
            if let t = temp {
                let x = min(max(t, lo), hi)
                RuleMark(x: .value("현재", x)).foregroundStyle(.secondary.opacity(0.4))
                PointMark(x: .value("현재", x), y: .value("팬", applied ?? interpolate(curve: curve, temp: t)))
                    .foregroundStyle(applied == nil ? .green : .blue)
                    .symbolSize(50)
            }
        }
        .chartXScale(domain: lo...hi)
        .chartYScale(domain: 0...100)
        .chartXAxis { AxisMarks(values: .stride(by: 10)) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))°") } } } }
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } } } }
        .font(.caption2)
        .frame(height: 70)
    }
}
