import CSMC
import Foundation

public enum SMCError: Error, CustomStringConvertible {
    case code(Int32, String)
    public var description: String {
        switch self {
        case let .code(c, k): return "SMC error \(String(format: "0x%x", c)) on key \(k)"
        }
    }
}

public func fourCC(_ s: String) -> UInt32 {
    var r: UInt32 = 0
    for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }
    return r
}

public func fourCCString(_ v: UInt32) -> String {
    let bytes = [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

public struct SMCValue {
    public let key: String
    public let type: String
    public let bytes: [UInt8]

    /// SMC 데이터 타입을 Double 로 디코딩. Apple Silicon 은 대부분 `flt ` (little-endian float).
    public var double: Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "fpe2": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0 : nil
        case "sp78": return bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0 : nil
        default: return nil
        }
    }
}

/// AppleSMC 접근. 읽기는 일반 사용자 권한으로 가능, 쓰기는 root 필요.
public final class SMC {
    public static let shared = SMC()
    private let lock = NSLock()

    private init() { _ = smc_open() }

    public func read(_ key: String) throws -> SMCValue {
        lock.lock(); defer { lock.unlock() }
        var v = smc_val_t()
        let r = smc_read(fourCC(key), &v)
        guard r == 0 else { throw SMCError.code(r, key) }
        let bytes = withUnsafeBytes(of: v.bytes) { Array($0.prefix(Int(v.size))) }
        return SMCValue(key: key, type: fourCCString(v.type), bytes: bytes)
    }

    public func double(_ key: String) -> Double? { try? read(key).double }

    public func write(_ key: String, bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let r = bytes.withUnsafeBufferPointer { smc_write(fourCC(key), $0.baseAddress, UInt32($0.count)) }
        guard r == 0 else { throw SMCError.code(r, key) }
    }

    /// 키의 기존 타입에 맞춰 값을 인코딩해서 쓴다.
    public func write(_ key: String, value: Double) throws {
        let info = try read(key)
        let bytes: [UInt8]
        switch info.type {
        case "flt ":
            let bits = Float(value).bitPattern
            bytes = [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 24 & 0xff)]
        case "ui8 ": bytes = [UInt8(max(0, min(255, value)))]
        case "fpe2":
            let v = UInt16(max(0, min(16383, value)) * 4)
            bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        case "ui16":
            let v = UInt16(max(0, min(65535, value)))
            bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        default:
            throw SMCError.code(-3, "\(key) unsupported type \(info.type)")
        }
        try write(key, bytes: bytes)
    }

    public func allKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var v = smc_val_t()
        guard smc_read(fourCC("#KEY"), &v) == 0 else { return [] }
        let n = UInt32(v.bytes.0) << 24 | UInt32(v.bytes.1) << 16 | UInt32(v.bytes.2) << 8 | UInt32(v.bytes.3)
        var keys: [String] = []
        keys.reserveCapacity(Int(n))
        for i in 0..<n {
            var k: UInt32 = 0
            if smc_key_at_index(i, &k) == 0 { keys.append(fourCCString(k)) }
        }
        return keys
    }
}
