import Foundation
import IOKit

/// SMC key（4 字符，大端打包成 UInt32），例如 "TC0P"、"#KEY"、"F0Mn"。
struct SMCKey: Hashable {
    let raw: UInt32

    init(_ code: String) {
        var v: UInt32 = 0
        for b in code.utf8.prefix(4) { v = (v << 8) | UInt32(b) }
        self.raw = v
    }

    init(raw: UInt32) { self.raw = raw }

    var code: String {
        let bytes = [UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff),
                     UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff)]
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// AppleSMC 用户客户端的轻量封装。
///
/// 与驱动的通信使用单个 80 字节结构体（与 smcFanControl 的 SMCKeyData_t 一致，小端）：
///   key@0 · keyInfo.dataSize@28 · keyInfo.dataType@32 · result@40 · status@41
///   data8@42（子命令）· data32@44（key 枚举索引）· bytes@48（读写数据）
/// 子命令：5=读数据 6=写数据 8=按索引取 key 9=取 key 元信息。
final class SMCClient {
    private var conn: io_connect_t = 0
    private(set) var opened = false
    private var infoCache: [UInt32: (dataSize: UInt32, dataType: UInt32)] = [:]

    private static let size = 80
    private enum Off {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let data8 = 42
        static let data32 = 44
        static let bytes = 48
    }

    deinit {
        if opened { IOServiceClose(conn) }
    }

    /// 连接 AppleSMC 驱动的 user client。
    @discardableResult
    func open() -> Bool {
        guard !opened else { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &c) == KERN_SUCCESS else { return false }
        conn = c
        opened = true
        return true
    }

    // MARK: - 底层调用

    private func put32(_ v: UInt32, at offset: Int, in buffer: inout [UInt8]) {
        buffer[offset] = UInt8(v & 0xff)
        buffer[offset + 1] = UInt8((v >> 8) & 0xff)
        buffer[offset + 2] = UInt8((v >> 16) & 0xff)
        buffer[offset + 3] = UInt8((v >> 24) & 0xff)
    }

    private func get32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    @discardableResult
    private func call(sub: UInt8, key: SMCKey? = nil, data32: UInt32 = 0,
                      dataSize: UInt32 = 0, bytes: [UInt8]? = nil) -> (output: [UInt8], kr: kern_return_t)? {
        guard opened else { return nil }
        var input = [UInt8](repeating: 0, count: SMCClient.size)
        var output = [UInt8](repeating: 0, count: SMCClient.size)
        if let key { put32(key.raw, at: Off.key, in: &input) }
        put32(dataSize, at: Off.dataSize, in: &input)
        input[Off.data8] = sub
        put32(data32, at: Off.data32, in: &input)
        if let bytes {
            for (i, b) in bytes.prefix(32).enumerated() { input[Off.bytes + i] = b }
        }
        var outputSize = SMCClient.size
        let kr = input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                IOConnectCallStructMethod(conn, 2, inPtr.baseAddress, SMCClient.size,
                                          outPtr.baseAddress, &outputSize)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (output, kr)
    }

    // MARK: - key 元信息与读写

    func keyInfo(_ key: SMCKey) -> (dataSize: UInt32, dataType: UInt32)? {
        if let cached = infoCache[key.raw] { return cached }
        guard let r = call(sub: 9, key: key) else { return nil }
        let size = get32(r.output, Off.dataSize)
        let type = get32(r.output, Off.dataType)
        guard size > 0, size <= 32, type != 0 else { return nil }
        let info = (size, type)
        infoCache[key.raw] = info
        return info
    }

    func readRaw(_ key: SMCKey) -> (data: [UInt8], dataType: UInt32)? {
        guard let info = keyInfo(key) else { return nil }
        guard let r = call(sub: 5, key: key, dataSize: info.dataSize) else { return nil }
        let n = Int(info.dataSize)
        return (Array(r.output[Off.bytes ..< Off.bytes + n]), info.dataType)
    }

    /// 写 key。返回 IOKit 错误码，KERN_SUCCESS 表示成功。
    @discardableResult
    func writeRaw(_ key: SMCKey, data: [UInt8]) -> kern_return_t {
        guard let info = keyInfo(key) else { return KERN_FAILURE }
        guard data.count == Int(info.dataSize) else { return KERN_INVALID_ARGUMENT }
        return call(sub: 6, key: key, dataSize: info.dataSize, bytes: data)?.kr ?? KERN_FAILURE
    }

    /// 按索引枚举 SMC key（返回 key 与类型，类型可能为 0 表示驱动未填）。
    func key(at index: UInt32) -> (key: SMCKey, dataType: UInt32)? {
        guard let r = call(sub: 8, data32: index) else { return nil }
        let k = get32(r.output, Off.key)
        guard k != 0 else { return nil }
        return (SMCKey(raw: k), get32(r.output, Off.dataType))
    }

