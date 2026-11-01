import Foundation

public enum FanMode: String, Codable, CaseIterable, Sendable {
    case system   // macOS(thermalmonitord)에 맡김
    case manual   // 고정 % 또는 RPM
    case curve    // 온도→% 곡선
    case target   // 목표 온도 유지 (PI 제어)
}

public struct CurvePoint: Codable, Equatable, Sendable {
    public var temp: Double
    public var percent: Double
    public init(_ temp: Double, _ percent: Double) { self.temp = temp; self.percent = percent }
}

public struct FanConfig: Codable, Equatable, Sendable {
    public var mode: FanMode = .system
    /// manual: 0~100%. 0% = 최소 RPM(Mn)
    public var manualPercent: Double = 50
    public var curve: [CurvePoint] = FanConfig.balancedCurve
    /// target 모드 목표 CPU 온도(°C)
    public var targetTemp: Double = 70
    /// 이 온도 이상이면 모드 무관 100% (system 모드 제외)
    public var safetyTemp: Double = 95
    /// target/curve 에서 이 % 미만 + 목표보다 충분히 낮으면 system 에 반납 (팬 정지 허용)
    public var releaseBelowPercent: Double = 1

    public init() {}

    public static let quietCurve = [CurvePoint(55, 0), CurvePoint(70, 15), CurvePoint(80, 45), CurvePoint(90, 100)]
    public static let balancedCurve = [CurvePoint(50, 0), CurvePoint(62, 20), CurvePoint(75, 55), CurvePoint(85, 100)]
    public static let performanceCurve = [CurvePoint(40, 10), CurvePoint(55, 35), CurvePoint(68, 70), CurvePoint(78, 100)]
}

/// 곡선 선형 보간. 점들은 temp 기준 정렬 가정 X — 내부에서 정렬.
public func interpolate(curve: [CurvePoint], temp: Double) -> Double {
    let pts = curve.sorted { $0.temp < $1.temp }
    guard let first = pts.first, let last = pts.last else { return 0 }
    if temp <= first.temp { return first.percent }
    if temp >= last.temp { return last.percent }
    for (a, b) in zip(pts, pts.dropFirst()) where temp >= a.temp && temp <= b.temp {
        let t = (temp - a.temp) / max(b.temp - a.temp, 0.001)
        return a.percent + (b.percent - a.percent) * t
    }
    return last.percent
}

public func percentToRPM(_ p: Double, min: Double, max: Double) -> Double {
    let c = Swift.max(0, Swift.min(100, p))
    return min + (max - min) * c / 100
}

/// 목표 온도 PI 제어기. 1초 주기 가정.
public struct TargetController: Sendable {
    public var kp: Double = 6      // °C 초과당 %
    public var ki: Double = 0.25   // 누적 오차 계수
    public private(set) var integral: Double = 0

    public init() {}

    public mutating func reset() { integral = 0 }

    public mutating func step(temp: Double, target: Double, dt: Double = 1) -> Double {
        let error = temp - target
        let pOut = kp * error
        // anti-windup: 현재 출력이 포화 상태이고 오차가 같은 방향이면 적분 정지
        let out = pOut + ki * integral
        if !(out >= 100 && error > 0) && !(out <= 0 && error < 0) {
            integral += error * dt
        }
        integral = Swift.max(-100 / ki, Swift.min(100 / ki, integral))
        return Swift.max(0, Swift.min(100, pOut + ki * integral))
    }
}

/// 한 틱의 결정: nil = system 에 반납, 값 = 팬 % (0~100)
public struct FanDecision: Equatable, Sendable {
    public var percent: Double?
    public var reason: String
    public init(percent: Double?, reason: String) { self.percent = percent; self.reason = reason }
}

public struct FanPolicyEngine: Sendable {
    public var controller = TargetController()
    /// 출력 % 의 틱당 최대 변화량 (급변 방지)
    public var maxStepPerTick: Double = 8
    public private(set) var lastPercent: Double?
    private var smoothed: Double?

    public init() {}

    public mutating func reset() {
        controller.reset(); lastPercent = nil; smoothed = nil
    }

    /// temp: 제어용 CPU 온도 (max 코어). nil = 센서 실패
    public mutating func decide(config: FanConfig, temp: Double?) -> FanDecision {
        guard let raw = temp else {
            reset()
            return FanDecision(percent: nil, reason: "sensor-unavailable")
        }
        // EMA 로 순간 스파이크 완화 
        let t = smoothed.map { $0 * 0.6 + raw * 0.4 } ?? raw
        smoothed = t

        if config.mode == .system {
            reset(); smoothed = t
            return FanDecision(percent: nil, reason: "system")
        }
        if t >= config.safetyTemp {
            lastPercent = 100
            return FanDecision(percent: 100, reason: "safety")
        }
        var want: Double
        switch config.mode {
        case .system: return FanDecision(percent: nil, reason: "system")
        case .manual:
            lastPercent = config.manualPercent
            return FanDecision(percent: config.manualPercent, reason: "manual")
        case .curve:
            want = interpolate(curve: config.curve, temp: t)
        case .target:
            want = controller.step(temp: t, target: config.targetTemp)
        }
        if let last = lastPercent {
            want = max(last - maxStepPerTick, min(last + maxStepPerTick, want))
        }
        lastPercent = want
        if want < config.releaseBelowPercent && t < (config.mode == .target ? config.targetTemp - 3 : 200) {
            return FanDecision(percent: nil, reason: "\(config.mode.rawValue)-idle")
        }
        return FanDecision(percent: want, reason: config.mode.rawValue)
    }
}
