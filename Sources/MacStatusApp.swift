//
//  MacStatusApp.swift
//  MacStatus
//
//  菜单栏状态监控：CPU 温度 / 风扇转速 / 内存 / CPU 占用。
//

import SwiftUI
import AppKit

/// 菜单栏显示模式
enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case temperature   // 62°
    case memory        // 内存占用百分比 60%
    case cpu           // CPU 使用百分比 12%
    case iconOnly      // 仅图标，不显示数据

    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: return "温度"
        case .memory: return "内存"
        case .cpu: return "CPU"
        case .iconOnly: return "图标"
        }
    }

    static var storageKey: String { "menuBarDisplay" }

    static var current: MenuBarDisplay {
        MenuBarDisplay(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .temperature
    }
}

@main
struct MacStatusApp {
    private static var delegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        self.delegate = delegate  // 保住生命周期
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// 用 NSStatusItem + NSPopover 实现：MenuBarExtra 的自定义图标 label 在
/// macOS 26/27 上渲染不出图片（文字正常），直接走 AppKit 行为完全可控。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var updateTimer: Timer?

    /// 菜单栏模板图标（黑+alpha，系统按菜单栏明暗自动反色）
    private static let menuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "menubar-icon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        statusItem = item

        popover.behavior = .transient  // 点击面板外自动关闭
        popover.animates = false
        let hosting = NSHostingController(rootView: PanelView(monitor: monitor))
        // 让弹窗尺寸跟随 SwiftUI 内容实际大小，否则默认 contentSize 会把面板顶部截掉
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        hosting.view.layoutSubtreeIfNeeded()
        popover.contentSize = NSSize(width: 320, height: max(hosting.view.fittingSize.height, 200))

        updateMenuBarContent()

        // 调试用：MACSTATUS_DEBUG_SHOW=1 启动后 3 秒自动弹出面板（免点击验证布局）
        if ProcessInfo.processInfo.environment["MACSTATUS_DEBUG_SHOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.showPopover()
            }
        }

        // 菜单栏数值每秒刷新（monitor 本身 2 秒采样一次）
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMenuBarContent()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer

        // 面板里切换显示模式时立即更新菜单栏
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateMenuBarContent()
            }
        }
    }

    /// 按当前模式刷新菜单栏内容（文字或图标）
    private func updateMenuBarContent() {
        guard let button = statusItem?.button else { return }
        switch MenuBarDisplay.current {
        case .iconOnly:
            button.image = Self.menuBarIcon
            button.title = ""
            button.image?.size = NSSize(width: 18, height: 15.25)
        case .temperature:
            button.image = nil
            if monitor.smcOK, let temp = monitor.cpuTemp {
                button.title = "\(Int(temp.rounded()))°"
            } else {
                button.title = "--°"
            }
        case .memory:
            button.image = nil
            if monitor.memTotal > 0 {
                let percent = Int((Double(monitor.memUsed) / Double(monitor.memTotal) * 100).rounded())
                button.title = "\(percent)%"
            } else {
                button.title = "--%"
            }
        case .cpu:
            button.image = nil
            button.title = "\(Int(monitor.cpuUsage.rounded()))%"
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

struct PanelView: View {
    @ObservedObject var monitor: Monitor
    @AppStorage(MenuBarDisplay.storageKey) private var displayModeRaw = MenuBarDisplay.temperature.rawValue

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func tempColor(_ t: Double) -> Color {
        if t >= 85 { return .red }
        if t >= 70 { return .orange }
        return .primary
    }

    private static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            cpuSection
            memorySection
            fanSection
            tempList
            appMemSection
            displayModeSection
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.open.with.lines.needle.84percent")
                .foregroundStyle(.blue)
            Text("Mac 状态监控")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !monitor.smcOK {
                Text("SMC 不可用")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("CPU", systemImage: "cpu")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(String(format: "%.0f%%", monitor.cpuUsage))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                if let temp = monitor.cpuTemp {
                    Text(String(format: "%.1f°C", temp))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tempColor(temp))
                }
            }
            ProgressView(value: monitor.cpuUsage, total: 100)
                .progressViewStyle(.linear)
                .tint(.blue)
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("内存", systemImage: "memorychip")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Self.gb(monitor.memUsed)) / \(Self.gb(monitor.memTotal))")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
            ProgressView(
                value: monitor.memTotal > 0
                    ? Double(monitor.memUsed) / Double(monitor.memTotal) * 100
                    : 0,
                total: 100
            )
            .progressViewStyle(.linear)
            .tint(.green)
        }
    }

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("风扇", systemImage: "fan.blades")
                .font(.system(size: 12, weight: .medium))
            if monitor.fans.isEmpty {
                Text(monitor.smcOK ? "未检测到风扇" : "--")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(monitor.fans) { fan in
                    HStack {
                        Text(fan.id == 0 ? "风扇 0" : "风扇 \(fan.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if fan.rpm < 1 {
                            Text("停转")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(String(format: "%.0f RPM", fan.rpm))
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            }
        }
    }

    private var appMemSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("内存占用 Top 5", systemImage: "square.stack.3d.up")
                .font(.system(size: 12, weight: .medium))
            ForEach(monitor.topApps) { app in
                HStack {
                    Text(app.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(Self.gb(app.bytes))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var tempList: some View {
        if !monitor.topTemps.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label("传感器温度（最高 4 项）", systemImage: "thermometer.medium")
                    .font(.system(size: 12, weight: .medium))
                ForEach(monitor.topTemps) { reading in
                    HStack {
                        Text(reading.name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if !reading.category.isEmpty {
                            Text(reading.category)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.blue.opacity(0.12)))
                                .foregroundStyle(.blue)
                        }
                        Spacer()
                        Text(String(format: "%.1f°C", reading.value))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tempColor(reading.value))
                    }
                }
            }
        }
    }

    private var displayModeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("菜单栏显示", systemImage: "menubar.dock.rectangle")
                .font(.system(size: 12, weight: .medium))
            Picker("菜单栏显示", selection: $displayModeRaw) {
                ForEach(MenuBarDisplay.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var footer: some View {
        HStack {
            Text("更新于 " + timeFormatter.string(from: monitor.lastUpdate))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("退出") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}
