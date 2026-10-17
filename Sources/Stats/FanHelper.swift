import Foundation
import Darwin

// MARK: - 特权风扇守护进程（root 运行）
//
// Apple Silicon 上 SMC 风扇写入被固件限制为 root，且 M3/M4 需要先进入
// 诊断模式（Ftst=1）再切手动模式（F0Md=1），最后写目标转速（F0Tg, float）。
// 协议参考: https://github.com/agoodkind/macos-smc-fan

enum FanDaemon {
    static let socketPath = "/tmp/com.hhq.stats.fanhelper.sock"

    static func main(socketPath: String) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let core = FanDaemonCore(socketPath: socketPath)
        core.start()
        print("[fanhelper] running, socket=\(socketPath)")
        RunLoop.current.run()
        exit(0)
    }
}

final class FanDaemonCore: NSObject {
    /// 协议版本：v2 = flt 小端写入；v3 = 转速收敛校验；v4 = restart+符号链接；v5 = auto 轮询确认。
    static let protocolVersion = 5

    /// 风扇编号在 SMC key 里使用的字符（0-9 之后是 A-J），与 SensorService.fanDigits 一致。
    private static let fanDigits = Array("0123456789ABCDEFGHJ")

    /// 风扇索引 → SMC key 前缀（如 0 → "F0"、10 → "FA"）。
    private func fanPrefix(_ index: Int) -> String {
        "F\(index < Self.fanDigits.count ? Self.fanDigits[index] : Character(String(index)))"
    }

    private let socketPath: String
    private let smc = SMCClient()
    private var fanCount = 0
    /// 手动目标（fan index → rpm）。非空时持续维持手动模式。
    private var manualTargets: [Int: Double] = [:]
    private var fd: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(socketPath: String) {
        self.socketPath = socketPath
        super.init()
    }

    func start() {
        guard smc.open() else {
            print("[fanhelper] AppleSMC 打开失败")
            return
        }
        fanCount = Int(smc.readUInt("FNum") ?? 0)
        print("[fanhelper] fans=\(fanCount)")

        // SIGTERM/SIGINT → 恢复自动模式再退出
        let signals = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signals.setEventHandler { [weak self] in
            print("[fanhelper] 收到 SIGTERM，恢复自动模式")
            self?.restoreAllAndExit()
        }
        signals.resume()
        signal(SIGTERM, SIG_IGN)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler { [weak self] in self?.restoreAllAndExit() }
        intSource.resume()
        signal(SIGINT, SIG_IGN)

        // 每 4 秒重新确认手动模式仍生效（thermalmonitord 会抢回；唤醒后 Ftst 清零）
        let timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.reassert()
        }
        RunLoop.current.add(timer, forMode: .default)

