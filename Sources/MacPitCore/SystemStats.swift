import Darwin
import Foundation
import IOKit.ps

public struct SystemSample: Sendable {
    public var cpuUser: Double = 0      // 0~1
    public var cpuSystem: Double = 0
    public var memUsed: UInt64 = 0
    public var memTotal: UInt64 = 0
    public var memPressureApprox: Double = 0
    public var netIn: Double = 0        // bytes/s
    public var netOut: Double = 0
    public var diskFree: Int64 = 0
    public var diskTotal: Int64 = 0
    public var batteryPercent: Int?
    public var batteryCharging: Bool = false
    public var load1: Double = 0
    public init() {}
}

/// 델타 기반 통계 (CPU tick·네트워크 바이트). sample() 을 주기 호출.
public final class SystemStats {
    private var prevTicks: [(user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)] = []
    private var prevNet: (UInt64, UInt64, Date)?
    // 디스크 용량 조회는 회당 ~10ms → 30초 캐시
    private var diskCache: (free: Int64, total: Int64, at: Date)?

    public init() {}

    public func sample() -> SystemSample {
        var s = SystemSample()
        (s.cpuUser, s.cpuSystem) = cpu()
        (s.memUsed, s.memTotal, s.memPressureApprox) = memory()
        (s.netIn, s.netOut) = network()
        if let c = diskCache, Date().timeIntervalSince(c.at) < 30 {
            s.diskFree = c.free; s.diskTotal = c.total
        } else if let a = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            s.diskFree = a.volumeAvailableCapacityForImportantUsage ?? 0
            s.diskTotal = Int64(a.volumeTotalCapacity ?? 0)
            diskCache = (s.diskFree, s.diskTotal, Date())
        }
        (s.batteryPercent, s.batteryCharging) = battery()
        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        s.load1 = la[0]
        return s
    }

    private func cpu() -> (Double, Double) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return (0, 0) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var cur: [(UInt64, UInt64, UInt64, UInt64)] = []
        for i in 0..<Int(count) {
            let b = Int(CPU_STATE_MAX) * i
            cur.append((UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)])), UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)])),
                        UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)])), UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))))
        }
        defer { prevTicks = cur.map { (user: $0.0, sys: $0.1, idle: $0.2, nice: $0.3) } }
        guard prevTicks.count == cur.count else { return (0, 0) }
        var u: UInt64 = 0, sy: UInt64 = 0, tot: UInt64 = 0
        for (p, c) in zip(prevTicks, cur) {
            let du = c.0 &- p.user + (c.3 &- p.nice), ds = c.1 &- p.sys, di = c.2 &- p.idle
            u += du; sy += ds; tot += du + ds + di
        }
        guard tot > 0 else { return (0, 0) }
        return (Double(u) / Double(tot), Double(sy) / Double(tot))
    }

    private func memory() -> (UInt64, UInt64, Double) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return (0, total, 0) }
        let page = UInt64(vm_kernel_page_size)
        // Activity Monitor 의 "사용된 메모리" ≈ app(internal - purgeable) + wired + compressed
        let app = (UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let used = app + wired + compressed
        return (used, total, Double(wired + compressed) / Double(total))
    }

    private func network() -> (Double, Double) {
        // if_data(32bit)는 4GB 에서 랩어라운드 → NET_RT_IFLIST2 의 if_data64 사용
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
        var inB: UInt64 = 0, outB: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(m.ifm_index), &name) != nil, String(cString: name).hasPrefix("en") {
                        inB += m.ifm_data.ifi_ibytes; outB += m.ifm_data.ifi_obytes
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        let now = Date()
        defer { prevNet = (inB, outB, now) }
        guard let (pi, po, pt) = prevNet else { return (0, 0) }
        let dt = max(now.timeIntervalSince(pt), 0.1)
        return (Double(inB &- pi) / dt, Double(outB &- po) / dt)
    }

    private func battery() -> (Int?, Bool) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false) }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let cap = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                return (cap * 100 / max, (d[kIOPSIsChargingKey] as? Bool) ?? false)
            }
        }
        return (nil, false)
    }
}

public func formatBytes(_ b: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = b, i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(Int(v)) \(units[i])" : String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
}
