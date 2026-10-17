import AppKit

// MARK: - 字体辅助

extension NSFont {
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = base.fontDescriptor.withDesign(.rounded),
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return base
    }

    static func monoDigits(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

// MARK: - 调色板（深浅色自适应）

enum Palette {
    static let isDark = NSApp.effectiveAppearance
        .bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil

    static var windowBackground: NSColor {
        isDark ? NSColor(calibratedWhite: 0.098, alpha: 1)
               : NSColor(calibratedWhite: 0.955, alpha: 1)
    }

    static var cardBackground: NSColor {
        isDark ? NSColor(calibratedWhite: 0.155, alpha: 1)
               : NSColor.white
    }

    static var hairline: NSColor {
        isDark ? NSColor(calibratedWhite: 1.0, alpha: 0.09)
               : NSColor(calibratedWhite: 0.0, alpha: 0.10)
    }

    static func usageColor(_ pct: Double) -> NSColor {
        switch pct {
        case ..<50: return .systemGreen
        case ..<80: return .systemOrange
        default: return .systemRed
        }
    }

    static func tempColor(_ c: Double) -> NSColor {
        switch c {
        case ..<45: return .systemBlue
        case ..<60: return .systemGreen
        case ..<75: return .systemOrange
        default: return .systemRed
        }
    }
}

// MARK: - 自绘控件

/// 平滑迷你折线图（可多条曲线 + 渐变填充）。
final class LineChartView: NSView {
    struct Series {
        var values: [Double]
        var color: NSColor
        var filled: Bool
    }

    var series: [Series] = [] { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 1.8

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 8, bounds.height > 8 else { return }
        let allMax = max(series.flatMap { $0.values }.max() ?? 0, 0.001)
        for s in series where s.values.count > 1 {
            let stepX = bounds.width / CGFloat(s.values.count - 1)
            var points: [CGPoint] = s.values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * stepX,
                        y: bounds.height - (CGFloat(v / allMax) * bounds.height * 0.86 + bounds.height * 0.07))
            }
            // 中点二次贝塞尔平滑
            let line = NSBezierPath()
            line.move(to: points[0])
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2,
                                  y: (points[i].y + points[i + 1].y) / 2)
                line.curve(to: mid, controlPoint1: points[i], controlPoint2: points[i])
            }
            line.line(to: points[points.count - 1])

            if s.filled {
                let fill = line.copy() as! NSBezierPath
                fill.line(to: NSPoint(x: bounds.width, y: bounds.height))
                fill.line(to: NSPoint(x: 0, y: bounds.height))
                fill.close()
                s.color.withAlphaComponent(0.16).setFill()
                fill.fill()
            }
            s.color.setStroke()
            line.lineWidth = lineWidth
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            line.stroke()
        }
    }
}

/// CPU 每核心占用柱状条（圆角、按占用着色）。
final class CoreBarsView: NSView {
    var percents: [Double] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !percents.isEmpty, bounds.width > 10 else { return }
        let gap: CGFloat = 3
        let w = (bounds.width - gap * CGFloat(percents.count - 1)) / CGFloat(percents.count)
        for (i, p) in percents.enumerated() {
            let x = CGFloat(i) * (w + gap)
            let h = max(2.5, CGFloat(p / 100) * bounds.height)
            let rect = NSRect(x: x, y: bounds.height - h, width: w, height: h)
            Palette.usageColor(p).withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// 横向用量进度条（内存/磁盘）。
final class UsageBarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var colors: [NSColor] = [.systemTeal, .systemBlue]

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 4, bounds.height > 2 else { return }
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let f = CGFloat(min(max(fraction, 0), 1))
        guard f > 0.005 else { return }
        let rect = NSRect(x: 0, y: 0, width: max(bounds.height, bounds.width * f), height: bounds.height)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        if let gradient = NSGradient(colors: colors) {
            gradient.draw(in: bounds, angle: 0)
        }
    }
}

// MARK: - 卡片

final class CardView: NSView {
    let content = NSStackView()

