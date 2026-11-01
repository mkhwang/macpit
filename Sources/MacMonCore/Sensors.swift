import Foundation

public struct FanReading: Codable, Equatable, Sendable {
    public var index: Int
    public var actual: Double
    public var target: Double
    public var min: Double
    public var max: Double
    public var mode: Int
    /// Mn<Mx 이고 Md·Tg 키가 있어야 제어 가능. 일부 기기는 읽기만 되는 팬 키를 노출한다.
    public var controllable: Bool
    public init(index: Int, actual: Double, target: Double, min: Double, max: Double, mode: Int, controllable: Bool = true) {
        self.index = index; self.actual = actual; self.target = target; self.min = min; self.max = max; self.mode = mode
        self.controllable = controllable
    }
}

/// 감지된 팬 1개. index 는 SMC 키 번호(F{index}..)라 연속이 아닐 수 있다.
public struct FanSpec: Equatable, Sendable {
    public var index: Int
    public var min: Double
    public var max: Double
    public var controllable: Bool
    public init(index: Int, min: Double, max: Double, controllable: Bool) {
        self.index = index; self.min = min; self.max = max; self.controllable = controllable
    }
}

/// 팬 감지. 기기별 차이:
///  - 팬리스(MacBook Air 등): FNum 없음 또는 0
///  - 1팬(Mac mini, 14" 일부 등) / 2팬(MacBook Pro 16" 등)
///  - FNum 이 실제와 다르게 보고되는 경우 → F{i}Ac 탐침으로 교차 확인
/// `read` 는 SMC 키 → 값. 테스트에서 가짜 SMC 를 주입한다.
public func detectFans(read: (String) -> Double?, probeLimit: Int = 8) -> [FanSpec] {
    let reported = read("FNum").map { Int($0) } ?? -1
    // FNum 이 있으면 그 범위만, 없으면 probeLimit 까지 탐침
    let range = reported >= 0 ? 0..<min(reported, probeLimit) : 0..<probeLimit
    var out: [FanSpec] = []
    for i in range {
        guard let ac = read("F\(i)Ac"), ac.isFinite, ac >= 0 else { continue }
        let mx = read("F\(i)Mx") ?? 0
        let mn = read("F\(i)Mn") ?? 0
        guard mx > 0, mx < 20000 else { continue }   // Mx 없음/쓰레기 → 팬 아님
        let ctl = mx > mn && read("F\(i)Md") != nil && read("F\(i)Tg") != nil
        out.append(FanSpec(index: i, min: mn, max: mx, controllable: ctl))
    }
    return out
}

public struct ThermalSnapshot: Codable, Equatable, Sendable {
    public var cpuAvg: Double?
    public var cpuMax: Double?
    public var gpuAvg: Double?
    public var fans: [FanReading]
    public var groups: [SensorGroupReading]
    public init(cpuAvg: Double?, cpuMax: Double?, gpuAvg: Double?, fans: [FanReading], groups: [SensorGroupReading] = []) {
        self.cpuAvg = cpuAvg; self.cpuMax = cpuMax; self.gpuAvg = gpuAvg; self.fans = fans; self.groups = groups
    }
    // 구버전 데몬 응답(groups 없음)도 디코딩되게
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        cpuAvg = try c.decodeIfPresent(Double.self, forKey: .cpuAvg)
        cpuMax = try c.decodeIfPresent(Double.self, forKey: .cpuMax)
        gpuAvg = try c.decodeIfPresent(Double.self, forKey: .gpuAvg)
        fans = try c.decode([FanReading].self, forKey: .fans)
        groups = try c.decodeIfPresent([SensorGroupReading].self, forKey: .groups) ?? []
    }
}

/// 의미가 분명한 센서 묶음. 키 → 의미는 Apple Silicon SMC 키 접두어 체계 기준.
/// 기기마다 존재하는 키가 달라서 시작 시 실제 읽히는 키만 채택한다.
public struct SensorGroupDef: Sendable {
    public let id: String
    public let name: String
    public let range: ClosedRange<Double>
    public let match: @Sendable (String) -> Bool
}

public let sensorGroupDefs: [SensorGroupDef] = [
    .init(id: "cpu", name: "CPU 코어", range: 10...130) { $0.hasPrefix("Tp") || $0.hasPrefix("Te") },
    .init(id: "gpu", name: "GPU", range: 10...130) { $0.hasPrefix("Tg") },
    .init(id: "mem", name: "메모리", range: 10...120) { $0.hasPrefix("Tm0") },
    .init(id: "ssd", name: "SSD", range: 10...110) { $0.hasPrefix("TH0") },
    .init(id: "battery", name: "배터리", range: 10...80) { $0.count == 4 && $0.hasPrefix("TB") && $0.hasSuffix("T") },
    .init(id: "airflow", name: "내부 공기", range: 15...100) { $0.hasPrefix("TaL") || $0.hasPrefix("TaR") || $0.hasPrefix("TaT") },
    .init(id: "palm", name: "팜레스트", range: 10...70) { $0 == "Ts0P" || $0 == "Ts1P" },
    .init(id: "wifi", name: "Wi-Fi", range: 10...110) { $0 == "TW0P" },
    .init(id: "charger", name: "충전부", range: 10...110) { $0 == "TCHP" },
]

