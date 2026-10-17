import Foundation

/// 命令行模式：不启动 GUI，用于验证传感器/指标读取与风扇写入。
///   Stats --cli              打印一次全部指标的 JSON
///   Stats --watch            每 2 秒打印一行实时概览
///   Stats --fan-test <rpm> [秒]  风扇写入实测：设最低转速→观察→恢复
enum CLI {
    static func run(arguments: [String]) -> Never {
        if arguments.contains("--smc-debug") { smcDebug() }
        if arguments.contains("--watch") { watch() }
        if arguments.contains("--helper-install") {
            if let err = FanHelperClient.installDaemon() { print("安装失败: \(err)"); exit(1) }
            print("风扇控制助手已安装并运行"); exit(0)
        }
        if arguments.contains("--helper-uninstall") {
            if let err = FanHelperClient.uninstallDaemon() { print("卸载失败: \(err)"); exit(1) }
            print("风扇控制助手已卸载"); exit(0)
        }
        if let i = arguments.firstIndex(of: "--fan-test"), i + 1 < arguments.count {
            let rpm = Double(arguments[i + 1]) ?? 3000
            let seconds = i + 2 < arguments.count ? Int(arguments[i + 2]) ?? 8 : 8
            fanTest(rpm: rpm, seconds: seconds)
        }
        dumpOnce()
        exit(0)
    }

    // MARK: - SMC 底层调试

    private static func smcDebug() -> Never {
        let smc = SMCClient()
        guard smc.open() else { print("AppleSMC 打开失败"); exit(1) }
        print("keyCount = \(smc.keyCount())")

        print("\n== keyInfo(子命令9) 尝试 ==")
        for code in ["FNum", "F0Ac", "F0ac", "F0AC", "F0Mn", "F0Mx", "F0Tg", "F0Sf", "F0ID", "F0Id", "F0id",
                     "TC0P", "Tp01", "Ts0S", "FS! ", "F0Md", "#KEY"] {
            if let info = smc.keyInfo(SMCKey(code)) {
                print("  \(code): size=\(info.dataSize) type=\(SMCKey(raw: info.dataType).code)")
            } else {
                print("  \(code): keyInfo 失败")
            }
        }

        print("\n== 索引枚举(子命令8, 前 12 个) ==")
        for i in 0..<12 {
            if let (k, t) = smc.key(at: UInt32(i)) {
                print("  [\(i)] key=\(k.code) typeFromIndex=\(SMCKey(raw: t).code)")
            } else {
                print("  [\(i)] 失败")
            }
        }

        print("\n== 风扇写实验（全部写回当前值/安全的无操作）==")
        let md = smc.readUInt("F0Md")
        let mn = smc.readNumber("F0Mn")
        let tg = smc.readNumber("F0Tg")
        let mx = smc.readNumber("F0Mx")
        print("  当前值: F0Md=\(md ?? -1) F0Mn=\(mn ?? -1) F0Mx=\(mx ?? -1) F0Tg=\(tg ?? -1)")
        func tryWrite(_ code: String, _ value: Double?) {
            guard let value else { print("  write \(code): 无法读取当前值，跳过"); return }
            let kr = smc.writeNumber(code, value: value)
            print("  write \(code)=\(value): \(kr == KERN_SUCCESS ? "成功" : "失败 \(kr) \(String(cString: mach_error_string(kr)))")")
        }
        tryWrite("F0Mn", mn)
        tryWrite("F0Tg", tg)
        tryWrite("F0Md", md)
        exit(0)
    }

    // MARK: - 一次性 JSON dump