    init(title: String, icon: String? = nil, trailing: NSView? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 9
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.spacing = 6
        headerRow.alignment = .centerY

        if let icon {
            let iv = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil)
                ?? NSImage())
            iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            iv.contentTintColor = .secondaryLabelColor
            headerRow.addArrangedSubview(iv)
        }
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .monoDigits(11, .semibold)
        titleField.textColor = .secondaryLabelColor
        headerRow.addArrangedSubview(titleField)
        if let trailing {
            trailing.setContentHuggingPriority(.defaultLow, for: .horizontal)
            headerRow.addArrangedSubview(trailing)
        } else {
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            headerRow.addArrangedSubview(spacer)
        }
        content.addArrangedSubview(headerRow)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addRow(_ view: NSView) {
        content.addArrangedSubview(view)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
        Palette.cardBackground.setFill()
        path.fill()
        Palette.hairline.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private func makeLabel(_ text: String = "—", font: NSFont, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = font
    field.textColor = color
    field.lineBreakMode = .byTruncatingMiddle
    return field
}

private func makeSpacer() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.defaultLow, for: .horizontal)
    v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return v
}

private func makeIcon(_ symbol: String, tint: NSColor, size: CGFloat = 11) -> NSImageView {
    let iv = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    iv.contentTintColor = tint
    return iv
}

// MARK: - 风扇控件

final class FanSlider: NSSlider {
    var dragging = false

    override func mouseDown(with event: NSEvent) {
        dragging = true
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        super.mouseUp(with: event)
    }
}

// MARK: - 主面板

final class DashboardController: NSObject {
    let store: Store
    private(set) var window: NSWindow?

    // CPU
    private var cpuValueLabel: NSTextField!
    private var cpuSubLabel: NSTextField!
    private var coreBars = CoreBarsView()
    private var cpuChart = LineChartView()
    // 内存
    private var memValueLabel: NSTextField!
    private var memSubLabel: NSTextField!
    private var memBar = UsageBarView()
    private var memDetailLabel: NSTextField!
    // 温度
    private var tempValueLabel: NSTextField!
    private var tempSubLabel: NSTextField!
    private var tempDetailLabel: NSTextField!
    private var tempChart = LineChartView()
    // 网络
    private var netDownLabel: NSTextField!
    private var netUpLabel: NSTextField!
    private var netSubLabel: NSTextField!
    private var netChart = LineChartView()
    // 磁盘
    private var diskStack = NSStackView()
    private var diskSignature = ""
    private var diskRows: [String: (bar: UsageBarView, freeLabel: NSTextField)] = [:]
    // 风扇
    private var fanStack = NSStackView()
    private var fanWidgets: [FanWidgets] = []
    private var fanErrorLabel: NSTextField!
    // 底部
    private var footerLabel: NSTextField!

    init(store: Store) {
        self.store = store
        super.init()
    }

    var uiDebugState: String {
        "fanWidgets=\(fanWidgets.count) diskRows=\(diskRows.count)"
    }

