import Foundation
import MacPitCore

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var current = ""
func expect(_ ok: Bool, _ msg: String = "", line: Int = #line) {
    if !ok { failures += 1; print("  ✘ \(current) line \(line) \(msg)") }
}

struct FanPolicyTests {
    static let all: [(String, (FanPolicyTests) -> () -> Void)] = [
        ("testInterpolate", testInterpolate),
        ("testPercentToRPM", testPercentToRPM),
        ("testSystemReleases", testSystemReleases),
        ("testSafetyOverridesManual", testSafetyOverridesManual),
        ("testSensorFailureReleases", testSensorFailureReleases),
        ("testTargetRampsUpWhenHot", testTargetRampsUpWhenHot),
        ("testTargetReleasesWhenCool", testTargetReleasesWhenCool),
        ("testRampLimit", testRampLimit),
        ("testTargetConvergesInThermalModel", testTargetConvergesInThermalModel),
        ("testDetectFanless", testDetectFanless),
        ("testDetectFanlessNoFNum", testDetectFanlessNoFNum),
        ("testDetectSingleFan", testDetectSingleFan),
        ("testDetectTwoFans", testDetectTwoFans),
        ("testDetectFNumOverReports", testDetectFNumOverReports),
        ("testDetectProbeWithoutFNum", testDetectProbeWithoutFNum),
        ("testDetectReadOnlyFan", testDetectReadOnlyFan),
        ("testHistoryAccumulator", testHistoryAccumulator),
        ("testHistoryStoreQueryPrune", testHistoryStoreQueryPrune),
        ("testParseDockerSize", testParseDockerSize),
        ("testSensorGroups", testSensorGroups),
        ("testGroupHistory", testGroupHistory),
        ("testParsePS", testParsePS),
        ("testMigrateLegacyHistory", testMigrateLegacyHistory),
        ("testSanitizeConfig", testSanitizeConfig),
        ("testNonFiniteCurveRecovers", testNonFiniteCurveRecovers),
        ("testCleanerRejectsInnerSymlink", testCleanerRejectsInnerSymlink),
    ]

    func testParsePS() {
        let out = "  123  12.5  204800 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome\n    1   0.0   8192 /sbin/launchd\ngarbage\n"
        let p = parsePS(out)
        expect(p.count == 2, "\(p)")
        expect(p.first == ProcUsage(pid: 123, name: "Google Chrome", cpu: 12.5, mem: 204800 * 1024), "\(String(describing: p.first))")
    }

    func testSensorGroups() {
        let vals: [String: Double] = ["Tp01": 60, "Te05": 50, "Tg05": 55, "TH0a": 35, "TB1T": 30, "TB2T": 31,
                                      "TaLP": 38, "Ta05": 8.5,      // Ta05 는 공기 그룹 아님 + 범위 밖
                                      "Ts0P": 30, "Ts00": 41,       // Ts00 은 팜레스트 아님
                                      "TBXT": 200, "TW0P": 41]      // 범위 밖 제외
        let g = detectSensorGroups(keys: Array(vals.keys).sorted(), read: { vals[$0] })
        let m = Dictionary(uniqueKeysWithValues: g.map { ($0.0.id, $0.1) })
        expect(m["cpu"] == ["Te05", "Tp01"], "\(String(describing: m["cpu"]))")
        expect(m["battery"] == ["TB1T", "TB2T"], "\(String(describing: m["battery"]))")
        expect(m["airflow"] == ["TaLP"] && m["palm"] == ["Ts0P"] && m["wifi"] == ["TW0P"])
        expect(m["mem"] == nil && m["charger"] == nil, "없는 그룹은 생략")
    }
    func testGroupHistory() {
        var a = HistoryAccumulator(interval: 10)
        _ = a.add(HistoryPoint(ts: 0), groups: ["ssd": 30])
        _ = a.add(HistoryPoint(ts: 4), groups: ["ssd": 40, "gpu": 50])
        _ = a.add(HistoryPoint(ts: 10), groups: [:])
        expect(a.flushedGroups == ["ssd": 35, "gpu": 50], "\(a.flushedGroups)")
        let path = NSTemporaryDirectory() + "macpit-gtest-\(getpid()).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        guard let h = HistoryStore(path: path) else { expect(false, "open"); return }
        h.insertGroups(ts: 100, ["ssd": 30, "gpu": 50]); h.insertGroups(ts: 110, ["ssd": 40])
        let q = h.queryGroups(from: 0, to: 200, bucket: 60)
        expect(q["ssd"]?.first?.1 == 35 && q["gpu"]?.count == 1, "\(q)")
    }