        startListening()
    }

    // MARK: socket 服务

    private func startListening() {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { print("[fanhelper] socket() 失败: \(errno)"); return }
        self.fd = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { print("[fanhelper] bind 失败: \(errno)"); return }
        guard listen(fd, 8) == 0 else { print("[fanhelper] listen 失败: \(errno)"); return }
        chmod(socketPath, 0o666)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.acceptOnce() }
        source.resume()
        acceptSource = source
    }

    private func acceptOnce() {
        var clientAddr = sockaddr()
        var len = socklen_t(MemoryLayout<sockaddr>.size)
        let client = accept(fd, &clientAddr, &len)
        guard client >= 0 else { return }
        defer { close(client) }

        // 逐行读取一条命令并应答（简单协议：一行请求一行响应）
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 512)
        while buffer.count < 4096 {
            let n = read(client, &chunk, chunk.count)
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.contains(UInt8(ascii: "\n")) { break }
        }
        guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return }
        let line = String(decoding: buffer[0..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        let response = handle(command: line)
        var out = Array((response + "\n").utf8)
        _ = out.withUnsafeMutableBytes { raw in write(client, raw.baseAddress, raw.count) }
        _ = out.removeAll()
    }

    // MARK: 命令处理

    private func handle(command: String) -> String {
        let parts = command.split(separator: " ")
        guard let verb = parts.first else { return "ERR 空命令" }
        switch verb {
        case "ping":
            return "OK pid=\(getpid()) fans=\(fanCount) ver=\(Self.protocolVersion)"
        case "state":
            let state = (0..<fanCount).map { i in
                let md = Int(smc.readUInt("\(fanPrefix(i))Md") ?? -1)
                let tg = manualTargets[i].map { String(format: "%.0f", $0) } ?? "-"
                return "\(i):\(md):\(tg)"
            }.joined(separator: " ")
            return "OK \(state)"
        case "set":
            guard parts.count >= 3, let idx = Int(parts[1]), let rpm = Double(parts[2]) else {
                return "ERR 参数: set <index> <rpm>"
            }
            guard idx >= 0, idx < fanCount else { return "ERR 风扇不存在" }
            if let err = enterManualAndSet(index: idx, rpm: rpm) {
                return "ERR \(err)"
            }
            return "OK"
        case "auto":
            guard parts.count >= 2, let idx = Int(parts[1]) else { return "ERR 参数: auto <index>" }
            guard idx >= 0, idx < fanCount else { return "ERR 风扇不存在" }
            manualTargets[idx] = nil
            // 模式位写入异步生效，轮询确认；必要时重写一次
            _ = smc.writeUInt8("\(fanPrefix(idx))Md", value: 0)
            if !waitMode("\(fanPrefix(idx))Md", expected: 0) {
                _ = smc.writeUInt8("\(fanPrefix(idx))Md", value: 0)
                if !waitMode("\(fanPrefix(idx))Md", expected: 0) {
                    return "ERR 恢复自动失败（模式未回落）"
                }
            }
            if manualTargets.isEmpty { _ = smc.writeUInt8("Ftst", value: 0) }
            return "OK"
        case "shutdown":
            restoreAllAndExit()
            return "OK"
        case "restart":
            // 供 App 在助手二进制更新后（符号链接指向新包）触发重载；KeepAlive 会自动拉起
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            return "OK"
        default:
            return "ERR 未知命令 \(verb)"
        }
    }

    // MARK: 解锁与写入（M4 路径）

    /// 进入手动模式并写目标转速。返回 nil 表示成功。
    /// 注意：SMC 写入后固件异步生效（1-3 秒），校验必须轮询等待，不能立即读回。
    private func enterManualAndSet(index: Int, rpm: Double) -> String? {
        let modeKey = "\(fanPrefix(index))Md"
        let targetKey = "\(fanPrefix(index))Tg"

        // 已经是手动模式 → 直接写目标
        if Int(smc.readUInt(modeKey) ?? -1) == 1 {
            return writeTarget(index: index, rpm: rpm)
        }
        // 先试直接写模式（部分机型可行），轮询确认
        _ = smc.writeUInt8(modeKey, value: 1)
        if waitMode(modeKey, expected: 1) {
            return writeTarget(index: index, rpm: rpm)
        }
        // M4 兜底：诊断模式解锁后重试；部分机型无 Ftst，失败也继续
        if smc.writeUInt8("Ftst", value: 1) != KERN_SUCCESS {
            print("[fanhelper] Ftst 写入失败（key 可能不存在），继续尝试直接写模式")
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            usleep(200_000)
            _ = smc.writeUInt8(modeKey, value: 1)
            if waitMode(modeKey, expected: 1) {
                return writeTarget(index: index, rpm: rpm)
            }
        }
        return "无法进入手动模式（F\(index)Md 写入未被接受）"
    }

    /// 轮询等待模式位变为期望值（写入后固件异步生效）。
    private func waitMode(_ key: String, expected: Int) -> Bool {
        for _ in 0..<8 {
            usleep(150_000)
            if Int(smc.readUInt(key) ?? -1) == expected { return true }
        }
        return false
    }

    /// 写目标转速，以“实际转速收敛”为成功依据（F0Ac 会追上 F0Tg）。
    private func writeTarget(index: Int, rpm: Double) -> String? {
        let kr = smc.writeNumber("\(fanPrefix(index))Tg", value: rpm)
        if kr != KERN_SUCCESS {
            return "写目标转速失败 (\(kr))"
        }
        manualTargets[index] = rpm
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            usleep(300_000)
            if let ac = smc.readNumber("\(fanPrefix(index))Ac"),
               abs(ac - rpm) < max(250, rpm * 0.12) {
                print("[fanhelper] 目标 \(Int(rpm)) 已生效（实际 \(Int(ac)) rpm）")
                return nil
            }
        }
        // 写入成功但 6 秒内未观察到收敛：仍视为已写入（实测写入均有效），只记日志
        print("[fanhelper] 目标 \(Int(rpm)) 已写入，转速暂未收敛")
        return nil
    }

    /// 周期性维持：手动模式被抢回或唤醒失效时重新应用。
    private func reassert() {
        for (idx, rpm) in manualTargets {
            let md = Int(smc.readUInt("\(fanPrefix(idx))Md") ?? -1)
            if md != 1 {
                print("[fanhelper] reassert: 风扇\(idx) 模式=\(md)，重新解锁")
                _ = enterManualAndSet(index: idx, rpm: rpm)
            } else if let cur = smc.readNumber("\(fanPrefix(idx))Tg"), abs(cur - rpm) > 80 {
                _ = writeTarget(index: idx, rpm: rpm)
            }
        }
    }

    private func restoreAllAndExit() {
        for idx in 0..<fanCount {
            _ = smc.writeUInt8("\(fanPrefix(idx))Md", value: 0)
        }
        manualTargets.removeAll()
        _ = smc.writeUInt8("Ftst", value: 0)
        exit(0)
    }
}

