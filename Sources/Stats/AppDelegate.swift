import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private lazy var dashboard = DashboardController(store: store)
    private var statusItem: NSStatusItem?
    private var statusLabels: [String: NSMenuItem] = [:]
    var selfShotPath: String?
    private var tickCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureLaunchAgent()
        store.addTickHandler { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.tickCount += 1
            strongSelf.dashboard.update()
            strongSelf.refreshStatusItem()
            if strongSelf.tickCount == 5 { strongSelf.takeSelfShot() }
        }
        dashboard.show()
        store.start()
        makeStatusItem()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 用户级 LaunchAgent：崩溃自动重启（干净退出不拉起）、登录自启，无需管理员密码。
    /// 首次 bootstrap 会由 launchd 拉起一个托管实例；若当前是手动启动的实例则让位退出。
    private func ensureLaunchAgent() {
        let label = "com.hhq.stats.app"
        let env = ProcessInfo.processInfo.environment
        let launchdOwned = env["XPC_SERVICE_NAME"]?.hasPrefix(label) == true

        guard let exe = Bundle.main.executableURL?.path else { return }
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
        let fm = FileManager.default
        var needsWrite = true
        if let data = fm.contents(atPath: plistPath),
           let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dict = obj as? [String: Any],
           (dict["ProgramArguments"] as? [String])?.first == exe {
            needsWrite = false
        }
        guard needsWrite || !launchdOwned else { return }

        let uid = getuid()
        if needsWrite {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
            ]
            let dir = (plistPath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? data.write(to: URL(fileURLWithPath: plistPath))
            }
            runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
            usleep(400_000)
        }
        let status = runLaunchctl(["bootstrap", "gui/\(uid)", plistPath])
        if status == 0, !launchdOwned {
            // launchd 正在拉起托管实例，本实例让位（exit 0 不会被 KeepAlive 重启）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// 调试：抓取自己窗口的截图后退出（不需要屏幕录制权限）。
    private func takeSelfShot() {
        guard let path = selfShotPath, let window = dashboard.window else { return }
        // 可选：--self-shot <path> [width] [height] 指定窗口尺寸
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--self-shot"), i + 3 < args.count,
           let w = Double(args[i + 2]), let h = Double(args[i + 3]) {
            window.setContentSize(NSSize(width: w, height: h))
            window.center()
        }
        print("selfshot state: smc=\(store.smcAvailable) temps=\(store.temps.count) fans=\(store.fans.count)")
        print("selfshot cont: helper=\(store.helperReachable) cpu=\(store.cpuTotal) ui=\(dashboard.uiDebugState)")
        window.contentView?.layoutSubtreeIfNeeded()
        func dump(_ v: NSView, _ depth: Int) {
            guard depth <= 3 else { return }
            let f = v.frame
            print(String(repeating: "  ", count: depth) + "\(type(of: v)) \(Int(f.width))x\(Int(f.height)) @\(Int(f.minX)),\(Int(f.minY))")
            for sub in v.subviews { dump(sub, depth + 1) }
        }
        dump(window.contentView!, 0)
        let windowID = CGWindowID(window.windowNumber)
        // CG 坐标系原点在左上，与 Cocoa 翻转
        let wf = window.frame
        let sf = window.screen?.frame ?? NSScreen.main?.frame ?? wf
        let cgRect = CGRect(x: wf.minX, y: sf.maxY - wf.maxY, width: wf.width, height: wf.height)
        guard let image = CGWindowListCreateImage(cgRect, [.optionIncludingWindow], windowID, [.bestResolution]),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("self-shot 失败")
            NSApp.terminate(nil)
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("self-shot 已写入 \(path) 尺寸=\(image.width)x\(image.height) 窗口=\(window.frame)")
        NSApp.terminate(nil)
    }

    // MARK: - 菜单栏

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monoDigits(12, .medium)

        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "打开 Stats", action: #selector(DashboardController.showWindow), keyEquivalent: "o")
        open.target = dashboard
        menu.addItem(open)
        menu.addItem(.separator())

        func labelItem(_ id: String, _ title: String) {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
            statusLabels[id] = mi
        }
        labelItem("cpu", "CPU —")
        labelItem("mem", "内存 —")
        labelItem("net", "网络 —")
        labelItem("temp", "温度 —")
        labelItem("fan", "风扇 —")

        // 风扇快捷档位（对全部风扇生效）
        menu.addItem(.separator())
        let auto = NSMenuItem(title: "风扇 · 自动", action: #selector(quickFanAuto(_:)), keyEquivalent: "")
        auto.target = self
        auto.isAlternate = false
        menu.addItem(auto)
        fanAutoItem = auto
        for (name, rpm) in fanPresets {
            let mi = NSMenuItem(title: "风扇 · \(name)（\(rpm) rpm）",
                                action: #selector(quickFanPreset(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = NSNumber(value: rpm)
            menu.addItem(mi)
            fanPresetItems.append(mi)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
        refreshStatusItem()
    }

    /// 快捷档位：按风扇实际 min/max 转速动态计算（不同机型范围差异很大）。
    private var fanPresets: [(String, Int)] {
        guard let f = store.fans.first, f.maxRPM > f.minRPM else { return Self.fallbackPresets }
        let range = f.maxRPM - f.minRPM
        return [
            ("静音", Int((f.minRPM + max(200, range * 0.12)).rounded())),
            ("均衡", Int(((f.minRPM + f.maxRPM) / 2).rounded())),
            ("全速", Int(f.maxRPM.rounded())),
        ]
    }
    /// 风扇转速读不到时的兜底档位。
    private static let fallbackPresets: [(String, Int)] = [
        ("静音", 1400), ("均衡", 2500), ("全速", 4900),
    ]
    private var fanAutoItem: NSMenuItem?
    private var fanPresetItems: [NSMenuItem] = []

    @objc private func quickFanAuto(_ sender: NSMenuItem) {
        for fan in store.fans { store.setFanAuto(index: fan.id) }
    }

    @objc private func quickFanPreset(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        for fan in store.fans { store.applyFanTarget(index: fan.id, rpm: num.doubleValue) }
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let cpu = Int(store.cpuTotal.rounded())
        let temp = store.hottestTemp > 0 ? " \(Int(store.hottestTemp.rounded()))°" : ""
        let fan = store.fans.first.map { " \(Int($0.rpm))rpm" } ?? ""
        button.title = "⚙︎ \(cpu)%\(temp)\(fan)"

        func set(_ id: String, _ text: String) { statusLabels[id]?.title = text }
        set("cpu", String(format: "CPU  %.1f%%  (%d 核)", store.cpuTotal, store.cpuCores.count))
        set("mem", String(format: "内存  %@ / %@", formatBytes(store.memory.used), formatBytes(store.memory.total)))
        set("net", "网络  ↓\(formatBytesPerSec(store.netDown))  ↑\(formatBytesPerSec(store.netUp))")
        let top = store.temps.prefix(3)
            .map { String(format: "%@ %.1f°C", $0.label, $0.celsius) }
            .joined(separator: " · ")
        set("temp", top.isEmpty ? "温度  不可用" : "温度  \(top)")
        if let f = store.fans.first {
            set("fan", String(format: "风扇  %@ %.0f rpm（%@）", f.name, f.rpm,
                              fanModeText(f)))
        }

        // 快捷档位：可用性跟随助手；勾选跟随当前档位
        let ready = store.helperReady
        fanAutoItem?.isEnabled = ready
        fanAutoItem?.state = fanIsAuto ? .on : .off
        for mi in fanPresetItems {
            mi.isEnabled = ready
            mi.state = (!fanIsAuto && matchesPreset(mi)) ? .on : .off
        }
    }

    private var fanIsAuto: Bool {
        guard let f = store.fans.first else { return false }
        return f.mode != 1
    }

    private func matchesPreset(_ item: NSMenuItem) -> Bool {
        guard let num = item.representedObject as? NSNumber,
              let f = store.fans.first, let target = f.targetRPM else { return false }
        return abs(target - num.doubleValue) < 100
    }

    private func fanModeText(_ f: FanState) -> String {
        switch f.mode {
        case 1:
            if let t = f.targetRPM, let preset = fanPresets.first(where: { abs(Double($0.1) - t) < 100 }) {
                return preset.0
            }
            return "手动 \(Int(f.targetRPM ?? 0))"
        case 3: return "系统温控"
        default: return "自动"
        }
    }
}
