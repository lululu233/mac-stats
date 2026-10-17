# AGENTS.md

给编码 Agent 的项目指引。人向文档见 [README.md](README.md)，本文件只写代码里看不出来的约束与踩坑。

## 项目是什么

macOS 菜单栏系统监视 App（CPU/内存/磁盘/网速/温度）+ Apple Silicon 风扇手动控制。纯 SwiftPM，零第三方依赖。已开源（MIT，仓库名 mac-stats）。

## 构建与验证

```bash
swift build                    # debug 构建（日常验证用这个）
swift build -c release         # release
./scripts/make-app.sh          # 打包 build/Stats.app（会自动生成缺失的图标）
.build/debug/Stats --cli       # 冒烟测试：一次性 JSON 输出全部指标（本机跑，需 SMC）
.build/debug/Stats --fan-test 3500 10   # 风扇写入链路端到端实测（需特权助手已装）
```

没有单元测试，`--cli` 就是回归手段：改完跑 `swift build && .build/debug/Stats --cli`，各字段有合理值即通过。

## 环境硬限制

- 本机（作者的 Mac mini M4）**只装了 Command Line Tools，没有完整 Xcode**：SwiftUI `@State` 宏缺插件编译必败。**GUI 一律纯 AppKit + Timer/DispatchQueue，别引入 SwiftUI**。
- 平台 macOS 13+（Package.swift），arm64 Apple Silicon 实测；Intel 读取路径保留但未实测。

## 架构地图（Sources/Stats/）

| 文件 | 职责 |
|---|---|
| `SMC.swift` | AppleSMC user client 封装：80 字节结构体协议、key 读写、类型解码 |
| `Sensors.swift` | 温度 key 枚举/标注、风扇状态读取 |
| `SystemMetrics.swift` | CPU/内存/磁盘/网络采样器 + 格式化 |
| `FanHelper.swift` | root 风扇守护进程（`FanDaemonCore`）+ 无特权客户端（`FanHelperClient`）+ 安装/卸载 |
| `Store.swift` | 每秒采样全局状态，tickHandlers 驱动 UI |
| `AppKitUI.swift` / `AppDelegate.swift` | 主窗口仪表盘 / 菜单栏 + 生命周期 + LaunchAgent 自愈 |

GUI 与守护进程是**同一个二进制**：`--fan-daemon <socket>` 进守护进程模式，`--cli/--watch/...` 进 CLI 模式，否则启动 GUI。

## 领域红线（改错会伤硬件或断功能）

- **SMC `flt ` 类型是 float32 小端，读和写都是**。别"修复"成大端——大端写 F0Tg 会被固件解析成 denormal，风扇会被压到 171rpm。
- **SMC 写入后固件异步生效（1-3 秒），立即读回拿到的是旧值**。模式位校验用 `waitMode` 轮询；转速成功与否以 `F{n}Ac` 实际转速收敛（±max(250, 12%)）判断，不能读回 `F{n}Tg` 比对。
- M3/M4 写风扇要先 `Ftst=1` 进诊断模式，且 thermalmonitord 会抢回——守护进程每 4 秒 reassert，别删这个逻辑。
- **改守护进程协议必须递增 `FanDaemonCore.protocolVersion`**：App 靠 ping 的 `ver=N` 握手决定是否升级助手。
- 所有系统计数器差分（网络/CPU tick/SMC）必须防回退：`cur >= prev` 否则 UInt64 下溢直接崩溃（已因此崩过一次）。

## 发布流程与雷区

1. `./scripts/make-app.sh`
2. `pkill -9 -f 'MacOS/Stats$'` —— **必须用这个锚定 pattern**。GUI 装了用户级 LaunchAgent（KeepAlive），被杀后 launchd 自动用新二进制拉起。**禁止** `pkill -f "Stats.app"`：风扇 LaunchDaemon 的命令行里含 App 二进制路径，会被误杀（launchd 重拉有 ~10s 节流，空窗期 App 会闪"安装"按钮诱导用户重输密码）。
3. 助手是指向 App 内二进制的**符号链接**：App 更新后版本握手不一致会自动 restart 助手加载新版，全程免密码。别把符号链接改回拷贝。

**不要改**：bundle ID（`com.hhq.stats` / `.app` / `.fanhelper`）、socket 路径、LaunchDaemon label——它们和已安装的 LaunchDaemon/LaunchAgent/符号链接绑定，改了等于让现有安装失灵。

**不要直接运行任意路径的二进制**：`AppDelegate.ensureLaunchAgent` 会把 LaunchAgent plist 重写为当前 exe 路径——从 `.build/debug` 直跑一次就把用户的生产 LaunchAgent 劫持到 debug 二进制。需要跑临时实例（如截图）时伪装 launchd 托管跳过 bootstrap：

```bash
env XPC_SERVICE_NAME=com.hhq.stats.app build/Stats.app/Contents/MacOS/Stats --self-shot assets/screenshot.png
```

（注：本机 shell 执行 `VAR=x cmd` 内联环境变量会崩 zsh，必须用 `env VAR=x cmd`。）

## UI 约定（AppKit 布局）

- 骨架是显式约束，不是嵌套 NSStackView（竖直 stack 的 `alignment = .width` 会静默失效）。
- 原则：**卡片尺寸由窗口唯一决定，内容只许截断/封顶不许撑开**（磁盘列表 prefix(4)、提示单行、占位行常驻）。
- UI 截图验证用 `--self-shot <path> [宽] [高]`（App 自截窗口，无需屏幕录制权限，截图后自动退出）。

## 风格

- 注释与 UI 文案用中文，与现有代码一致；注释写"为什么"（固件行为、踩过的坑），不复述代码。
- 图标是程序生成的（`scripts/make-icon.swift`），不是设计资产，改动直接改脚本。