    func show() {
        buildWindow()
        update()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 窗口与布局

    private func buildWindow() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Palette.windowBackground.cgColor

        // 布局全部用显式约束（NSStackView 的 alignment=.width 在此场景不生效）：
        // 两行左右钉满窗口宽度、等高均分窗口高度，窗口拉伸时卡片随之缩放、无留白；
        // 行高由窗口唯一决定，内容变化无法改变卡片尺寸。
        let tiles = makeHRow()
        let cpuTile = makeCPUTile()
        let memTile = makeMemoryTile()
        let tempTile = makeTempTile()
        let netTile = makeNetworkTile()
        tiles.addArrangedSubview(cpuTile)
        tiles.addArrangedSubview(memTile)
        tiles.addArrangedSubview(tempTile)
        tiles.addArrangedSubview(netTile)
        equalHeights([cpuTile, memTile, tempTile, netTile])
        root.addSubview(tiles)

        let row2 = makeHRow()
        let diskCard = makeDiskCard()
        let fanCard = makeFanCard()
        row2.addArrangedSubview(diskCard)
        row2.addArrangedSubview(fanCard)
        equalHeights([diskCard, fanCard])
        root.addSubview(row2)

        let footer = makeFooter()
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            tiles.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            tiles.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            tiles.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            row2.topAnchor.constraint(equalTo: tiles.bottomAnchor, constant: 12),
            row2.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            row2.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            footer.topAnchor.constraint(equalTo: row2.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            // 行高均分窗口高度（各设下限防挤压），完全由窗口决定
            tiles.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            row2.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            tiles.heightAnchor.constraint(equalTo: row2.heightAnchor),

            // 每行第一张卡片撑满行高（其余卡片与之等高）
            cpuTile.topAnchor.constraint(equalTo: tiles.topAnchor),
            cpuTile.bottomAnchor.constraint(equalTo: tiles.bottomAnchor),
            diskCard.topAnchor.constraint(equalTo: row2.topAnchor),
            diskCard.bottomAnchor.constraint(equalTo: row2.bottomAnchor),
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Stats"
        w.titlebarAppearsTransparent = false
        w.contentView = root
        w.minSize = NSSize(width: 860, height: 540)
        w.center()
        w.delegate = self
        window = w
    }

    /// 让一组卡片保持等高。
    private func equalHeights(_ views: [NSView]) {
        guard let first = views.first else { return }
        for v in views.dropFirst() {
            v.heightAnchor.constraint(equalTo: first.heightAnchor).isActive = true
        }
    }

    /// 弹性占位：吸收卡片伸展出来的空间，把后续内容压到底部。
    private func makeFlexSpacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    /// 迷你图：最小高度固定、可随窗口伸展。
    private func flexibleChart(_ chart: LineChartView, minHeight: CGFloat) {
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        chart.setContentHuggingPriority(.defaultLow, for: .vertical)
        chart.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func makeHRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setContentHuggingPriority(.required, for: .vertical)
        return row
    }

    /// 指标块通用骨架：数值区 + 副标题。
    private func tileValueStack(value: NSView, sub: NSTextField) -> NSStackView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 0
        v.addArrangedSubview(value)
        v.addArrangedSubview(sub)
        return v
    }

    private func makeCPUTile() -> CardView {
        let card = CardView(title: "CPU", icon: "cpu")
        cpuValueLabel = makeLabel("0%", font: .rounded(30, .bold))
        cpuSubLabel = makeLabel("", font: .monoDigits(10.5), color: .secondaryLabelColor)
        card.addRow(tileValueStack(value: cpuValueLabel, sub: cpuSubLabel))
        card.addRow(makeFlexSpacer())

        coreBars.translatesAutoresizingMaskIntoConstraints = false
        coreBars.heightAnchor.constraint(equalToConstant: 22).isActive = true
        card.addRow(coreBars)
        flexibleChart(cpuChart, minHeight: 26)
        card.addRow(cpuChart)
        return card
    }

    private func makeMemoryTile() -> CardView {
        let card = CardView(title: "内存", icon: "memorychip")
        memValueLabel = makeLabel("0%", font: .rounded(30, .bold))
        memSubLabel = makeLabel("", font: .monoDigits(10.5), color: .secondaryLabelColor)
        card.addRow(tileValueStack(value: memValueLabel, sub: memSubLabel))
        card.addRow(makeFlexSpacer())

        memBar.translatesAutoresizingMaskIntoConstraints = false
        memBar.heightAnchor.constraint(equalToConstant: 7).isActive = true
        card.addRow(memBar)

        memDetailLabel = makeLabel("", font: .monoDigits(10), color: .secondaryLabelColor)
        card.addRow(memDetailLabel)
        return card
    }