// MARK: - 客户端（app 侧，无特权）

struct FanHelperClient {
    static let socketPath = FanDaemon.socketPath
    static let daemonLabel = "com.hhq.stats.fanhelper"
    static let daemonBinary = "/Library/PrivilegedHelperTools/com.hhq.stats.fanhelper"
    static let daemonPlist = "/Library/LaunchDaemons/com.hhq.stats.fanhelper.plist"
    /// 当前 App 期望的助手协议版本。
    static let expectedVersion = FanDaemonCore.protocolVersion

    private func communicate(_ command: String, timeoutSec: UInt32 = 3) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: Int(timeoutSec), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Self.socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        var request = Array((command + "\n").utf8)
        let sent = request.withUnsafeMutableBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }
        guard sent > 0 else { return nil }

        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 512)
        while buffer.count < 4096 {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.contains(UInt8(ascii: "\n")) { break }
        }
        guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return String(decoding: buffer[0..<newline], as: UTF8.self)
    }

    struct Probe {
        var reachable = false
        var version = 0
    }

    /// 探测守护进程：是否在线、协议版本。
    func probe() -> Probe {
        guard let reply = communicate("ping", timeoutSec: 1), reply.hasPrefix("OK") else {
            return Probe()
        }
        var p = Probe(reachable: true, version: 1) // v1 无 ver 字段
        if let range = reply.range(of: "ver=") {
            p.version = Int(reply[range.upperBound...].prefix { $0.isNumber }) ?? 1
        }
        return p
    }

    var isReachable: Bool {
        probe().reachable
    }

    /// 让守护进程退出并由 launchd 重拉（用于二进制更新后自动加载新版）。
    @discardableResult
    func requestRestart() -> Bool {
        communicate("restart", timeoutSec: 2)?.hasPrefix("OK") == true
    }

    /// 已安装的助手是否是指向当前 App 二进制的符号链接（是则可免密码自动更新）。
    static func helperIsSymlinkToAppBinary() -> Bool {
        let fm = FileManager.default
        guard let exe = Bundle.main.executableURL?.standardizedFileURL else { return false }
        let helperURL = URL(fileURLWithPath: daemonBinary)
        guard let attrs = try? fm.attributesOfItem(atPath: helperURL.path),
              attrs[.type] as? FileAttributeType == .typeSymbolicLink else {
            return false
        }
        let resolved = (try? helperURL.resolvingSymlinksInPath().standardizedFileURL) ?? helperURL
        return resolved.path == exe.path
    }

    /// 设定手动目标转速。nil = 成功，否则为错误描述。
    /// 超时给足 12 秒：守护进程写完后要轮询转速收敛（固件异步生效）。
    func setTarget(index: Int, rpm: Double) -> String? {
        guard let reply = communicate("set \(index) \(Int(rpm))", timeoutSec: 12) else { return "无法连接风扇助手" }
        return reply.hasPrefix("OK") ? nil : String(reply.dropFirst(4))
    }

    /// 恢复自动模式。
    func setAuto(index: Int) -> String? {
        guard let reply = communicate("auto \(index)", timeoutSec: 12) else { return "无法连接风扇助手" }
        return reply.hasPrefix("OK") ? nil : String(reply.dropFirst(4))
    }

    // MARK: 安装/卸载（osascript 管理员授权）

    /// 生成 LaunchDaemon plist 内容。
    private static func daemonPlistContent(binary: String, socket: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>--fan-daemon</string>
                <string>\(socket)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardOutPath</key><string>/tmp/com.hhq.stats.fanhelper.log</string>
            <key>StandardErrorPath</key><string>/tmp/com.hhq.stats.fanhelper.log</string>
        </dict>
        </plist>
        """
    }

    /// 通过 osascript 弹出管理员密码框安装守护进程。
    /// 助手以【符号链接】指向 App 内二进制：以后 App 更新后无需再输密码，
    /// 由 App 发送 restart 命令让 launchd 重新拉起（加载的即是新二进制）。
    static func installDaemon() -> String? {
        guard let exe = Bundle.main.executableURL?.path, FileManager.default.isExecutableFile(atPath: exe) else {
            return "找不到当前可执行文件"
        }
        let staging = "/tmp/com.hhq.stats.fanhelper.plist"
        do {
            try daemonPlistContent(binary: daemonBinary, socket: socketPath)
                .write(toFile: staging, atomically: true, encoding: .utf8)
        } catch {
            return "写入临时 plist 失败: \(error.localizedDescription)"
        }
        var shell = [
            "mkdir -p /Library/PrivilegedHelperTools",
            "rm -f '\(daemonBinary)'",
            "ln -s '\(exe)' '\(daemonBinary)'",
            "cp -f '\(staging)' '\(daemonPlist)'",
            "chmod 644 '\(daemonPlist)'",
            "rm -f '\(socketPath)'",
            "launchctl bootout system/\(daemonLabel) 2>/dev/null || true",
            "launchctl bootstrap system '\(daemonPlist)'",
        ].joined(separator: " ; ")
        shell = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(shell)\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return "osascript 启动失败: \(error.localizedDescription)"
        }
        guard task.terminationStatus == 0 else {
            let err = (task.standardError as? Pipe)?
                .fileHandleForReading.readDataToEndOfFile()
            let message = err.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return "安装被取消或失败: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        // 等待守护进程上线
        for _ in 0..<20 {
            if FanHelperClient().isReachable { return nil }
            usleep(300_000)
        }
        return "守护进程已安装但未响应，请稍后重试或查看 /tmp/com.hhq.stats.fanhelper.log"
    }

    /// 卸载守护进程。
    static func uninstallDaemon() -> String? {
        var shell = [
            "launchctl bootout system/\(daemonLabel) 2>/dev/null || true",
            "rm -f '\(daemonPlist)'",
            "rm -f '\(daemonBinary)'",
            "rm -f '\(socketPath)'",
        ].joined(separator: " ; ")
        shell = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(shell)\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return "osascript 启动失败: \(error.localizedDescription)"
        }
        return task.terminationStatus == 0 ? nil : "卸载失败"
    }
}
