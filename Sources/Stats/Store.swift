import Foundation

/// 全局状态：每秒采样一次，通过 tickHandlers 驱动 AppKit 界面刷新。
final class Store {
    // CPU
    var cpuTotal: Double = 0
    var cpuCores: [Double] = []
    var cpuHistory: [Double] = []
    // 内存
    var memory = MemoryInfo()
    // 网络
    var netDown: Double = 0
    var netUp: Double = 0
    var netDownHistory: [Double] = []
    var netUpHistory: [Double] = []
    var interfaces: [InterfaceRate] = []
    // 磁盘
    var volumes: [VolumeInfo] = []
    // 传感器
    var temps: [TempReading] = []
    var tempHistory: [Double] = []
    var fans: [FanState] = []
    var fanError: String?
    // 风扇控制（特权守护进程）
    let fanHelper = FanHelperClient()
    var helperReachable = false
    var helperVersion = 0
    var helperInstalling = false
    var helperMessage: String?
    /// 助手在线且版本匹配（此时手动控制可用）。
    var helperReady: Bool {
        helperReachable && helperVersion >= FanHelperClient.expectedVersion
    }
    // 系统
    var system = SystemInfo.read()

    let sensors = SensorService()
    var tickHandlers: [() -> Void] = []

    private let cpu = CPUSampler()
    private let network = NetworkSampler()
    private var timer: Timer?
    private let historyLimit = 120
    private var tickCount = 0
    private var autoRestartAttempted = false
    private var everConnected = false
    private var unreachableSince: Date?
    private var probeFailures = 0

    /// 助手版本过旧时：若它是指向当前 App 二进制的符号链接，则让 launchd 重拉
    /// 加载新版本（免密码）；否则仍需用户点"更新风扇助手"（拷贝转链接，最后一次密码）。
    private func attemptAutoRestart() {
        autoRestartAttempted = true
        guard FanHelperClient.helperIsSymlinkToAppBinary() else { return }
        fanHelper.requestRestart()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            sleep(2)
            let info = self?.fanHelper.probe() ?? FanHelperClient.Probe()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.helperReachable = info.reachable
                self.helperVersion = info.version
                self.helperMessage = info.version >= FanHelperClient.expectedVersion
                    ? nil : "助手自动升级失败，请点“更新风扇助手…”"
                for handler in self.tickHandlers { handler() }
            }
        }
    }

    var smcAvailable: Bool { sensors.available }
    var hottestTemp: Double { temps.first?.celsius ?? 0 }

    func addTickHandler(_ handler: @escaping () -> Void) {
        tickHandlers.append(handler)
    }

    func start() {
        sensors.discover()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        tickCount += 1

        // CPU
        let cpuSample = cpu.sample()
        cpuTotal = cpuSample.total
        cpuCores = cpuSample.cores
        cpuHistory = appended(cpuHistory, cpuSample.total)

        // 内存 / 网络 / 磁盘
        memory = readMemoryInfo()
        let net = network.sample()
        netDown = net.down
        netUp = net.up
        interfaces = Array(net.interfaces.prefix(4))
        netDownHistory = appended(netDownHistory, net.down)
        netUpHistory = appended(netUpHistory, net.up)
        if volumes.isEmpty || tickCount % 60 == 0 { volumes = readVolumes() }

        // 传感器（SMC 在主线程串行访问）
        if sensors.available {
            temps = sensors.readTemperatures()
            fans = sensors.readFans()
            tempHistory = appended(tempHistory, hottestTemp)
        }
        // 每 5 秒探测一次风扇助手。
        // 曾连接成功过的场景下给 30 秒宽限（launchd 重启/节流窗口内不闪"安装"按钮，
        // 避免用户误点再次输入密码）；首次未安装则立即显示按钮。
        if tickCount % 5 == 0 {
            let info = fanHelper.probe()
            if info.reachable {
                everConnected = true
                unreachableSince = nil
                probeFailures = 0
                helperReachable = true
                helperVersion = info.version
                if info.version >= FanHelperClient.expectedVersion {
                    helperMessage = nil
                } else if !autoRestartAttempted {
                    attemptAutoRestart()
                }
            } else {
                // 单次探测超时不改状态（防抖），连续失败才判定离线
                probeFailures += 1
                if everConnected {
                    if unreachableSince == nil { unreachableSince = Date() }
                    if Date().timeIntervalSince(unreachableSince!) > 30 {
                        helperReachable = false
                    }
                } else if probeFailures >= 2 {
                    helperReachable = false
                }
            }
        }
        for handler in tickHandlers { handler() }
    }

    /// 设置手动目标转速（经特权守护进程，后台执行避免卡 UI）。
    func applyFanTarget(index: Int, rpm: Double) {
        guard helperReady else {
            fanError = "风扇助手不可用或版本过旧，请先安装/更新"
            for handler in tickHandlers { handler() }
            return
        }
        fanError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = self?.fanHelper.setTarget(index: index, rpm: rpm)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fanError = err
                if err == nil { self.fans = self.sensors.readFans() }
                for handler in self.tickHandlers { handler() }
            }
        }
    }

    /// 恢复自动模式。
    func setFanAuto(index: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let err = self?.fanHelper.setAuto(index: index)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fanError = err
                if err == nil { self.fans = self.sensors.readFans() }
                for handler in self.tickHandlers { handler() }
            }
        }
    }

    /// 安装/更新特权守护进程（弹管理员密码框，后台执行）。
    func installFanHelper() {
        guard !helperInstalling else { return }
        helperInstalling = true
        helperMessage = "正在安装，请在弹出的密码框中输入管理员密码…"
        for handler in tickHandlers { handler() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = FanHelperClient.installDaemon()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.helperInstalling = false
                let info = self.fanHelper.probe()
                self.helperReachable = info.reachable
                self.helperVersion = info.version
                self.helperMessage = result ?? (self.helperReady ? "风扇控制已就绪" : nil)
                for handler in self.tickHandlers { handler() }
            }
        }
    }

    private func appended(_ history: [Double], _ value: Double) -> [Double] {
        var out = history
        out.append(value)
        if out.count > historyLimit { out.removeFirst(out.count - historyLimit) }
        return out
    }
}