    private func makeTempTile() -> CardView {
        let card = CardView(title: "温度", icon: "thermometer.medium")
        tempValueLabel = makeLabel("—", font: .rounded(30, .bold))
        tempSubLabel = makeLabel("正在读取…", font: .monoDigits(10.5), color: .secondaryLabelColor)
        card.addRow(tileValueStack(value: tempValueLabel, sub: tempSubLabel))
        card.addRow(makeFlexSpacer())

        flexibleChart(tempChart, minHeight: 26)
        card.addRow(tempChart)

        tempDetailLabel = makeLabel("", font: .monoDigits(10), color: .secondaryLabelColor)
        card.addRow(tempDetailLabel)
        return card
    }

    private func makeNetworkTile() -> CardView {
        let card = CardView(title: "网络", icon: "arrow.up.arrow.down")
        netDownLabel = makeLabel("↓ —", font: .rounded(30, .bold), color: .controlAccentColor)
        netUpLabel = makeLabel("↑ —", font: .monoDigits(11.5, .medium), color: .systemGreen)
        let values = NSStackView()
        values.orientation = .vertical
        values.alignment = .leading
        values.spacing = 2
        values.addArrangedSubview(netDownLabel)
        values.addArrangedSubview(netUpLabel)
        netSubLabel = makeLabel("", font: .monoDigits(10.5), color: .secondaryLabelColor)
        card.addRow(tileValueStack(value: values, sub: netSubLabel))
        card.addRow(makeFlexSpacer())

        flexibleChart(netChart, minHeight: 30)
        card.addRow(netChart)
        return card
    }

    private func makeDiskCard() -> CardView {
        let card = CardView(title: "磁盘", icon: "internaldrive")
        diskStack.orientation = .vertical
        diskStack.alignment = .width
        diskStack.spacing = 9
        diskStack.translatesAutoresizingMaskIntoConstraints = false
        card.addRow(diskStack)
        return card
    }

