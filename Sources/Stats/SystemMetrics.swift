import Foundation
import Darwin

// MARK: - CPU

/// CPU 占用采样器：对内核 tick 计数做差分。
final class CPUSampler {
    private(set) var perCore: [Double] = []
    private(set) var total: Double = 0
    private var previous: [[UInt64]] = []

    /// 采样一次，返回（总占用 %，各核心占用 %）。
    func sample() -> (total: Double, cores: [Double]) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return (total, perCore) }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }

        let states = Int(CPU_STATE_MAX)
        var ticks: [[UInt64]] = []
        ticks.reserveCapacity(Int(count))
        for core in 0..<Int(count) {
            var row: [UInt64] = []
            row.reserveCapacity(states)
            for state in 0..<states {
                row.append(UInt64(info[core * states + state]))
            }
            ticks.append(row)
        }

        if previous.count == ticks.count, !previous.isEmpty {
            var cores: [Double] = []
            var totalBusy: Double = 0
            var totalAll: Double = 0
            for (now, before) in zip(ticks, previous) {
                var busy: Double = 0
                var all: Double = 0
                for s in 0..<states {
                    guard now[s] >= before[s] else { continue } // 计数回退防护
                    let d = Double(now[s] - before[s])
                    all += d
                    if s != Int(CPU_STATE_IDLE) { busy += d }
                }
                let usage = all > 0 ? min(100, busy / all * 100) : 0
                cores.append(usage)
                totalBusy += busy
                totalAll += all
            }
            perCore = cores
            total = totalAll > 0 ? min(100, totalBusy / totalAll * 100) : 0
        }
        previous = ticks
        return (total, perCore)
    }
}

// MARK: - 内存

struct MemoryInfo {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
}

func readMemoryInfo() -> MemoryInfo {
    var info = MemoryInfo()
    info.total = UInt64(sysctlInt("hw.memsize") ?? 0)

    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<Int32>.size)
    let kr = withUnsafeMutableBytes(of: &stats) { ptr in
        host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          ptr.baseAddress?.assumingMemoryBound(to: integer_t.self), &count)
    }
    if kr == KERN_SUCCESS {
        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        info.wired = wired
        info.compressed = compressed
        info.used = active + wired + compressed
    }

    // vm.swapusage: "total = 2048.00M  used = 0.00M  free = 2047.50M  (encrypted)"
    if let s = sysctlString("vm.swapusage") {
        let nums = s.split(separator: "=").compactMap { part -> Double? in
            let trimmed = part.drop { $0 == " " }.prefix { $0.isNumber || $0 == "." }
            return Double(trimmed)
        }
        if nums.count >= 2 {
            info.swapTotal = UInt64(nums[0] * 1_000_000)
            info.swapUsed = UInt64(nums[1] * 1_000_000)
        }
    }
    return info
}

// MARK: - 磁盘

struct VolumeInfo: Identifiable, Equatable {
    var id: String { mountPoint }
    let name: String
    let mountPoint: String
    let totalBytes: UInt64
    let freeBytes: UInt64
}

func readVolumes() -> [VolumeInfo] {
    var mountPtr: UnsafeMutablePointer<statfs>? = nil
    let count = getmntinfo(&mountPtr, MNT_NOWAIT)
    guard count > 0, let mountPtr else { return [] }
    var out: [VolumeInfo] = []
    for i in 0..<Int(count) {
        let m = mountPtr[i]
        let type = cTupleString(m.f_fstypename)
        guard ["apfs", "hfs", "msdos", "exfat", "nfs", "smbfs", "ufsd_NTFS", "tfat"].contains(type) else { continue }
        let mount = cTupleString(m.f_mntonname)
        // 只展示用户关心的卷：系统根 + /Volumes 下的外部/数据卷
        guard mount == "/" || mount.hasPrefix("/Volumes/") else { continue }
        guard !mount.hasPrefix("/System/Volumes/VM"),
              !mount.hasPrefix("/private/var/vm") else { continue }
        let bsize = UInt64(m.f_bsize)
        let total = UInt64(m.f_blocks) * bsize
        let free = UInt64(m.f_bavail) * bsize
        guard total > 0 else { continue }
        let name = volumeDisplayName(mount) ?? mount
        out.append(VolumeInfo(name: name, mountPoint: mount, totalBytes: total, freeBytes: free))
    }
    return out
}

private func volumeDisplayName(_ mount: String) -> String? {
    let url = URL(fileURLWithPath: mount)
    return (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
}

private func cTupleString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}

// MARK: - 网络

