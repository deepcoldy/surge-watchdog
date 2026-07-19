import AppKit
import ApplicationServices
import Foundation
import SwiftUI

private enum ProductPaths {
    static let fileManager = FileManager.default
    static let home = fileManager.homeDirectoryForCurrentUser
    static let supportDirectory = home.appendingPathComponent(
        "Library/Application Support/surge-watchdog",
        isDirectory: true
    )
    static let stateDirectory = supportDirectory.appendingPathComponent("state", isDirectory: true)
    static let configURL = supportDirectory.appendingPathComponent("config")
    static let watchdogURL = supportDirectory.appendingPathComponent("bin/surge-watchdog")
    static let requestURL = stateDirectory.appendingPathComponent("ui-request.json")
    static let responseURL = stateDirectory.appendingPathComponent("ui-response.json")
    static let requestLockURL = stateDirectory.appendingPathComponent("ui-request.lock", isDirectory: true)
    static let probeSuccessURL = stateDirectory.appendingPathComponent("ui_probe_success_epoch")
    static let logDirectory = home.appendingPathComponent("Library/Logs/Surge Watchdog", isDirectory: true)
    static let legacyLogURL = home.appendingPathComponent("Library/Logs/surge-watchdog.log")
    static let errorLogURL = home.appendingPathComponent("Library/Logs/surge-watchdog.error.log")
    static let launchAgentURL = home.appendingPathComponent(
        "Library/LaunchAgents/com.shenhan.surge-watchdog.app.plist"
    )
}

private let requestMaxAge: TimeInterval = 90

private struct ProductUIRequest: Codable {
    let requestID: String
    let mode: UIMode
    let createdEpoch: TimeInterval
}

private struct ProductUIResponse: Codable {
    let requestID: String
    let status: String
    let message: String
}

private struct CommandResult {
    let status: Int32
    let output: String
}

enum ProductHealthState {
    case checking
    case healthy
    case unhealthy
    case paused
}

final class WatchdogModel: ObservableObject {
    @Published var healthState: ProductHealthState = .checking
    @Published var healthTitle = "正在检查家庭网关"
    @Published var healthDetail = "正在读取 Surge、Gateway VM 和 DNS 状态…"
    @Published var lastChecked = "尚未检查"
    @Published var gatewayAddress = "自动发现"
    @Published var monitoringEnabled = true
    @Published var launchAtLogin = false
    @Published var uiFallbackEnabled = false
    @Published var accessibilityGranted = false
    @Published var uiProbeReady = false
    @Published var logRetentionDays = 7
    @Published var logText = "暂无监控日志"
    @Published var isBusy = false
    @Published var lastActionMessage = ""

    private var refreshTimer: Timer?
    private var permissionTimer: Timer?