public struct SensorGroupReading: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var avg: Double
    public var max: Double
    public var count: Int
    public init(id: String, name: String, avg: Double, max: Double, count: Int) {
        self.id = id; self.name = name; self.avg = avg; self.max = max; self.count = count
    }
}

/// 키 목록 + 리더 → 그룹별 채택 키 (테스트 주입용 순수 함수)
public func detectSensorGroups(keys: [String], read: (String) -> Double?) -> [(SensorGroupDef, [String])] {
    sensorGroupDefs.compactMap { def in
        let ks = keys.filter { def.match($0) && read($0).map { def.range.contains($0) } == true }
        return ks.isEmpty ? nil : (def, ks)
    }
}

/// 센서 키 탐색·읽기. 키 목록은 기기마다 달라서 시작 시 한 번 enumerate.
public final class Sensors {
    public let cpuKeys: [String]
    public let gpuKeys: [String]
    public let groups: [(SensorGroupDef, [String])]
    public let fans: [FanSpec]
    public var fanCount: Int { fans.count }
    public var controllableFans: [FanSpec] { fans.filter(\.controllable) }
    private let smc = SMC.shared
    // CPU·GPU 외 그룹(SSD·배터리 등)은 천천히 변해서 slowEvery 번에 한 번만 읽고 나머지는 직전 값 재사용
    private let slowEvery = 5
    private var tick = 0
    private var lastSlow: [String: SensorGroupReading] = [:]
    private let lock = NSLock()

    public init() {
        let keys = smc.allKeys()
        func valid(_ k: String) -> Bool {
            guard let v = SMC.shared.double(k) else { return false }
            return v > 5 && v < 130
        }
        // Apple Silicon: Tp* = CPU 코어/클러스터, Te* = E-core, Tg* = GPU
        cpuKeys = keys.filter { ($0.hasPrefix("Tp") || $0.hasPrefix("Te")) && valid($0) }
        gpuKeys = keys.filter { $0.hasPrefix("Tg") && valid($0) }
        groups = detectSensorGroups(keys: keys, read: { SMC.shared.double($0) })
        let detected = detectFans(read: { SMC.shared.double($0) })
        // 검증용: MACMON_FAKE_FANS=N → 감지된 팬 중 앞 N개만 (0 = 팬리스 흉내)
        if let n = ProcessInfo.processInfo.environment["MACMON_FAKE_FANS"].flatMap(Int.init) {
            fans = Array(detected.prefix(max(0, n)))
        } else {
            fans = detected
        }
    }

    private func groupReadings(_ read: (String) -> Double?) -> [SensorGroupReading] {
        lock.lock(); defer { lock.unlock() }
        let readSlow = tick % slowEvery == 0
        tick += 1
        return groups.compactMap { def, ks in
            let fast = def.id == "cpu" || def.id == "gpu"
            if !fast, !readSlow, let prev = lastSlow[def.id] { return prev }
            let v = ks.compactMap { read($0) }.filter { def.range.contains($0) }
            guard let mx = v.max() else { return nil }
            let r = SensorGroupReading(id: def.id, name: def.name, avg: v.reduce(0, +) / Double(v.count), max: mx, count: v.count)
            if !fast { lastSlow[def.id] = r }
            return r
        }
    }

    public func snapshot() -> ThermalSnapshot {
        // 그룹과 cpu/gpu 키가 겹치므로 스냅샷 1회당 키마다 한 번만 읽는다
        var cache: [String: Double?] = [:]
        func read(_ k: String) -> Double? {
            if let v = cache[k] { return v }
            let v = smc.double(k); cache[k] = v; return v
        }
        let cpu = cpuKeys.compactMap { read($0) }.filter { $0 > 5 && $0 < 130 }
        let gpu = gpuKeys.compactMap { read($0) }.filter { $0 > 5 && $0 < 130 }
        let fans = self.fans.map { f in
            let i = f.index
            return FanReading(
                index: i,
                actual: smc.double("F\(i)Ac") ?? 0,
                target: smc.double("F\(i)Tg") ?? 0,
                min: f.min,      // 최소·최대 RPM 은 고정값 → 감지 시 값 사용
                max: f.max,
                mode: Int(smc.double("F\(i)Md") ?? -1),
                controllable: f.controllable
            )
        }
        return ThermalSnapshot(
            cpuAvg: cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
            cpuMax: cpu.max(),
            gpuAvg: gpu.isEmpty ? nil : gpu.reduce(0, +) / Double(gpu.count),
            fans: fans,
            groups: groupReadings(read)
        )
    }
}
