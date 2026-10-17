import Foundation

struct TempReading: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let label: String
    let celsius: Double
}

struct FanState: Identifiable, Equatable {
    let id: Int
    var name: String
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
    var targetRPM: Double?
    /// 模式：0=自动 1=手动 3=系统(温控守护) -1=未知
    var mode: Int?
    var originalMinRPM: Double
}

/// 温度/风扇传感器服务：启动时枚举全部 sp78 温度 key，之后按秒刷新。
final class SensorService {
    let smc = SMCClient()

    private(set) var available = false
    private(set) var tempKeys: [SMCKey] = []
    private(set) var fanCount = 0
    private var originalMins: [Int: Double] = [:]

    /// 风扇编号在 SMC key 里使用的字符（0-9 之后是 A-J）。
    let fanDigits = Array("0123456789ABCDEFGHJ")

    private static let sp78Type = SMCKey("sp78").raw

    /// 已知传感器的中文名（其余按前缀推断）。
    private static let knownLabels: [String: String] = [
        "TC0P": "CPU 外壳",
        "TC0D": "CPU 核心",
        "TC0E": "CPU 核心",
        "TC0F": "CPU 核心",
        "TC0G": "CPU 核心",
        "TG0D": "GPU",
        "TG0P": "GPU",
        "TN0D": "SSD",
        "TN0P": "SSD",
        "Ts0S": "SoC",
        "Ts1S": "SoC",
        "TaLP": "环境温度",
        "TaPF": "环境温度",
        "TB1T": "电池",
        "TB2T": "电池",
        "TM0P": "内存",
    ]

    /// 枚举 SMC key，找出全部温度传感器和风扇数量。
    /// Apple Silicon 上温度多为 "flt "（float32），Intel 为 "sp78"，两者都接受，
    /// 并按读值范围（-20…130°C）过滤掉名字像温度但不是温度的 key。
    @discardableResult
    func discover() -> Bool {
        guard smc.open() else { return false }
        let total = smc.keyCount()
        var keys: [SMCKey] = []
        var seen = Set<UInt32>()
        for i in 0..<total {
            guard let (k, _) = smc.key(at: UInt32(i)) else { continue }
            guard !seen.contains(k.raw) else { continue }
            seen.insert(k.raw)
            guard k.code.hasPrefix("T"),
                  let type = smc.dataTypeCode(k.code),
                  type == "sp78" || type == "flt " else { continue }
            if let v = smc.readTemperature(k.code), v > 5, v < 130 {
                keys.append(k)
            }
        }
        keys.sort { $0.raw < $1.raw }
        tempKeys = keys
        fanCount = Int(smc.readUInt("FNum") ?? 0)
        available = true
        return true
    }

    /// 读取全部温度，按温度降序。
    func readTemperatures() -> [TempReading] {
        var out: [TempReading] = []
        for k in tempKeys {
            if let v = smc.readTemperature(k.code) {
                out.append(TempReading(key: k.code, label: Self.label(for: k.code), celsius: v))
            }
        }
        out.sort { $0.celsius > $1.celsius }
        return out
    }

    /// 读取全部风扇状态（RPM、最小/最大、当前模式）。
    func readFans() -> [FanState] {
        guard fanCount > 0 else { return [] }
        var fans: [FanState] = []
        for i in 0..<min(fanCount, fanDigits.count) {
            let d = String(fanDigits[i])
            let rpm = smc.readNumber("F\(d)Ac") ?? 0
            var mn = smc.readNumber("F\(d)Mn") ?? 0
            let mx = smc.readNumber("F\(d)Mx") ?? 0
            let tg = smc.readNumber("F\(d)Tg")
            // 首次读到时记住出厂最低转速，用于"恢复默认"
            if mn > 0 {
                if originalMins[i] == nil { originalMins[i] = mn }
                else { mn = originalMins[i] ?? mn }
            }
            fans.append(FanState(
                id: i,
                name: fanName(digit: d, index: i),
                rpm: rpm,
                minRPM: mn,
                maxRPM: mx,
                targetRPM: tg,
                mode: Int(smc.readUInt("F\(d)Md") ?? -1),
                originalMinRPM: originalMins[i] ?? mn
            ))
        }
        return fans
    }

    // MARK: - 私有

    private func fanName(digit: String, index: Int) -> String {
        for code in ["F\(digit)ID", "F\(digit)Id", "F\(digit)id"] {
            if let s = smc.readCharString(code, skipFirst: true), !s.isEmpty {
                return s
            }
        }
        return "风扇 \(index + 1)"
    }
}

extension SensorService {
    /// 传感器 key → 展示名。
    static func label(for key: String) -> String {
        if let l = knownLabels[key] { return l }
        let prefix = String(key.prefix(2))
        let rest = String(key.dropFirst(2))
        let prefix3 = String(key.prefix(3))
        if prefix3 == "TCM" { return "CPU 峰值" }
        switch prefix {
        case "Tp": return "P核心 \(rest)"
        case "Te": return "E核心 \(rest)"
        case "Tg": return "GPU \(rest)"
        case "TG": return "GPU"
        case "TC": return "CPU \(rest)"
        case "TN": return "SSD \(rest)"
        case "Tm", "TM": return "内存 \(rest)"
        case "Ts", "TS": return "SoC \(rest)"
        case "Ta", "TA": return "环境 \(rest)"
        default: return key
        }
    }
}
