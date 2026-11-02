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
    /// 이 온도 이상이면 모드 무관 100% (system 모드는 systemSafety 가 켜져 있을 때만)
    public var safetyTemp: Double = 95
    /// target/curve 에서 이 % 미만 + 목표보다 충분히 낮으면 system 에 반납 (팬 정지 허용)
    public var releaseBelowPercent: Double = 1
    /// system 모드에서도 안전 온도 이상이면 개입. macOS 는 고온에서 팬 대신 클럭 스로틀로 대응해 100°C+ 에서도 팬이 낮게 머문다
    public var systemSafety: Bool = true

    public init() {}

    // 구버전 설정 파일·데몬 응답(새 필드 없음)도 디코딩되게: 없는 키는 기본값
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FanConfig()
        mode = try c.decodeIfPresent(FanMode.self, forKey: .mode) ?? d.mode
        manualPercent = try c.decodeIfPresent(Double.self, forKey: .manualPercent) ?? d.manualPercent
        curve = try c.decodeIfPresent([CurvePoint].self, forKey: .curve) ?? d.curve
        targetTemp = try c.decodeIfPresent(Double.self, forKey: .targetTemp) ?? d.targetTemp
        safetyTemp = try c.decodeIfPresent(Double.self, forKey: .safetyTemp) ?? d.safetyTemp
        releaseBelowPercent = try c.decodeIfPresent(Double.self, forKey: .releaseBelowPercent) ?? d.releaseBelowPercent
        systemSafety = try c.decodeIfPresent(Bool.self, forKey: .systemSafety) ?? d.systemSafety
    }

    /// 외부 입력(소켓·디스크)을 안전 범위로 정규화. 비유한 값·과다 점은 기본값/버림.
    public func sanitized() -> FanConfig {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
            v.isFinite ? Swift.max(lo, Swift.min(hi, v)) : fallback
        }
        var c = self
        c.manualPercent = clamp(manualPercent, 0, 100, 50)
        c.targetTemp = clamp(targetTemp, 40, 95, 70)
        c.safetyTemp = clamp(safetyTemp, 60, 100, 95)
        c.releaseBelowPercent = clamp(releaseBelowPercent, 0, 50, 1)
        let pts = curve.prefix(16).filter { $0.temp.isFinite && $0.percent.isFinite }
            .map { CurvePoint(Swift.max(0, Swift.min(130, $0.temp)), Swift.max(0, Swift.min(100, $0.percent))) }
        c.curve = pts.count >= 2 ? Array(pts) : FanConfig.balancedCurve
        return c
    }

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
    /// system 모드 개입 후 안전 온도에서 이만큼 아래까지 팬을 서서히 내리고(100%→0%) 반납.
    /// 바로 반납하면 macOS 가 팬을 다시 최저로 내려 수십 초 만에 재진입하는 진동이 생긴다
    public var systemSafetyBand = FanPolicyEngine.defaultSystemSafetyBand
    public static let defaultSystemSafetyBand: Double = 10
    /// system 모드 개입 최소 유지 틱(초). 개입/반납마다 Ftst 잠금 해제(~5.6초)가 반복되지 않게
    public var systemSafetyMinTicks: Int = 30
    public private(set) var lastPercent: Double?
    private var smoothed: Double?
    /// system 모드에서 개입 중인 틱 수. 0 = 개입 안 함
    public private(set) var systemSafetyTicks = 0

    public init() {}

    public mutating func reset() {
        controller.reset(); lastPercent = nil; smoothed = nil; systemSafetyTicks = 0
    }

    /// temp: 제어용 CPU 온도 (max 코어). nil = 센서 실패
    /// hottest: 안전 판정용 최고 온도 (CPU·GPU 중 높은 값). nil 이면 temp 로 판정
    public mutating func decide(config: FanConfig, temp: Double?, hottest: Double? = nil) -> FanDecision {
        guard let raw = temp, raw.isFinite else {   // NaN 센서값이 EMA 에 고착되지 않게
            reset()
            return FanDecision(percent: nil, reason: "sensor-unavailable")
        }
        // EMA 로 순간 스파이크 완화 
        let t = smoothed.map { $0 * 0.6 + raw * 0.4 } ?? raw
        smoothed = t

        let hot = hottest.flatMap { $0.isFinite ? Swift.max($0, t) : nil } ?? t
        if config.mode == .system {
            controller.reset()
            guard config.systemSafety, hot >= config.safetyTemp || systemSafetyTicks > 0 else {
                lastPercent = nil; systemSafetyTicks = 0
                return FanDecision(percent: nil, reason: "system")
            }
            systemSafetyTicks += 1
            if hot >= config.safetyTemp {
                lastPercent = 100
                return FanDecision(percent: 100, reason: "safety")
            }
            // 식는 중: 안전 온도 −band ~ 안전 온도 구간을 0~100% 로 보고 램프 제한을 걸어 서서히 내림
            var want = interpolate(curve: [CurvePoint(config.safetyTemp - systemSafetyBand, 0), CurvePoint(config.safetyTemp, 100)], temp: hot)
            if let last = lastPercent, last.isFinite {
                want = max(last - maxStepPerTick, min(last + maxStepPerTick, want))
            }
            guard want.isFinite else { lastPercent = 100; return FanDecision(percent: 100, reason: "invalid") }
            lastPercent = want
            if want < config.releaseBelowPercent && systemSafetyTicks >= systemSafetyMinTicks {
                lastPercent = nil; systemSafetyTicks = 0
                return FanDecision(percent: nil, reason: "system")
            }
            return FanDecision(percent: want, reason: "system-safety")
        }
        if hot >= config.safetyTemp {
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
        if let last = lastPercent, last.isFinite {
            want = max(last - maxStepPerTick, min(last + maxStepPerTick, want))
        }
        // 비정상 값(NaN/inf)이 상태에 고착되지 않도록: 초기화 후 안전하게 최대 출력
        guard want.isFinite else { reset(); lastPercent = 100; return FanDecision(percent: 100, reason: "invalid") }
        lastPercent = want
        if want < config.releaseBelowPercent && t < (config.mode == .target ? config.targetTemp - 3 : 200) {
            return FanDecision(percent: nil, reason: "\(config.mode.rawValue)-idle")
        }
        return FanDecision(percent: want, reason: config.mode.rawValue)
    }
}