    init() {
        refreshConfiguration()
        refreshPermission()
        refreshLogs()
        refreshStatus()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshConfiguration()
                self?.refreshPermission()
                self?.refreshStatus()
                self?.refreshLogs()
            }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        permissionTimer?.invalidate()
    }

    func refreshConfiguration() {
        let config = readConfiguration()
        monitoringEnabled = config["MONITORING_ENABLED"] != "0"
        uiFallbackEnabled = config["ENABLE_UI_FALLBACK"] == "1"
        if let days = Int(config["LOG_RETENTION_DAYS"] ?? ""), (1...90).contains(days) {
            logRetentionDays = days
        }
        launchAtLogin = config["LAUNCH_AT_LOGIN"] != "0" &&
            ProductPaths.fileManager.fileExists(atPath: ProductPaths.launchAgentURL.path)
        uiProbeReady = ProductPaths.fileManager.fileExists(atPath: ProductPaths.probeSuccessURL.path)
        if !monitoringEnabled && !isBusy {
            healthState = .paused
            healthTitle = "监控已暂停"
        }
    }

    func refreshPermission() {
        let granted = AXIsProcessTrusted()
        if granted && !accessibilityGranted {
            lastActionMessage = "辅助功能权限已生效，可以运行 UI 安全探测。"
        }
        accessibilityGranted = granted
    }

    func requestAccessibilityPermission() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        if let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(settingsURL)
        }
        lastActionMessage = "已打开辅助功能设置；启用 Surge Watchdog 后无需重启应用。"
    }

    func repairAccessibilityPermission() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            lastActionMessage = "无法读取应用标识，不能修复辅助功能授权。"
            return
        }

        // ad-hoc 开发签名更新后，系统设置里可能仍显示旧条目已开启，但新的代码
        // 身份会继续被 TCC 拒绝。只重置本应用的 Accessibility 条目，再由当前
        // 版本重新发起请求；不会影响其他应用的隐私权限。
        try? ProductPaths.fileManager.removeItem(at: ProductPaths.probeSuccessURL)
        uiProbeReady = false
        if uiFallbackEnabled {
            try? updateConfiguration(key: "ENABLE_UI_FALLBACK", value: "0")
            uiFallbackEnabled = false
        }
        lastActionMessage = "正在清理旧的辅助功能授权记录…"
        runCommand(
            executable: URL(fileURLWithPath: "/usr/bin/tccutil"),
            arguments: ["reset", "Accessibility", bundleIdentifier]
        ) { [weak self] result in
            guard let self else { return }
            self.accessibilityGranted = false
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
            if let settingsURL = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(settingsURL)
            }
            self.lastActionMessage = result.status == 0
                ? "旧授权已清理。请在系统设置中开启当前 Surge Watchdog；状态会自动刷新。"
                : "系统未能自动清理旧授权，请在辅助功能列表中移除 Surge Watchdog 后重新添加。"
        }
    }

    func refreshStatus() {
        guard !isBusy else { return }
        isBusy = true
        runWatchdog(arguments: ["--status"]) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            self.lastChecked = Self.displayDateFormatter.string(from: Date())
            let line = Self.lastMeaningfulLine(in: result.output)
            if let address = Self.gatewayAddress(in: result.output) {
                self.gatewayAddress = address
            }
            if !self.monitoringEnabled {
                self.healthState = .paused
                self.healthTitle = "监控已暂停"
                self.healthDetail = result.status == 0
                    ? "当前手动检查正常；开启监控后会自动恢复故障。"
                    : line
            } else if result.status == 0 {
                self.healthState = .healthy
                self.healthTitle = "家庭网关运行正常"
                self.healthDetail = line
            } else {
                self.healthState = .unhealthy
                self.healthTitle = "检测到网关异常"
                self.healthDetail = line.isEmpty ? "健康检查未通过" : line
            }
        }
    }

    func runUIProbe() {
        refreshPermission()
        guard accessibilityGranted else {
            repairAccessibilityPermission()
            return
        }
        guard !isBusy else { return }
        isBusy = true
        lastActionMessage = "正在打开 Surge 并安全探测网关控件…"
        runWatchdog(arguments: ["--ui-probe"]) { [weak self] result in
            guard let self else { return }
            self.isBusy = false
            let line = Self.lastMeaningfulLine(in: result.output)
            self.lastActionMessage = result.status == 0
                ? "UI 安全探测成功：\(line)"
                : "UI 安全探测失败：\(line)"
            self.refreshConfiguration()
            self.refreshStatus()
            self.refreshLogs()
        }
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        do {
            try updateConfiguration(key: "MONITORING_ENABLED", value: enabled ? "1" : "0")
            monitoringEnabled = enabled
            lastActionMessage = enabled ? "监控已开启。" : "监控已暂停；手动检查仍可使用。"
            if enabled {
                runCommand(
                    executable: URL(fileURLWithPath: "/bin/launchctl"),
                    arguments: ["kickstart", "-k", "gui/\(getuid())/com.shenhan.surge-watchdog"]
                ) { _ in }
                refreshStatus()
            } else {
                healthState = .paused
                healthTitle = "监控已暂停"
            }
        } catch {
            lastActionMessage = "保存监控设置失败：\(error.localizedDescription)"
            refreshConfiguration()
        }
    }

    func setUIFallbackEnabled(_ enabled: Bool) {
        if enabled {
            if !accessibilityGranted {
                lastActionMessage = "请先授予辅助功能权限。"
                repairAccessibilityPermission()
                return
            }
            if !uiProbeReady {
                lastActionMessage = "请先在“概览”运行并通过一次 UI 安全探测。"
                return
            }
        }
        do {
            try updateConfiguration(key: "ENABLE_UI_FALLBACK", value: enabled ? "1" : "0")
            uiFallbackEnabled = enabled
            lastActionMessage = enabled
                ? "Surge UI 定向恢复已开启。"
                : "Surge UI 定向恢复已关闭。"
        } catch {
            lastActionMessage = "保存 UI 兜底设置失败：\(error.localizedDescription)"
            refreshConfiguration()
        }
    }

    func setLogRetentionDays(_ days: Int) {
        let safeDays = min(90, max(1, days))
        do {
            try updateConfiguration(key: "LOG_RETENTION_DAYS", value: String(safeDays))
            logRetentionDays = safeDays
            pruneLogs()
            refreshLogs()
            lastActionMessage = "日志将自动保留最近 \(safeDays) 天。"
        } catch {
            lastActionMessage = "保存日志策略失败：\(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try updateConfiguration(key: "LAUNCH_AT_LOGIN", value: enabled ? "1" : "0")
            if enabled {
                try installLoginItemDefinition()
            } else if ProductPaths.fileManager.fileExists(atPath: ProductPaths.launchAgentURL.path) {
                try ProductPaths.fileManager.removeItem(at: ProductPaths.launchAgentURL)
            }
            launchAtLogin = enabled
            lastActionMessage = enabled
                ? "已启用登录后自动在菜单栏运行。"
                : "已关闭登录启动；当前应用会继续运行到退出。"
        } catch {
            lastActionMessage = "修改登录启动设置失败：\(error.localizedDescription)"
            launchAtLogin = ProductPaths.fileManager.fileExists(atPath: ProductPaths.launchAgentURL.path)
        }
    }

    func refreshLogs() {
        pruneLogs()
        var urls: [URL] = []
        if let files = try? ProductPaths.fileManager.contentsOfDirectory(
            at: ProductPaths.logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            urls.append(contentsOf: files.filter { $0.pathExtension == "log" }.sorted { $0.path < $1.path })
        }
        if ProductPaths.fileManager.fileExists(atPath: ProductPaths.legacyLogURL.path) {
            urls.insert(ProductPaths.legacyLogURL, at: 0)
        }
        if ProductPaths.fileManager.fileExists(atPath: ProductPaths.errorLogURL.path) {
            urls.append(ProductPaths.errorLogURL)
        }
        var seen = Set<String>()
        let lines = urls.suffix(8).flatMap { url -> [String] in
            guard let tail = Self.readTail(of: url, maximumBytes: 120_000), !tail.isEmpty else { return [] }
            return tail.components(separatedBy: .newlines)
        }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted(by: >)
        logText = lines.prefix(500).joined(separator: "\n")
        if logText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logText = "暂无监控日志"
        }
    }

    func openLogDirectory() {
        try? ProductPaths.fileManager.createDirectory(
            at: ProductPaths.logDirectory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(ProductPaths.logDirectory)
    }

    func noteUIRequestResult(_ message: String, succeeded: Bool) {
        lastActionMessage = succeeded ? "UI 操作完成：\(message)" : "UI 操作失败：\(message)"
        refreshPermission()
        refreshStatus()
        refreshLogs()
    }

    private func readConfiguration() -> [String: String] {
        guard let text = try? String(contentsOf: ProductPaths.configURL, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
            result[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return result
    }

    private func updateConfiguration(key: String, value: String) throws {
        var lines = (try? String(contentsOf: ProductPaths.configURL, encoding: .utf8))?
            .components(separatedBy: .newlines) ?? []
        if let index = lines.firstIndex(where: { $0.hasPrefix("\(key)=") }) {
            lines[index] = "\(key)=\(value)"
        } else {
            if lines.last == "" { lines.removeLast() }
            lines.append("\(key)=\(value)")
        }
        let output = lines.joined(separator: "\n") + "\n"
        try output.data(using: .utf8)?.write(to: ProductPaths.configURL, options: .atomic)
    }

    private func installLoginItemDefinition() throws {
        let plist: [String: Any] = [
            "Label": "com.shenhan.surge-watchdog.app",
            "ProgramArguments": [
                "/usr/bin/open", "-g", Bundle.main.bundlePath, "--args", "--background"
            ],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try ProductPaths.fileManager.createDirectory(
            at: ProductPaths.launchAgentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: ProductPaths.launchAgentURL, options: .atomic)
        try ProductPaths.fileManager.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: ProductPaths.launchAgentURL.path
        )
    }

    private func pruneLogs() {
        guard let files = try? ProductPaths.fileManager.contentsOfDirectory(
            at: ProductPaths.logDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-TimeInterval(logRetentionDays * 86_400))
        for file in files where file.pathExtension == "log" {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? ProductPaths.fileManager.removeItem(at: file)
        }
    }

    private func runWatchdog(arguments: [String], completion: @escaping (CommandResult) -> Void) {
        var environment = ProcessInfo.processInfo.environment
        environment["SURGE_WATCHDOG_CONFIG"] = ProductPaths.configURL.path
        runCommand(
            executable: ProductPaths.watchdogURL,
            arguments: arguments,
            environment: environment,
            completion: completion
        )
    }

    private func runCommand(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        completion: @escaping (CommandResult) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    completion(CommandResult(status: process.terminationStatus, output: output))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(CommandResult(status: 127, output: error.localizedDescription))
                }
            }
        }
    }

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func lastMeaningfulLine(in text: String) -> String {
        text.components(separatedBy: .newlines)
            .reversed()
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
    }

    private static func gatewayAddress(in text: String) -> String? {
        guard let range = text.range(of: "Gateway VM ") else { return nil }
        let suffix = text[range.upperBound...]
        let address = suffix.prefix { $0.isNumber || $0 == "." }
        return address.isEmpty ? nil : String(address)
    }

    private static func readTail(of url: URL, maximumBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maximumBytes ? size - maximumBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

final class ProductAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusSummaryItem: NSMenuItem!
    private var monitoringMenuItem: NSMenuItem!
    private var permissionMenuItem: NSMenuItem!
    private var windowController: NSWindowController!
    private var model: WatchdogModel!
    private var requestTimer: Timer?
    private var statusTimer: Timer?
    private var requestInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model = WatchdogModel()
        createStatusItem()
        createMainWindow()
        startRequestListener()

        let backgroundLaunch = ProcessInfo.processInfo.arguments.contains("--background")
        let hasPendingRequest = ProductPaths.fileManager.fileExists(atPath: ProductPaths.requestURL.path)
        if !backgroundLaunch && !hasPendingRequest {
            showMainWindow(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        requestTimer?.invalidate()
        statusTimer?.invalidate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(nil)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    @objc private func showMainWindow(_ sender: Any?) {
        model.refreshConfiguration()
        model.refreshPermission()
        model.refreshStatus()
        model.refreshLogs()
        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = menuBarTemplateImage()
            button.toolTip = "Surge Watchdog"
        }

        statusMenu = NSMenu(title: "Surge Watchdog")
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false

        statusSummaryItem = NSMenuItem(title: "正在检查家庭网关…", action: nil, keyEquivalent: "")
        statusSummaryItem.isEnabled = false
        statusMenu.addItem(statusSummaryItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(makeMenuItem("打开 Surge Watchdog", action: #selector(showMainWindow(_:))))
        statusMenu.addItem(makeMenuItem("立即检查", action: #selector(checkNowFromMenu(_:))))

        monitoringMenuItem = makeMenuItem("暂停自动监控", action: #selector(toggleMonitoringFromMenu(_:)))
        statusMenu.addItem(monitoringMenuItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(makeMenuItem("UI 安全探测…", action: #selector(runUIProbeFromMenu(_:))))
        statusMenu.addItem(makeMenuItem("打开监控日志文件夹", action: #selector(openLogsFromMenu(_:))))

        permissionMenuItem = makeMenuItem("辅助功能权限", action: #selector(openPermissionFromMenu(_:)))
        statusMenu.addItem(permissionMenuItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(makeMenuItem(
            "完全退出 Surge Watchdog",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = statusMenu
        updateStatusItem()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateStatusItem()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.contentTintColor = nil
        switch model.healthState {
        case .healthy:
            button.toolTip = "Surge Watchdog：运行正常"
            statusSummaryItem?.title = "● 家庭网关运行正常"
        case .unhealthy:
            button.toolTip = "Surge Watchdog：检测到异常"
            statusSummaryItem?.title = "● 检测到网关异常"
        case .paused:
            button.toolTip = "Surge Watchdog：监控已暂停"
            statusSummaryItem?.title = "● 自动监控已暂停"
        case .checking:
            button.toolTip = "Surge Watchdog：正在检查"
            statusSummaryItem?.title = "● 正在检查家庭网关"
        }
        monitoringMenuItem?.title = model.monitoringEnabled ? "暂停自动监控" : "继续自动监控"
        monitoringMenuItem?.state = model.monitoringEnabled ? .on : .off
        permissionMenuItem?.title = model.accessibilityGranted
            ? "辅助功能权限：已就绪"
            : "修复辅助功能授权…"
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.refreshConfiguration()
        model.refreshPermission()
        updateStatusItem()
    }

    private func makeMenuItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func checkNowFromMenu(_ sender: Any?) {
        model.refreshStatus()
        updateStatusItem()
    }

    @objc private func toggleMonitoringFromMenu(_ sender: Any?) {
        model.setMonitoringEnabled(!model.monitoringEnabled)
        updateStatusItem()
    }

    @objc private func runUIProbeFromMenu(_ sender: Any?) {
        showMainWindow(nil)
        model.runUIProbe()
    }

    @objc private func openLogsFromMenu(_ sender: Any?) {
        model.openLogDirectory()
    }

    @objc private func openPermissionFromMenu(_ sender: Any?) {
        showMainWindow(nil)
        if model.accessibilityGranted {
            model.requestAccessibilityPermission()
        } else {
            model.repairAccessibilityPermission()
        }
    }

    @objc private func quitApplication(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func menuBarTemplateImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let arc = NSBezierPath()
            arc.lineWidth = 1.8
            arc.lineCapStyle = .round
            arc.appendArc(
                withCenter: NSPoint(x: 9, y: 9),
                radius: 6.7,
                startAngle: 48,
                endAngle: 326,
                clockwise: false
            )
            arc.stroke()

            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 14.8, y: 12.3))
            arrow.line(to: NSPoint(x: 16.6, y: 11.8))
            arrow.line(to: NSPoint(x: 15.9, y: 14.2))
            arrow.close()
            arrow.fill()

            let gateway = NSBezierPath(
                roundedRect: NSRect(x: 5.0, y: 7.0, width: 8.0, height: 4.0),
                xRadius: 1.4,
                yRadius: 1.4
            )
            gateway.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Surge Watchdog"
        return image
    }

    private func createMainWindow() {
        let content = ProductDashboardView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Surge Watchdog"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 560)
        window.center()
        window.setFrameAutosaveName("SurgeWatchdogMainWindow")
        window.contentView = NSHostingView(rootView: content)
        window.delegate = self
        windowController = NSWindowController(window: window)
    }

    private func startRequestListener() {
        requestTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.handlePendingRequest()
        }
        handlePendingRequest()
    }

    private func handlePendingRequest() {
        guard !requestInProgress,
              ProductPaths.fileManager.fileExists(atPath: ProductPaths.requestURL.path) else { return }
        requestInProgress = true
        defer {
            try? ProductPaths.fileManager.removeItem(at: ProductPaths.requestLockURL)
            requestInProgress = false
        }

        var requestID = "unknown"
        do {
            let data = try Data(contentsOf: ProductPaths.requestURL)
            try? ProductPaths.fileManager.removeItem(at: ProductPaths.requestURL)
            let request = try JSONDecoder().decode(ProductUIRequest.self, from: data)
            requestID = request.requestID
            let age = abs(Date().timeIntervalSince1970 - request.createdEpoch)
            guard age <= requestMaxAge else {
                throw HelperFailure(message: "拒绝执行已经过期的 UI 请求")
            }
            guard AXIsProcessTrusted() else {
                throw HelperFailure(message: "Surge Watchdog 尚未获得辅助功能权限")
            }

            let result = try SurgeUIController().perform(request.mode)
            try writeResponse(ProductUIResponse(
                requestID: request.requestID,
                status: "ok",
                message: result
            ))
            model.noteUIRequestResult(result, succeeded: true)
        } catch {
            let message = error.localizedDescription
            try? writeResponse(ProductUIResponse(
                requestID: requestID,
                status: "error",
                message: message
            ))
            model.noteUIRequestResult(message, succeeded: false)
        }
    }

    private func writeResponse(_ response: ProductUIResponse) throws {
        try ProductPaths.fileManager.createDirectory(
            at: ProductPaths.stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(response).write(to: ProductPaths.responseURL, options: .atomic)
        try ProductPaths.fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: ProductPaths.responseURL.path
        )
    }
}

private struct ProductDashboardView: View {
    @ObservedObject var model: WatchdogModel
    @State private var selectedSection = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Surge Watchdog")
                        .font(.title2.weight(.semibold))
                    Text("家庭网关守护")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Picker("页面", selection: $selectedSection) {
                Text("概览").tag(0)
                Text("监控日志").tag(1)
                Text("设置").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            Divider()

            Group {
                switch selectedSection {
                case 1: logsView
                case 2: settingsView
                default: overviewView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusColor: Color {
        switch model.healthState {
        case .healthy: return .green
        case .unhealthy: return .red
        case .paused: return .secondary
        case .checking: return .orange
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 7) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text(model.monitoringEnabled ? "监控中" : "已暂停")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var overviewView: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: healthSymbol)
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(statusColor)
                            .frame(width: 48, height: 48)
                            .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.healthTitle).font(.title3.weight(.semibold))
                            Text(model.healthDetail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }
                    HStack(spacing: 10) {
                        Button {
                            model.refreshStatus()
                        } label: {
                            Label("立即检查", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)

                        Button {
                            model.runUIProbe()
                        } label: {
                            Label("UI 安全探测", systemImage: "cursorarrow.click.2")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isBusy)

                        if model.isBusy { ProgressView().controlSize(.small) }
                    }
                }
                .productCard()

                HStack(spacing: 14) {
                    metricCard(
                        title: "Gateway VM",
                        value: model.gatewayAddress,
                        symbol: "network"
                    )
                    metricCard(
                        title: "最近检查",
                        value: model.lastChecked,
                        symbol: "clock"
                    )
                    metricCard(
                        title: "日志保留",
                        value: "\(model.logRetentionDays) 天",
                        symbol: "doc.text"
                    )
                }

                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: Binding(
                        get: { model.monitoringEnabled },
                        set: { model.setMonitoringEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("自动监控与恢复").font(.headline)
                            Text("连续异常达到阈值后，安全重启 Surge 并验证网关是否恢复。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    HStack {
                        Label(
                            model.accessibilityGranted ? "辅助功能权限已就绪" : "需要辅助功能权限",
                            systemImage: model.accessibilityGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(model.accessibilityGranted ? .green : .orange)
                        Spacer()
                        if !model.accessibilityGranted {
                            Button("修复授权…") { model.repairAccessibilityPermission() }
                        }
                    }
                }
                .productCard()

                if !model.lastActionMessage.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                        Text(model.lastActionMessage)
                            .font(.callout)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .productCard()
                }
            }
            .padding(24)
        }
    }

    private var healthSymbol: String {
        switch model.healthState {
        case .healthy: return "checkmark.circle.fill"
        case .unhealthy: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        case .checking: return "ellipsis.circle.fill"
        }
    }

    private func metricCard(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .productCard()
    }

    private var logsView: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("监控日志").font(.title3.weight(.semibold))
                    Text("最新日志显示在最上方；保留最近 500 行，并自动清理过期按日日志。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refreshLogs() } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                Button { model.openLogDirectory() } label: {
                    Label("打开文件夹", systemImage: "folder")
                }
            }

            ScrollView([.vertical, .horizontal]) {
                Text(model.logText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .textColor))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.7)))
        }
        .padding(24)
    }

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsSection(title: "运行") {
                    Toggle("自动监控与恢复", isOn: Binding(
                        get: { model.monitoringEnabled },
                        set: { model.setMonitoringEnabled($0) }
                    ))
                    Toggle("登录后在菜单栏启动", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                }

                settingsSection(title: "故障恢复") {
                    Toggle("启用 Surge UI 定向恢复", isOn: Binding(
                        get: { model.uiFallbackEnabled },
                        set: { model.setUIFallbackEnabled($0) }
                    ))
                    Text("Surge 正在运行时优先尝试“重启服务”；网关模式关闭时才执行受限的重新启用向导。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Label(
                            permissionSummary,
                            systemImage: model.accessibilityGranted && model.uiProbeReady
                                ? "checkmark.circle.fill" : "lock.trianglebadge.exclamationmark"
                        )
                        .foregroundStyle(model.accessibilityGranted && model.uiProbeReady ? .green : .orange)
                        Spacer()
                        Button(model.accessibilityGranted ? "打开系统设置" : "修复授权…") {
                            if model.accessibilityGranted {
                                model.requestAccessibilityPermission()
                            } else {
                                model.repairAccessibilityPermission()
                            }
                        }
                    }
                }

                settingsSection(title: "日志") {
                    HStack {
                        Text("自动清理")
                        Spacer()
                        Stepper(
                            "保留 \(model.logRetentionDays) 天",
                            value: Binding(
                                get: { model.logRetentionDays },
                                set: { model.setLogRetentionDays($0) }
                            ),
                            in: 1...90
                        )
                        .fixedSize()
                    }
                    Text("日志按天保存，过期文件由后台检查器和本应用共同清理。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("完全退出 Surge Watchdog") { NSApp.terminate(nil) }
                }
                .padding(.top, 6)

                Text("关闭主窗口只会把应用收回菜单栏；“完全退出”会结束菜单栏进程，后台监控开关保持原设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !model.lastActionMessage.isEmpty {
                    Text(model.lastActionMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .productCard()
    }

    private var permissionSummary: String {
        if !model.accessibilityGranted { return "辅助功能权限未授权" }
        return model.uiProbeReady ? "辅助功能与 UI 探测均已就绪" : "已授权，尚未通过 UI 安全探测"
    }
}

private extension View {
    func productCard() -> some View {
        self
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
    }
}