    /// SMC 中 key 的总数（"#KEY"）。
    func keyCount() -> Int {
        guard let raw = readRaw(SMCKey("#KEY")) else { return 0 }
        guard raw.data.count >= 4 else { return 0 }
        return Int(UInt32(raw.data[0]) << 24 | UInt32(raw.data[1]) << 16
                   | UInt32(raw.data[2]) << 8 | UInt32(raw.data[3]))
    }

    // MARK: - 带类型的读取

    private func typeMatches(_ raw: (data: [UInt8], dataType: UInt32)?, _ code: String) -> [UInt8]? {
        guard let raw, raw.dataType == SMCKey(code).raw else { return nil }
        return raw.data
    }

    /// sp78 温度（°C）。
    func readTemperature(_ code: String) -> Double? {
        if let b = typeMatches(readRaw(SMCKey(code)), "sp78"), b.count >= 2 {
            return Double(Int8(bitPattern: b[0])) + Double(b[1]) / 256.0
        }
        if let b = typeMatches(readRaw(SMCKey(code)), "flt "), b.count >= 4 {
            return smcFloat(b)
        }
        return nil
    }

    /// 风扇转速等数值：Apple Silicon 为 "flt "，老机型为 "fpe2"。
    func readNumber(_ code: String) -> Double? {
        guard let raw = readRaw(SMCKey(code)) else { return nil }
        let b = raw.data
        let type = SMCKey(raw: raw.dataType).code
        switch type {
        case "fpe2":
            guard b.count >= 4 else { return nil }
            let v = bigEndian32(b)
            return Double(v) / 4.0
        case "flt ":
            guard b.count >= 4 else { return nil }
            return smcFloat(b)
        case "ui8 ":
            guard b.count >= 1 else { return nil }
            return Double(b[0])
        default:
            return nil
        }
    }

    /// 写数值 key：按 key 自身类型编码。注意实测 Apple Silicon 的 "flt " 为
    /// 小端 float32（BE 写入会被固件解析成接近 0 的 denormal，风扇会被压到最低速）。
    @discardableResult
    func writeNumber(_ code: String, value: Double) -> kern_return_t {
        guard let info = keyInfo(SMCKey(code)) else { return KERN_FAILURE }
        let type = SMCKey(raw: info.dataType).code
        let data: [UInt8]
        switch type {
        case "flt ":
            let bits = Float(value).bitPattern
            data = [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
                    UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
        default:
            data = beBytes(UInt32(max(0, (value * 4).rounded())))
        }
        return writeRaw(SMCKey(code), data: data)
    }

    /// 返回 key 的数据类型代码（"flt "、"sp78"、"fpe2" 等）。
    func dataTypeCode(_ code: String) -> String? {
        keyInfo(SMCKey(code)).map { SMCKey(raw: $0.dataType).code }
    }

    // MARK: 解码

    private func bigEndian32(_ b: [UInt8]) -> UInt32 {
        UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    /// "flt " 按小端 float32 解释（M4 实测：F0Ac=1001rpm、F0Mn=1000 等均由此正确解出）。
    private func smcFloat(_ b: [UInt8]) -> Double? {
        let bits = UInt32(b[3]) << 24 | UInt32(b[2]) << 16 | UInt32(b[1]) << 8 | UInt32(b[0])
        let f = Float(bitPattern: bits)
        return f.isFinite ? Double(f) : nil
    }

    private func beBytes(_ v: UInt32) -> [UInt8] {
        [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff].map { UInt8($0) }
    }

    /// ui8 / ui16 / ui32 整数。
    func readUInt(_ code: String) -> Double? {
        let key = SMCKey(code)
        guard let raw = readRaw(key) else { return nil }
        let b = raw.data
        if raw.dataType == SMCKey("ui8 ").raw, b.count >= 1 {
            return Double(b[0])
        }
        if raw.dataType == SMCKey("ui16").raw, b.count >= 2 {
            return Double(UInt32(b[0]) << 8 | UInt32(b[1]))
        }
        if raw.dataType == SMCKey("ui32").raw, b.count >= 4 {
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        }
        return nil
    }

    /// 'char ' 字符串值（F0ID 风扇名：有效内容从第 4 字节开始）。
    func readCharString(_ code: String, skipFirst: Bool) -> String? {
        let key = SMCKey(code)
        guard let raw = readRaw(key), raw.dataType == SMCKey("char").raw else { return nil }
        var bytes = raw.data
        if skipFirst && bytes.count > 4 { bytes = Array(bytes[4...]) }
        let valid = bytes.prefix { $0 != 0 }
        let s = String(decoding: valid, as: UTF8.self)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 写 fpe2（风扇 RPM ×4，大端）。
    @discardableResult
    func writeFPE2(_ code: String, value: Double) -> kern_return_t {
        let v = UInt32(max(0, (value * 4).rounded()))
        let data = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                    UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return writeRaw(SMCKey(code), data: data)
    }

    /// 写 ui8 标量（模式位等）。
    @discardableResult
    func writeUInt8(_ code: String, value: UInt8) -> kern_return_t {
        writeRaw(SMCKey(code), data: [value])
    }
}