struct InterfaceRate: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let inBytesPerSec: Double
    let outBytesPerSec: Double
}

/// 网络流量采样器：getifaddrs(AF_LINK) 计数差分。
final class NetworkSampler {
    private var previous: [String: (in: UInt64, out: UInt64, at: Date)] = [:]

    /// 采样，返回（下行 B/s，上行 B/s，各接口速率）。
    func sample() -> (down: Double, up: Double, interfaces: [InterfaceRate]) {
        let now = counters()
        var down: Double = 0
        var up: Double = 0
        var result: [InterfaceRate] = []
        for (name, c) in now.map {
            guard name != "lo0" else { continue }
            if let prev = previous[name] {
                let dt = max(0.2, now.date.timeIntervalSince(prev.at))
                // 接口计数器可能重置/回绕（VPN 隧道重建、接口复位），
                // 计数回退时丢弃本周期差分，避免 UInt64 下溢崩溃
                let inDelta = c.in >= prev.in ? c.in - prev.in : 0
                let outDelta = c.out >= prev.out ? c.out - prev.out : 0
                let inRate = Double(inDelta) / dt
                let outRate = Double(outDelta) / dt
                down += max(0, inRate)
                up += max(0, outRate)
                result.append(InterfaceRate(name: name, inBytesPerSec: inRate, outBytesPerSec: outRate))
            }
            previous[name] = (c.in, c.out, now.date)
        }
        result.sort { ($0.inBytesPerSec + $0.outBytesPerSec) > ($1.inBytesPerSec + $1.outBytesPerSec) }
        return (down, up, result)
    }

    private func counters() -> (map: [String: (in: UInt64, out: UInt64)], date: Date) {
        var map: [String: (in: UInt64, out: UInt64)] = [:]
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (map, Date()) }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
                  let data = p.pointee.ifa_data else { continue }
            let ifd = data.assumingMemoryBound(to: if_data.self).pointee
            let name = String(cString: p.pointee.ifa_name)
            let cur = map[name] ?? (0, 0)
            map[name] = (cur.in + UInt64(ifd.ifi_ibytes), cur.out + UInt64(ifd.ifi_obytes))
        }
        return (map, Date())
    }
}

// MARK: - 系统信息

struct SystemInfo {
    var model: String
    var chip: String
    var osVersion: String
    var pCores: Int
    var eCores: Int
    var bootTime: Date
    var uptime: TimeInterval {
        max(0, Date().timeIntervalSince(bootTime))
    }

    static func read() -> SystemInfo {
        let pCores = Int(sysctlInt("hw.perflevel0.logicalcpu") ?? 0)
        let eCores = Int(sysctlInt("hw.perflevel1.logicalcpu") ?? 0)
        var boot = Date(timeIntervalSince1970: 0)
        var tv = timeval()
        var len = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &tv, &len, nil, 0) == 0 {
            boot = Date(timeIntervalSince1970: Double(tv.tv_sec))
        }
        return SystemInfo(
            model: sysctlString("hw.model") ?? "未知型号",
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            pCores: pCores,
            eCores: eCores,
            bootTime: boot
        )
    }
}

// MARK: - sysctl 辅助

func sysctlString(_ name: String) -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    var size = buffer.count
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

func sysctlInt(_ name: String) -> Int64? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}

// MARK: - 格式化

func formatBytesPerSec(_ v: Double) -> String {
    formatRate(v, unit: "B/s")
}

func formatBitsPerSec(_ v: Double) -> String {
    formatRate(v * 8, unit: "bps")
}

private func formatRate(_ v: Double, unit: String) -> String {
    let units = ["K", "M", "G", "T"]
    var value = v
    var idx = -1
    while value >= 1024, idx < units.count - 1 {
        value /= 1024
        idx += 1
    }
    if idx < 0 { return String(format: "%.0f %@", v, unit) }
    return String(format: "%.1f %@%@", value, units[idx], unit)
}

func formatBytes(_ v: UInt64) -> String {
    let bytes = ["KB", "MB", "GB", "TB"]
    var value = Double(v)
    var idx = -1
    while value >= 1024, idx < bytes.count - 1 {
        value /= 1024
        idx += 1
    }
    if idx < 0 { return String(format: "%.0f B", Double(v)) }
    return String(format: "%.1f %@", value, bytes[idx])
}

func formatDuration(_ t: TimeInterval) -> String {
    let s = Int(t)
        let days = s / 86400
    let hours = (s % 86400) / 3600
    let minutes = (s % 3600) / 60
    if days > 0 { return "\(days) 天 \(hours) 小时" }
    if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
    return "\(minutes) 分"
}
