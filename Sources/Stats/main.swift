import AppKit

let arguments = CommandLine.arguments

// 特权风扇守护进程模式（root 运行）
if let i = arguments.firstIndex(of: "--fan-daemon"), i + 1 < arguments.count {
    FanDaemon.main(socketPath: arguments[i + 1])
}

// CLI 验证模式（不启动 GUI）
let cliFlags = ["--cli", "--watch", "--fan-test", "--smc-debug", "--helper-install", "--helper-uninstall"]
if !Set(arguments).isDisjoint(with: cliFlags) {
    CLI.run(arguments: arguments)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
if let i = arguments.firstIndex(of: "--self-shot"), i + 1 < arguments.count {
    delegate.selfShotPath = arguments[i + 1]
}
app.run()