    private static func dumpOnce() {
        var out: [String: Any] = [:]

        let sys = SystemInfo.read()
        out["system"] = [
            "model": sys.model,
            "chip": sys.chip,
            "os": sys.osVersion,
            "pCores": sys.pCores,
            "eCores": sys.eCores,
            "uptimeSec": Int(sys.uptime),
        ] as [String: Any]

        let mem = readMemoryInfo()
        out["memory"] = [
            "total": mem.total, "used": mem.used,
            "wired": mem.wired, "compressed": mem.compressed,
            "swapUsed": mem.swapUsed,
        ] as [String: Any]

        let cpu = CPUSampler()
        _ = cpu.sample()
        usleep(400_000)
        let cpu2 = cpu.sample()
        out["cpu"] = ["totalPercent": cpu2.total, "cores": cpu2.cores] as [String: Any]

        let net = NetworkSampler()
        _ = net.sample()
        usleep(400_000)
        let net2 = net.sample()
        out["network"] = [
            "downBytesPerSec": net2.down,
            "upBytesPerSec": net2.up,
            "interfaces": net2.interfaces.map { ["name": $0.name, "in": $0.inBytesPerSec, "out": $0.outBytesPerSec] },
        ] as [String: Any]

        out["volumes"] = readVolumes().map { ["name": $0.name, "mount": $0.mountPoint, "total": $0.totalBytes, "free": $0.freeBytes] }

        // SMC 传感器
        let svc = SensorService()
        if svc.discover() {
            let fans = svc.readFans()
            var smc: [String: Any] = [
                "keyCount": svc.smc.keyCount(),
                "tempKeyCount": svc.tempKeys.count,
                "fanCount": svc.fanCount,
            ]
            // 无操作写入测试：把当前最低转速原值写回，验证写入权限
            if let first = fans.first, first.minRPM > 0 {
                let kr = svc.smc.writeNumber("F\(svc.fanDigits[first.id])Mn", value: first.minRPM)
                smc["fanWriteTest"] = [
                    "key": "F\(svc.fanDigits[first.id])Mn",
                    "kernResult": Int(kr),
                    "error": kr == KERN_SUCCESS ? "" : String(cString: mach_error_string(kr)),
                ] as [String: Any]
            }
            out["smc"] = smc
            out["fans"] = fans.map { fan in
                [
                    "name": fan.name, "rpm": fan.rpm, "min": fan.minRPM,
                    "max": fan.maxRPM, "target": fan.targetRPM ?? -1,
                    "mode": fan.mode ?? -1,
                ] as [String: Any]
            }
            out["temps"] = svc.readTemperatures().map { ["key": $0.key, "label": $0.label, "c": $0.celsius] }
        } else {
            out["smc"] = "open failed"
        }

        if let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("JSON 编码失败")
        }
    }

    // MARK: - 持续监视

    private static func watch() -> Never {
        let svc = SensorService()
        _ = svc.discover()
        let cpu = CPUSampler()
        let net = NetworkSampler()
        _ = cpu.sample()
        _ = net.sample()
        while true {
            sleep(2)
            let c = cpu.sample()
            let n = net.sample()
            let temps = svc.readTemperatures().prefix(3)
            let fans = svc.readFans()
            let tempStr = temps.map { String(format: "%@=%.1f°C", $0.key, $0.celsius) }.joined(separator: " ")
            let fanStr = fans.map { String(format: "%@ %.0frpm(>=%.0f)", $0.name, $0.rpm, $0.minRPM) }.joined(separator: " ")
            print(String(format: "%@ CPU %5.1f%% ↓%@ ↑%@ | %@ | %@",
                         DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium),
                         c.total,
                         formatBytesPerSec(n.down), formatBytesPerSec(n.up),
                         tempStr, fanStr))
            fflush(stdout)
        }
    }

    // MARK: - 风扇写入实测（经特权守护进程）

    private static func fanTest(rpm: Double, seconds: Int) -> Never {
        let client = FanHelperClient()
        let svc = SensorService()
        guard svc.discover(), let fan = svc.readFans().first else {
            print("无法读取风扇"); exit(1)
        }
        print(String(format: "风扇: %@ 当前 %.0f rpm (范围 %.0f–%.0f, 模式 %@)",
                     fan.name, fan.rpm, fan.minRPM, fan.maxRPM,
                     fan.mode.map(String.init) ?? "?"))
        guard client.isReachable else {
            print("风扇控制助手未运行。先安装：\(CommandLine.arguments[0]) --helper-install（或 App 内“启用风扇控制”）")
            exit(1)
        }
        print(String(format: "→ 手动目标 %.0f rpm ...", rpm))
        if let err = client.setTarget(index: fan.id, rpm: rpm) {
            print("设置失败: \(err)"); exit(1)
        }
        for i in 1...seconds {
            sleep(1)
            if let f = svc.readFans().first(where: { $0.id == fan.id }) {
                print(String(format: "  %2ds 后: 实际 %.0f rpm (目标 %.0f, 模式 %d)", i, f.rpm, f.targetRPM ?? -1, f.mode ?? -1))
            }
            fflush(stdout)
        }
        print("→ 恢复自动模式 ...")
        if let err = client.setAuto(index: fan.id) {
            print("恢复失败: \(err)"); exit(1)
        }
        sleep(2)
        if let f = svc.readFans().first(where: { $0.id == fan.id }) {
            print(String(format: "已恢复: 实际 %.0f rpm (模式 %d)", f.rpm, f.mode ?? -1))
        }
        exit(0)
    }
}