    private func makeFanCard() -> CardView {
        let card = CardView(title: "风扇控制", icon: "fan")
        fanStack.orientation = .vertical
        fanStack.alignment = .width
        fanStack.spacing = 10
        fanStack.translatesAutoresizingMaskIntoConstraints = false
        card.addRow(fanStack)

        // 常驻占位行（空字符串也保留高度，避免内容出现/消失导致卡片跳动）
        fanErrorLabel = makeLabel("", font: .monoDigits(10.5), color: .systemOrange)
        card.addRow(fanErrorLabel)

        installRowContainer.heightAnchor.constraint(equalToConstant: 26).isActive = true
        installRowContainer.translatesAutoresizingMaskIntoConstraints = false
        installRowContainer.addSubview(installButton)
        installButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            installButton.centerYAnchor.constraint(equalTo: installRowContainer.centerYAnchor),
            installButton.leadingAnchor.constraint(equalTo: installRowContainer.leadingAnchor),
        ])
        card.addRow(installRowContainer)

        card.addRow(helperMessageLabel)
        card.addRow(makeFlexSpacer())

        let hint = makeLabel("手动模式由特权助手解锁 SMC 并持续保持；“恢复自动”交回系统温控。",
                            font: .monoDigits(10), color: .secondaryLabelColor)
        hint.lineBreakMode = .byTruncatingMiddle
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        card.addRow(hint)
        return card
    }

    /// 安装按钮的常驻容器（按钮隐藏时保留行高）。
    private let installRowContainer: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private func makeFooter() -> NSView {
        footerLabel = makeLabel("", font: .monoDigits(10.5), color: .secondaryLabelColor)
        footerLabel.alignment = .center
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        return footerLabel
    }

    // MARK: 每秒刷新

    func update() {
        guard window != nil, cpuValueLabel != nil else { return }

        // CPU
        cpuValueLabel.stringValue = String(format: "%.1f%%", store.cpuTotal)
        cpuValueLabel.textColor = Palette.usageColor(store.cpuTotal)
        cpuSubLabel.stringValue = "\(store.cpuCores.count) 核 (\(store.system.pCores)P+\(store.system.eCores)E)"
        coreBars.percents = store.cpuCores
        cpuChart.series = [.init(values: store.cpuHistory, color: .systemTeal, filled: true)]

        // 内存
        let memPct = store.memory.total > 0 ? Double(store.memory.used) / Double(store.memory.total) * 100 : 0
        memValueLabel.stringValue = String(format: "%.0f%%", memPct)
        memValueLabel.textColor = Palette.usageColor(memPct)
        memSubLabel.stringValue = "\(formatBytes(store.memory.used)) / \(formatBytes(store.memory.total))"
        memBar.fraction = memPct / 100
        memDetailLabel.stringValue = "联动 \(formatBytes(store.memory.wired)) · 压缩 \(formatBytes(store.memory.compressed))"
            + (store.memory.swapUsed > 0 ? " · 交换 \(formatBytes(store.memory.swapUsed))" : "")

        // 温度：只显示一个最热温度
        if let hottest = store.temps.first {
            tempValueLabel.stringValue = String(format: "%.0f°C", hottest.celsius)
            tempValueLabel.textColor = Palette.tempColor(hottest.celsius)
            tempSubLabel.stringValue = "最热 · \(hottest.label)"
            tempDetailLabel.stringValue = store.smcAvailable ? "SMC \(store.temps.count) 个传感器" : ""
            tempChart.series = [.init(values: store.tempHistory, color: Palette.tempColor(hottest.celsius), filled: true)]
        } else {
            tempValueLabel.stringValue = "—"
            tempValueLabel.textColor = .secondaryLabelColor
            tempSubLabel.stringValue = store.smcAvailable ? "无数据" : "SMC 不可用"
            tempDetailLabel.stringValue = ""
        }

        // 网络
        netDownLabel.stringValue = "↓ \(formatBytesPerSec(store.netDown))"
        netUpLabel.stringValue = "↑ \(formatBytesPerSec(store.netUp))"
        let active = store.interfaces.filter { $0.inBytesPerSec + $0.outBytesPerSec > 1 }.prefix(2)
        netSubLabel.stringValue = active.map { $0.name }.joined(separator: " · ")
        netChart.series = [
            .init(values: store.netDownHistory, color: .controlAccentColor, filled: true),
            .init(values: store.netUpHistory, color: .systemGreen, filled: false),
        ]

        // 磁盘
        updateDiskRows()

        // 风扇
        updateFans()

        // 底部
        footerLabel.stringValue = "\(store.system.chip) · macOS \(store.system.osVersion) · 已运行 \(formatDuration(store.system.uptime))"
    }

    private func updateDiskRows() {
        // 固定卡片高度内最多展示 4 个卷（超出部分不代表在卡片里，避免布局被内容撑开）
        let displayVolumes = Array(store.volumes.prefix(4))
        let signature = displayVolumes.map(\.mountPoint).joined(separator: "|")
        if signature != diskSignature {
            diskSignature = signature
            diskRows.removeAll()
            diskStack.views.forEach {
                diskStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            var usedNames = Set<String>()
            for volume in displayVolumes {
                let displayName = usedNames.contains(volume.name)
                    ? "\(volume.name) (\(volume.mountPoint))"
                    : volume.name
                usedNames.insert(volume.name)

                let row = NSStackView()
                row.orientation = .vertical
                row.alignment = .width
                row.spacing = 3
                row.translatesAutoresizingMaskIntoConstraints = false

                let nameRow = NSStackView()
                nameRow.orientation = .horizontal
                nameRow.spacing = 6
                nameRow.alignment = .firstBaseline
                nameRow.addArrangedSubview(makeLabel(displayName, font: .monoDigits(12, .medium)))
                nameRow.addArrangedSubview(makeSpacer())
                let free = makeLabel("—", font: .monoDigits(10), color: .secondaryLabelColor)
                nameRow.addArrangedSubview(free)

                let bar = UsageBarView()
                bar.colors = [.systemIndigo, .systemPurple]
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.heightAnchor.constraint(equalToConstant: 6).isActive = true

                row.addArrangedSubview(nameRow)
                row.addArrangedSubview(bar)
                diskStack.addArrangedSubview(row)
                diskRows[volume.mountPoint] = (bar, free)
            }
        }
        for volume in displayVolumes {
            guard let widgets = diskRows[volume.mountPoint] else { continue }
            let pct = volume.totalBytes > 0
                ? Double(volume.totalBytes - volume.freeBytes) / Double(volume.totalBytes) : 0
            widgets.bar.fraction = pct
            widgets.freeLabel.stringValue = "可用 \(formatBytes(volume.freeBytes)) / \(formatBytes(volume.totalBytes))"
        }
    }

    private func updateFans() {
        guard store.smcAvailable, !store.fans.isEmpty else {
            rebuildFanRows(nil)
            return
        }
        let controlsUsable = store.helperReady
        let needRebuild = fanWidgets.count != store.fans.count || fanControlsVisible != controlsUsable
        if needRebuild {
            rebuildFanRows(store.fans)
        }
        for (w, fan) in zip(fanWidgets, store.fans) {
            w.rpmLabel.stringValue = String(format: "%.0f", fan.rpm)
            let target = fan.targetRPM ?? fan.minRPM
            if !w.slider.dragging, store.helperReady {
                w.slider.doubleValue = min(max(target, w.slider.minValue), w.slider.maxValue)
            }
            switch fan.mode {
            case 1:
                w.modeLabel.stringValue = "● 手动 · 目标 \(Int(fan.targetRPM ?? 0)) rpm"
                w.modeLabel.textColor = .systemOrange
            case 3:
                w.modeLabel.stringValue = "● 系统温控"
                w.modeLabel.textColor = .secondaryLabelColor
            default:
                w.modeLabel.stringValue = "● 自动 · 基线 \(Int(fan.minRPM)) rpm"
                w.modeLabel.textColor = .systemGreen
            }
        }
        fanErrorLabel.stringValue = store.fanError ?? ""
        updateHelperStatus()
    }

    private var fanControlsVisible = false

    private func updateHelperStatus() {
        installButton.isEnabled = !store.helperInstalling
        if store.helperInstalling {
            installButton.title = "安装中…"
        } else if store.helperReachable {
            installButton.title = "更新风扇助手…"
        } else {
            installButton.title = "启用风扇控制…"
        }
        // ready 后按钮隐藏（安装是罕见状态切换，允许此处变化行高）
        installButton.isHidden = store.helperReady && !store.helperInstalling

        if let msg = store.helperMessage {
            helperMessageLabel.stringValue = msg
        } else if store.helperReady {
            helperMessageLabel.stringValue = ""
        } else if store.helperReachable {
            helperMessageLabel.stringValue = "已安装的风扇助手版本过旧，点“更新风扇助手…”升级（这是最后一次需要密码）"
        } else {
            helperMessageLabel.stringValue = "手动控制需要安装特权助手（Apple Silicon 限制：SMC 写入需 root）"
        }
    }

    private func rebuildFanRows(_ fans: [FanState]?) {
        fanStack.views.forEach {
            fanStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        fanWidgets = []
        fanControlsVisible = store.helperReady
        guard let fans, !fans.isEmpty else {
            fanStack.addArrangedSubview(makeLabel(
                store.smcAvailable ? "未检测到风扇" : "SMC 不可用，无法读取/控制风扇",
                font: .monoDigits(11), color: .secondaryLabelColor))
            return
        }
        for fan in fans {
            fanStack.addArrangedSubview(makeFanRow(fan: fan))
        }
    }

    private lazy var installButton: NSButton = {
        let b = NSButton(title: "启用风扇控制…", target: self, action: #selector(installTapped))
        b.controlSize = .small
        b.bezelStyle = .rounded
        return b
    }()

    private lazy var helperMessageLabel: NSTextField = {
        let f = makeLabel("", font: .monoDigits(10), color: .secondaryLabelColor)
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        return f
    }()

    @objc private func installTapped() {
        store.installFanHelper()
    }

    private func makeFanRow(fan: FanState) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 5
        container.translatesAutoresizingMaskIntoConstraints = false

        let top = NSStackView()
        top.orientation = .horizontal
        top.spacing = 8
        top.alignment = .firstBaseline
        let rpm = makeLabel("—", font: .rounded(28, .bold))
        let rpmUnit = makeLabel("RPM", font: .monoDigits(10.5), color: .secondaryLabelColor)
        let rpmStack = NSStackView()
        rpmStack.orientation = .horizontal
        rpmStack.alignment = .firstBaseline
        rpmStack.spacing = 4
        rpmStack.addArrangedSubview(rpm)
        rpmStack.addArrangedSubview(rpmUnit)
        top.addArrangedSubview(makeLabel("风扇 1", font: .monoDigits(12, .semibold)))
        top.addArrangedSubview(makeSpacer())
        top.addArrangedSubview(rpmStack)

        let mode = makeLabel("", font: .monoDigits(10.5), color: .secondaryLabelColor)
        mode.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let lower = fan.minRPM > 0 ? fan.minRPM : 1000
        let upper = fan.maxRPM > lower ? fan.maxRPM : lower + 1
        let initial = min(max(fan.targetRPM ?? fan.rpm, lower), upper)
        let slider = FanSlider(value: initial, minValue: lower, maxValue: upper,
                               target: nil, action: nil)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.sendAction(on: [.leftMouseUp, .keyUp])
        slider.isEnabled = store.helperReady

        let sliderRow = NSStackView()
        sliderRow.orientation = .horizontal
        sliderRow.spacing = 8
        let minLabel = makeLabel("\(Int(lower))", font: .monoDigits(9.5), color: .secondaryLabelColor)
        let maxLabel = makeLabel("\(Int(upper))", font: .monoDigits(9.5), color: .secondaryLabelColor)
        minLabel.setContentHuggingPriority(.required, for: .horizontal)
        maxLabel.setContentHuggingPriority(.required, for: .horizontal)
        sliderRow.addArrangedSubview(minLabel)
        sliderRow.addArrangedSubview(slider)
        sliderRow.addArrangedSubview(maxLabel)

        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 10
        bottomRow.alignment = .lastBaseline
        bottomRow.addArrangedSubview(mode)
        bottomRow.addArrangedSubview(makeSpacer())
        let auto = NSButton(title: "恢复自动", target: self, action: #selector(autoTapped(_:)))
        auto.controlSize = .small
        auto.identifier = NSUserInterfaceItemIdentifier(String(fan.id))
        auto.isEnabled = store.helperReady
        bottomRow.addArrangedSubview(auto)

        container.addArrangedSubview(top)
        container.addArrangedSubview(sliderRow)
        container.addArrangedSubview(bottomRow)

        let widgets = FanWidgets(fanID: fan.id, rpmLabel: rpm, slider: slider, modeLabel: mode)
        widgets.onApply = { [weak self, weak widgets] value in
            guard let self, let id = widgets?.fanID else { return }
            self.store.applyFanTarget(index: id, rpm: value)
        }
        slider.target = widgets
        slider.action = #selector(FanWidgets.sliderChanged(_:))
        fanWidgets.append(widgets)
        return container
    }

    @objc private func autoTapped(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue, let index = Int(idString) else { return }
        store.setFanAuto(index: index)
    }
}

// MARK: - 风扇控件组

final class FanWidgets: NSObject {
    let fanID: Int
    let rpmLabel: NSTextField
    let slider: FanSlider
    let modeLabel: NSTextField
    var onApply: ((Double) -> Void)?

    init(fanID: Int, rpmLabel: NSTextField, slider: FanSlider, modeLabel: NSTextField) {
        self.fanID = fanID
        self.rpmLabel = rpmLabel
        self.slider = slider
        self.modeLabel = modeLabel
    }

    @objc func sliderChanged(_ sender: FanSlider) {
        onApply?(sender.doubleValue)
    }
}

// MARK: - 窗口代理（关窗仅隐藏）

extension DashboardController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