    func testHistoryAccumulator() {
        var a = HistoryAccumulator(interval: 10)
        expect(a.add(HistoryPoint(ts: 100, cpu: 10, fan: nil)) == nil)
        expect(a.add(HistoryPoint(ts: 104, cpu: 30, fan: 2000)) == nil)
        let r = a.add(HistoryPoint(ts: 110, cpu: 99))   // 새 버킷 → 직전 평균 방출
        expect(r?.ts == 100 && r?.cpu == 20 && r?.fan == 2000 && r?.temp == nil, "\(String(describing: r))")
    }
    func testHistoryStoreQueryPrune() {
        let path = NSTemporaryDirectory() + "macpit-test-\(getpid()).sqlite"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }
        guard let h = HistoryStore(path: path) else { expect(false, "open"); return }
        let now: Int64 = 1_800_000_000
        for i in 0..<60 { h.insert(HistoryPoint(ts: now - 600 + Int64(i) * 10, cpu: Double(i), temp: 50)) }
        h.insert(HistoryPoint(ts: now - HistoryStore.retention - 100, cpu: 1))   // 보관기간 초과
        expect(h.count() == 61)
        let pts = h.query(from: now - 600, to: now, bucket: 60)
        expect(pts.count == 10 && pts.first?.cpu == 2.5 && pts.allSatisfy { $0.temp == 50 }, "\(pts.count) \(String(describing: pts.first))")
        h.prune(now: now)
        expect(h.count() == 60)
    }
    func testSanitizeConfig() {
        var c = FanConfig()
        c.manualPercent = .nan; c.targetTemp = 1e9; c.safetyTemp = -.infinity; c.releaseBelowPercent = 999
        c.curve = [CurvePoint(-1e308, -1e308), CurvePoint(1e308, 1e308)]
        let s = c.sanitized()
        expect(s.manualPercent == 50 && s.targetTemp == 95 && s.safetyTemp == 95 && s.releaseBelowPercent == 50, "\(s)")
        expect(s.curve.allSatisfy { (0...130).contains($0.temp) && (0...100).contains($0.percent) }, "curve \(s.curve)")
        c.curve = Array(repeating: CurvePoint(50, 50), count: 1000)
        expect(c.sanitized().curve.count == 16)
        c.curve = [CurvePoint(.nan, 1)]
        expect(c.sanitized().curve == FanConfig.balancedCurve)
    }
    func testNonFiniteCurveRecovers() {
        // 검증 우회로 NaN 곡선이 들어와도 결정값은 유한하고, 정상 곡선으로 바꾸면 같은 모드에서 회복
        var e = FanPolicyEngine()
        var c = FanConfig(); c.mode = .curve
        c.curve = [CurvePoint(-1e308, -1e308), CurvePoint(1e308, 1e308)]
        for _ in 0..<3 { let d = e.decide(config: c, temp: 60); expect(d.percent.map { $0.isFinite } ?? true, "\(d)") }
        c.curve = FanConfig.balancedCurve
        var last: FanDecision?
        for _ in 0..<30 { last = e.decide(config: c, temp: 60) }
        expect(last?.reason == "curve" && (last?.percent.map { $0 < 30 } ?? false), "\(String(describing: last))")
        expect(e.decide(config: c, temp: .nan).percent == nil)
    }
    func testCleanerRejectsInnerSymlink() {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "macpit-home-\(getpid())"
        defer { try? fm.removeItem(atPath: home) }
        try? fm.createDirectory(atPath: home + "/work/shared", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: home + "/.m2", withIntermediateDirectories: true)
        fm.createFile(atPath: home + "/work/shared/keep.jar", contents: Data("x".utf8))
        try? fm.createSymbolicLink(atPath: home + "/.m2/repository", withDestinationPath: home + "/work/shared")
        let c = StorageCleaner(home: home)
        let o = c.clean(cleanTargets.first { $0.id == "maven" }!)
        expect(fm.fileExists(atPath: home + "/work/shared/keep.jar"), "symlink target must survive")
        expect(o.error?.contains("거부") == true, "\(String(describing: o.error))")
    }
    func testMigrateLegacyHistory() {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "macpit-mig-\(getpid())"
        defer { try? fm.removeItem(atPath: root) }
        let oldDir = root + "/MacMon", newPath = root + "/MacPit/history.sqlite"
        try? fm.createDirectory(atPath: oldDir, withIntermediateDirectories: true)
        do { let h = HistoryStore(path: oldDir + "/history.sqlite"); h?.insert(HistoryPoint(ts: 100, cpu: 7)) }
        expect(migrateLegacyHistory(from: oldDir, to: newPath), "first migrate")
        expect(!fm.fileExists(atPath: oldDir + "/history.sqlite"), "old removed")
        expect(HistoryStore(path: newPath)?.count() == 1, "data kept")
        // 새 DB 가 있으면 덮어쓰지 않음
        try? fm.createDirectory(atPath: oldDir, withIntermediateDirectories: true)
        fm.createFile(atPath: oldDir + "/history.sqlite", contents: Data("x".utf8))
        expect(!migrateLegacyHistory(from: oldDir, to: newPath), "no overwrite")
        expect(HistoryStore(path: newPath)?.count() == 1, "new intact")
    }
    func testParseDockerSize() {
        expect(parseDockerSize("13.58GB") == 13_580_000_000)
        expect(parseDockerSize("167.9kB") == 167_900)
        expect(parseDockerSize("0B") == 0)
        expect(parseDockerSize("1.5MB") == 1_500_000)
    }

    // --- 팬 감지 (가짜 SMC) ---
    static func fan(_ i: Int, mn: Double = 1200, mx: Double = 5000, ctl: Bool = true) -> [String: Double] {
        var d: [String: Double] = ["F\(i)Ac": 0, "F\(i)Mn": mn, "F\(i)Mx": mx]
        if ctl { d["F\(i)Md"] = 3; d["F\(i)Tg"] = 0 }
        return d
    }
    static func smc(_ parts: [String: Double]...) -> (String) -> Double? {
        let all = parts.reduce(into: [String: Double]()) { $0.merge($1) { a, _ in a } }
        return { all[$0] }
    }

    func testDetectFanless() {
        // MacBook Air: FNum=0, 팬 키 없음
        expect(detectFans(read: Self.smc(["FNum": 0])).isEmpty)
    }
    func testDetectFanlessNoFNum() {
        expect(detectFans(read: Self.smc([:])).isEmpty)
    }
    func testDetectSingleFan() {
        let f = detectFans(read: Self.smc(["FNum": 1], Self.fan(0, mn: 1000, mx: 4900)))
        expect(f.count == 1 && f[0].index == 0 && f[0].controllable && f[0].max == 4900, "\(f)")
    }
    func testDetectTwoFans() {
        let f = detectFans(read: Self.smc(["FNum": 2], Self.fan(0, mx: 4296), Self.fan(1, mx: 4744)))
        expect(f.map(\.index) == [0, 1] && f.map(\.max) == [4296, 4744], "\(f)")
    }
    func testDetectFNumOverReports() {
        // FNum=2 인데 F1 키가 없음 → 1개로 판정
        let f = detectFans(read: Self.smc(["FNum": 2], Self.fan(0)))
        expect(f.count == 1, "\(f)")
    }
    func testDetectProbeWithoutFNum() {
        // FNum 키 자체가 없지만 F0 이 있음 → 탐침으로 1개
        let f = detectFans(read: Self.smc(Self.fan(0)))
        expect(f.count == 1, "\(f)")
    }
    func testDetectReadOnlyFan() {
        // Md/Tg 없음 또는 Mn==Mx → 표시만, 제어 대상 아님
        let f = detectFans(read: Self.smc(["FNum": 2], Self.fan(0, ctl: false), Self.fan(1, mn: 3000, mx: 3000)))
        expect(f.count == 2 && f.allSatisfy { !$0.controllable }, "\(f)")
    }
    func testInterpolate() {
        let c = [CurvePoint(50, 0), CurvePoint(70, 40), CurvePoint(90, 100)]
        expect(interpolate(curve: c, temp: 40) == 0)
        expect(abs(interpolate(curve: c, temp: 60) - 20) <= 0.01)
        expect(abs(interpolate(curve: c, temp: 80) - 70) <= 0.01)
        expect(interpolate(curve: c, temp: 95) == 100)
    }

    func testPercentToRPM() {
        expect(percentToRPM(0, min: 1500, max: 4500) == 1500)
        expect(percentToRPM(50, min: 1500, max: 4500) == 3000)
        expect(percentToRPM(150, min: 1500, max: 4500) == 4500)
    }

    func testSystemReleases() {
        var e = FanPolicyEngine()
        expect(e.decide(config: FanConfig(), temp: 99).percent == nil)
    }

    func testSafetyOverridesManual() {
        var e = FanPolicyEngine(); var c = FanConfig(); c.mode = .manual; c.manualPercent = 10
        expect(e.decide(config: c, temp: 60).percent == 10)
        var e2 = FanPolicyEngine()
        expect(e2.decide(config: c, temp: 99).percent == 100)
    }

    func testSensorFailureReleases() {
        var e = FanPolicyEngine(); var c = FanConfig(); c.mode = .manual
        expect(e.decide(config: c, temp: nil).percent == nil)
    }

    func testTargetRampsUpWhenHot() {
        var e = FanPolicyEngine(); var c = FanConfig(); c.mode = .target; c.targetTemp = 70
        var last = 0.0
        for _ in 0..<30 { last = e.decide(config: c, temp: 85).percent ?? 0 }
        expect(abs((last) - (100)) <= 0.01)
    }

    func testTargetReleasesWhenCool() {
        var e = FanPolicyEngine(); var c = FanConfig(); c.mode = .target; c.targetTemp = 70
        var d = FanDecision(percent: 0, reason: "")
        for _ in 0..<10 { d = e.decide(config: c, temp: 55) }
        expect(d.percent == nil)
    }

    func testRampLimit() {
        var e = FanPolicyEngine(); var c = FanConfig(); c.mode = .curve
        c.curve = [CurvePoint(50, 0), CurvePoint(60, 100)]
        _ = e.decide(config: c, temp: 55)          // 50%
        let next = e.decide(config: c, temp: 70)   // 원하는 값 100%, 램프 제한 +8
        expect((next.percent ?? 0) <= 50 + 8 + 0.01)
    }

    /// 단순 열 모델: 발열 고정, 팬 % 비례 냉각. 목표 근처 수렴 확인.
    func testTargetConvergesInThermalModel() {
        var e = FanPolicyEngine(); var c = FanConfig(); c.mode = .target; c.targetTemp = 72
        var temp = 80.0
        var tail: [Double] = []
        for i in 0..<600 {
            let p = e.decide(config: c, temp: temp).percent ?? 0
            let heat = 1.2, ambientPull = (temp - 30) * 0.015, fanCool = (temp - 30) * 0.0006 * p
            temp += heat - ambientPull - fanCool
            if i > 450 { tail.append(temp) }
        }
        let avg = tail.reduce(0, +) / Double(tail.count)
        expect(abs(avg - 72) <= 2.0, "steady-state avg \(avg)")
    }
}

for (name, f) in FanPolicyTests.all {
    current = name
    let before = failures
    f(FanPolicyTests())()
    print(failures == before ? "✔ \(name)" : "✘ \(name)")
}
print(failures == 0 ? "ALL PASSED (\(FanPolicyTests.all.count))" : "FAILED: \(failures)")
exit(failures == 0 ? 0 : 1)
