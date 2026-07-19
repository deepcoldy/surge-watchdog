import AppKit
import ApplicationServices
import Foundation

private let surgeBundleIdentifier = "com.nssurge.surge-mac"
enum UIMode: String, Codable {
    case probe
    case recover
}

struct HelperFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class SurgeUIController {
    private let devicesNames = ["设备", "Devices"]
    private let gatewayNames = ["网关模式", "Gateway Mode"]
    private let restartNames = ["重启服务", "Restart Service"]
    private let nextNames = ["下一步", "Next"]
    private let finishNames = ["完成", "Finish", "Done"]
    private let confirmationNames = ["好", "OK"]
    private let ethernetNames = ["Ethernet", "以太网"]
    private let dhcpToggleNames = [
        "启用 Surge IPv4 DHCP 服务器",
        "Enable Surge IPv4 DHCP Server"
    ]
    private let safeDismissNames = ["稍后", "Later", "Not Now", "以后", "取消", "Cancel", "关闭", "Close", "跳过", "Skip"]
    private var targetProcessIdentifier: pid_t?

    func perform(_ mode: UIMode) throws -> String {
        let surge = try waitForRunningSurge(timeout: 8)
        targetProcessIdentifier = surge.processIdentifier

        surge.unhide()
        surge.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 1)

        let application = AXUIElementCreateApplication(surge.processIdentifier)
        guard let window = waitForMainWindow(in: application, timeout: 8) else {
            throw HelperFailure(message: "无法自动打开 Surge 主窗口；请确认当前用户处于已解锁的图形登录会话")
        }
        try raise(window, description: "Surge 主窗口")
        try dismissSafeBlockingUI(in: application, mainWindow: window)

        guard let devicesControl = findNavigationElement(in: window, names: devicesNames) else {
            throw HelperFailure(message: "无法找到 Surge 的“设备”导航控件")
        }
        let devicesDebug = debugDescription(of: devicesControl)
        try press(devicesControl, description: "“设备”导航")
        if waitForGatewayControl(in: window, timeout: 1.2) == nil {
            try clickNavigationFallback(in: window, named: devicesNames, description: "“设备”导航")
        }

        guard let gatewayControl = waitForGatewayControl(in: window, timeout: 3) else {
            throw HelperFailure(message: "已尝试切换到“设备”，但仍无法找到“网关模式”开关。设备控件：\(devicesDebug)")
        }
        let gatewayIsOn = try controlIsOn(gatewayControl)

        if mode == .recover && !gatewayIsOn {
            return try enableGatewayMode(
                in: application,
                mainWindow: window,
                gatewayControl: gatewayControl
            )
        }

        guard let settingsControl = findGatewaySettingsControl(in: window, gatewayControl: gatewayControl),
              let settingsPoint = center(of: settingsControl) else {
            throw HelperFailure(message: "无法找到网关模式设置按钮")
        }
        // Surge 的齿轮按钮通过 AXPress 打开菜单时会使用错误锚点，菜单可能跑到
        // 屏幕左下角。这里必须在齿轮的真实屏幕坐标发送系统鼠标点击。
        try click(at: settingsPoint, description: "网关模式设置按钮")
        Thread.sleep(forTimeInterval: 0.6)

        guard let restartControl = waitForNamedElement(
            in: application,
            names: restartNames,
            timeout: 2
        ) else {
            pressEscape()
            throw HelperFailure(message: "无法在网关模式菜单中找到“重启服务”")
        }

        if mode == .probe {
            pressEscape()
            return "gateway_mode=\(gatewayIsOn ? "on" : "off"); restart_service=found"
        }

        try press(restartControl, description: "“重启服务”菜单项")
        return "已请求重启 Surge 网关服务"
    }

    private func enableGatewayMode(
        in application: AXUIElement,
        mainWindow: AXUIElement,
        gatewayControl: AXUIElement
    ) throws -> String {
        guard let gatewayPoint = center(of: gatewayControl) else {
            throw HelperFailure(message: "无法读取网关模式开关的屏幕位置")
        }

        // 网关模式关闭后，Surge 可能展示一套首次启用向导。使用真实点击打开向导，
        // 然后只操作明确允许的按钮和 IPv4 DHCP 开关，不修改任何地址字段。
        try click(at: gatewayPoint, description: "“网关模式”开关")

        let deadline = Date().addingTimeInterval(75)
        var nextPressCount = 0
        var dhcpEnableRequested = false
        var dhcpReady = false
        var finishPressed = false
        var lastStep = "等待 Surge 打开启用向导"

        while Date() < deadline {
            if let currentGateway = findGatewayControl(in: mainWindow),
               (try? controlIsOn(currentGateway)) == true {
                return "已通过 Surge 向导重新启用网关模式和 IPv4 DHCP"
            }

            if let confirmation = findEnabledNamedElement(
                in: application,
                names: confirmationNames
            ) {
                lastStep = "确认 Surge 的网关模式注意事项"
                try press(confirmation, description: "网关模式注意事项确认按钮")
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }

            if containsNameFragment(
                in: application,
                fragments: ["载入中", "Loading", "检测现有 DHCP", "Detecting existing DHCP"]
            ) {
                lastStep = "等待 Surge 完成网络环境检测或配置载入"
                Thread.sleep(forTimeInterval: 0.35)
                continue
            }

            if let dhcpSwitch = findSwitchNearLabel(in: application, names: dhcpToggleNames) {
                let dhcpIsOn = (try? controlIsOn(dhcpSwitch)) == true
                if dhcpIsOn {
                    dhcpReady = true
                    lastStep = "IPv4 DHCP 已启用"
                } else if !dhcpEnableRequested {
                    guard let dhcpPoint = center(of: dhcpSwitch) else {
                        throw HelperFailure(message: "无法读取 Surge IPv4 DHCP 开关位置")
                    }
                    lastStep = "启用 Surge IPv4 DHCP 服务器"
                    try click(at: dhcpPoint, description: "Surge IPv4 DHCP 开关")
                    dhcpEnableRequested = true
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                } else {
                    lastStep = "等待 Surge 完成 IPv4 DHCP 配置"
                }

                if dhcpReady,
                   let finish = findEnabledNamedElement(in: application, names: finishNames) {
                    lastStep = "完成网关模式配置"
                    try press(finish, description: "网关模式“完成”按钮")
                    finishPressed = true
                    Thread.sleep(forTimeInterval: 0.8)
                    continue
                }
            }

            if !finishPressed,
               let next = findEnabledNamedElement(in: application, names: nextNames) {
                if nextPressCount >= 1 && !containsNamedElement(in: application, names: ethernetNames) {
                    throw HelperFailure(
                        message: "网关模式向导没有选择 Ethernet 接口；为避免接管错误网卡，已停止自动操作"
                    )
                }
                lastStep = nextPressCount == 0
                    ? "阅读网关模式介绍"
                    : "确认使用 Ethernet 网络接口"
                try press(next, description: "网关模式“下一步”按钮")
                nextPressCount += 1
                Thread.sleep(forTimeInterval: 0.7)
                continue
            }

            Thread.sleep(forTimeInterval: 0.25)
        }

        throw HelperFailure(message: "重新启用网关模式超时；最后步骤：\(lastStep)")
    }

    private func waitForRunningSurge(timeout: TimeInterval) throws -> NSRunningApplication {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: surgeBundleIdentifier
            ).first {
                return running
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        throw HelperFailure(message: "8 秒内未发现 Surge 进程；请通过 watchdog 的 --ui-probe 启动探测")
    }

    private func waitForMainWindow(in application: AXUIElement, timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] {
                let standardWindows = windows.filter {
                    stringAttribute($0, kAXSubroleAttribute) == "AXStandardWindow"
                }
                let semanticWindows = standardWindows.filter {
                    findNamedElement(in: $0, names: devicesNames) != nil
                }
                let candidates = semanticWindows.isEmpty
                    ? (standardWindows.isEmpty ? windows : standardWindows)
                    : semanticWindows
                if let mainWindow = largestWindow(in: candidates) {
                    if boolAttribute(mainWindow, kAXMinimizedAttribute) == true {
                        _ = AXUIElementSetAttributeValue(
                            mainWindow,
                            kAXMinimizedAttribute as CFString,
                            kCFBooleanFalse
                        )
                    }
                    return mainWindow
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    private func largestWindow(in windows: [AXUIElement]) -> AXUIElement? {
        windows.compactMap { window -> (AXUIElement, CGFloat)? in
            guard let windowSize = size(of: window), windowSize.width >= 400, windowSize.height >= 300 else {
                return nil
            }
            return (window, windowSize.width * windowSize.height)
        }.max(by: { $0.1 < $1.1 })?.0
    }

    private func waitForGatewayControl(in root: AXUIElement, timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let control = findGatewayControl(in: root) { return control }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    private func dismissSafeBlockingUI(in application: AXUIElement, mainWindow: AXUIElement) throws {
        for _ in 0..<4 {
            var blockers = allElements(in: mainWindow).filter { role(of: $0) == "AXSheet" }
            if let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] {
                blockers.append(contentsOf: windows.filter {
                    CFEqual($0, mainWindow) == false && boolAttribute($0, kAXModalAttribute) == true
                })
            }
            if blockers.isEmpty { return }

            for blocker in blockers {
                if let closeButton = attribute(blocker, kAXCloseButtonAttribute),
                   CFGetTypeID(closeButton) == AXUIElementGetTypeID() {
                    let closeElement = unsafeBitCast(closeButton, to: AXUIElement.self)
                    try press(closeElement, description: "弹窗关闭按钮")
                    Thread.sleep(forTimeInterval: 0.3)
                    continue
                }
                if let safeButton = findNamedElement(in: blocker, names: safeDismissNames) {
                    try press(safeButton, description: "弹窗安全关闭按钮")
                    Thread.sleep(forTimeInterval: 0.3)
                    continue
                }

                let popupName = name(of: blocker)
                let displayName = popupName.isEmpty ? "无标题弹窗" : popupName
                throw HelperFailure(message: "Surge 存在未识别的模态弹窗“\(displayName)”；为避免误操作，Helper 未自动确认")
            }
        }
        throw HelperFailure(message: "Surge 的模态弹窗未能安全关闭")
    }

    private func waitForNamedElement(
        in root: AXUIElement,
        names: [String],
        timeout: TimeInterval
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = findNamedElement(in: root, names: names) { return element }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return nil
    }

    private func findEnabledNamedElement(in root: AXUIElement, names: [String]) -> AXUIElement? {
        guard let element = findNamedElement(in: root, names: names),
              boolAttribute(element, kAXEnabledAttribute) != false else { return nil }
        return element
    }

    private func containsNamedElement(in root: AXUIElement, names: [String]) -> Bool {
        allElements(in: root).contains { names.contains(name(of: $0)) }
    }

    private func containsNameFragment(in root: AXUIElement, fragments: [String]) -> Bool {
        allElements(in: root).contains { element in
            let elementName = name(of: element)
            return fragments.contains { elementName.localizedCaseInsensitiveContains($0) }
        }
    }

    private func findNamedElement(in root: AXUIElement, names: [String]) -> AXUIElement? {
        var fallback: AXUIElement?
        for element in allElements(in: root) where names.contains(name(of: element)) {
            if actionNames(of: element).contains(kAXPressAction) { return element }
            if let ancestor = pressableAncestor(of: element) { return ancestor }
            if fallback == nil || (isPressable(element) && !isPressable(fallback!)) {
                fallback = element
            }
        }
        return fallback
    }

    private func findNavigationElement(in root: AXUIElement, names: [String]) -> AXUIElement? {
        let matches = navigationLabels(in: root, names: names)
        for element in matches {
            if actionNames(of: element).contains(kAXPressAction) { return element }
            if let ancestor = pressableAncestor(of: element) { return ancestor }
        }
        for element in matches {
            if let row = bestRowContainer(of: element) { return row }
        }
        return matches.first
    }

    private func navigationLabels(in root: AXUIElement, names: [String]) -> [AXUIElement] {
        guard let rootFrame = frame(of: root) else { return [] }
        // Surge 的概览卡片也包含“设备”字样。导航栏固定在主窗口最左侧，
        // 因此只接受左侧 30%（最多 480 点）内的同名标签。
        let navigationMaxX = rootFrame.minX + min(480, rootFrame.width * 0.30)
        return allElements(in: root).filter { element in
            guard names.contains(name(of: element)), let elementCenter = center(of: element) else {
                return false
            }
            return elementCenter.x >= rootFrame.minX && elementCenter.x <= navigationMaxX
        }.sorted {
            (position(of: $0)?.x ?? .greatestFiniteMagnitude) <
                (position(of: $1)?.x ?? .greatestFiniteMagnitude)
        }
    }

    private func bestRowContainer(of label: AXUIElement) -> AXUIElement? {
        guard let labelFrame = frame(of: label), let labelCenter = center(of: label) else { return nil }
        var current = label
        var candidates: [(AXUIElement, CGFloat)] = []

        for _ in 0..<14 {
            guard let parentValue = attribute(current, kAXParentAttribute),
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }
            let parent = unsafeBitCast(parentValue, to: AXUIElement.self)
            if let parentFrame = frame(of: parent),
               parentFrame.contains(labelCenter),
               parentFrame.height >= max(20, labelFrame.height),
               parentFrame.height <= 120,
               parentFrame.width >= labelFrame.width + 24,
               parentFrame.width <= 520 {
                // SwiftUI 的侧栏行经常是没有 AXPress 的 AXGroup。优先选覆盖整行、
                // 但不会扩展到整个侧栏列表的容器。
                let score = parentFrame.width + parentFrame.height * 0.25
                candidates.append((parent, score))
            }
            current = parent
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    private func clickNavigationFallback(
        in root: AXUIElement,
        named names: [String],
        description: String
    ) throws {
        guard let label = navigationLabels(in: root, names: names).first,
              let labelFrame = frame(of: label) else {
            throw HelperFailure(message: "无法读取\(description)文字的屏幕位置")
        }

        var points: [CGPoint] = []
        if let row = bestRowContainer(of: label), let rowCenter = center(of: row) {
            points.append(rowCenter)
        }
        // Surge 的 SwiftUI 侧栏可能只在图标/整行手势区域接收点击。图标通常位于
        // 标签左侧约 34 点；最后再尝试文字中心，均属于同一条“设备”导航行。
        points.append(CGPoint(x: max(1, labelFrame.minX - 34), y: labelFrame.midY))
        points.append(CGPoint(x: labelFrame.midX, y: labelFrame.midY))

        var attempted: [String] = []
        for point in points {
            let key = "\(Int(point.x)),\(Int(point.y))"
            guard !attempted.contains(key) else { continue }
            attempted.append(key)
            try click(at: point, description: description)
            if waitForGatewayControl(in: root, timeout: 1.2) != nil { return }
        }
    }

    private func findGatewayControl(in root: AXUIElement) -> AXUIElement? {
        let elements = allElements(in: root)
        var gatewayLabel: AXUIElement?
        var switches: [AXUIElement] = []

        for element in elements {
            if isSwitch(element) {
                if gatewayNames.contains(name(of: element)) { return element }
                switches.append(element)
            }
            if gatewayLabel == nil && gatewayNames.contains(name(of: element)) {
                gatewayLabel = element
            }
        }

        guard let label = gatewayLabel, let labelCenter = center(of: label) else { return nil }
        return switches.compactMap { element -> (AXUIElement, CGFloat)? in
            guard let switchCenter = center(of: element) else { return nil }
            let horizontal = switchCenter.x - labelCenter.x
            let vertical = abs(switchCenter.y - labelCenter.y)
            guard horizontal > -40, horizontal < 500, vertical < 90 else { return nil }
            return (element, horizontal + vertical * 3)
        }.min(by: { $0.1 < $1.1 })?.0
    }

    private func findSwitchNearLabel(in root: AXUIElement, names: [String]) -> AXUIElement? {
        let elements = allElements(in: root)
        if let namedSwitch = elements.first(where: { isSwitch($0) && names.contains(name(of: $0)) }) {
            return namedSwitch
        }
        guard let label = elements.first(where: { names.contains(name(of: $0)) }),
              let labelCenter = center(of: label) else { return nil }
        return elements.compactMap { element -> (AXUIElement, CGFloat)? in
            guard isSwitch(element), let switchCenter = center(of: element) else { return nil }
            let horizontal = abs(switchCenter.x - labelCenter.x)
            let vertical = abs(switchCenter.y - labelCenter.y)
            guard horizontal < 650, vertical < 90 else { return nil }
            return (element, horizontal + vertical * 4)
        }.min(by: { $0.1 < $1.1 })?.0
    }

    private func findGatewaySettingsControl(
        in root: AXUIElement,
        gatewayControl: AXUIElement
    ) -> AXUIElement? {
        guard let gatewayCenter = center(of: gatewayControl) else { return nil }
        return allElements(in: root).compactMap { element -> (AXUIElement, CGFloat)? in
            guard role(of: element) == kAXButtonRole as String,
                  let buttonCenter = center(of: element) else { return nil }
            let horizontal = buttonCenter.x - gatewayCenter.x
            let vertical = abs(buttonCenter.y - gatewayCenter.y)
            guard horizontal > 20, horizontal < 700, vertical < 100 else { return nil }
            return (element, horizontal + vertical * 4)
        }.min(by: { $0.1 < $1.1 })?.0
    }

    private func allElements(in root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0

        while index < queue.count && result.count < 5000 {
            let (element, depth) = queue[index]
            index += 1
            result.append(element)
            guard depth < 16,
                  let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return result
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func stringAttribute(_ element: AXUIElement, _ attributeName: String) -> String {
        attribute(element, attributeName) as? String ?? ""
    }

    private func role(of element: AXUIElement) -> String {
        stringAttribute(element, kAXRoleAttribute)
    }

    private func name(of element: AXUIElement) -> String {
        for attributeName in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute] {
            let value = stringAttribute(element, attributeName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return ""
    }

    private func isSwitch(_ element: AXUIElement) -> Bool {
        let elementRole = role(of: element)
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        return elementRole == kAXCheckBoxRole as String ||
            elementRole == "AXSwitch" || subrole == "AXSwitch"
    }

    private func isPressable(_ element: AXUIElement) -> Bool {
        [kAXButtonRole as String, kAXRadioButtonRole as String,
         kAXCheckBoxRole as String, kAXMenuItemRole as String].contains(role(of: element))
    }

    private func pressableAncestor(of element: AXUIElement) -> AXUIElement? {
        var current = element
        var roleFallback: AXUIElement?
        for _ in 0..<14 {
            guard let parentValue = attribute(current, kAXParentAttribute),
                  CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { return nil }
            let parent = unsafeBitCast(parentValue, to: AXUIElement.self)
            if actionNames(of: parent).contains(kAXPressAction) { return parent }
            if roleFallback == nil && isPressable(parent) { roleFallback = parent }
            current = parent
        }
        return roleFallback
    }

    private func raise(_ element: AXUIElement, description: String) throws {
        guard actionNames(of: element).contains(kAXRaiseAction) else { return }
        let result = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard result == .success else {
            throw HelperFailure(message: "无法置前\(description)（AXError \(result.rawValue)）")
        }
    }

    private func press(_ element: AXUIElement, description: String) throws {
        if boolAttribute(element, kAXEnabledAttribute) == false {
            throw HelperFailure(message: "\(description)当前不可用")
        }

        if actionNames(of: element).contains(kAXPressAction) {
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if result == .success { return }
            if result != .actionUnsupported {
                throw HelperFailure(message: "点击\(description)失败（AXError \(result.rawValue)）")
            }
        }

        var selectedIsSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            element,
            kAXSelectedAttribute as CFString,
            &selectedIsSettable
        ) == .success, selectedIsSettable.boolValue,
           AXUIElementSetAttributeValue(
               element,
               kAXSelectedAttribute as CFString,
               kCFBooleanTrue
           ) == .success {
            return
        }

        guard let clickPoint = center(of: element) else {
            throw HelperFailure(message: "\(description)不支持 AXPress，且无法读取其屏幕位置")
        }
        try click(at: clickPoint, description: description)
    }

    private func click(at clickPoint: CGPoint, description: String) throws {
        guard let processIdentifier = targetProcessIdentifier else {
            throw HelperFailure(message: "无法确定 Surge 进程，未执行\(description)点击")
        }
        guard let surge = NSRunningApplication(processIdentifier: processIdentifier) else {
            throw HelperFailure(message: "Surge 进程已经退出，未执行\(description)点击")
        }
        surge.unhide()
        surge.activate(options: [.activateAllWindows])
        let frontmostDeadline = Date().addingTimeInterval(1.5)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != processIdentifier,
              Date() < frontmostDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            let frontmostName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知应用"
            throw HelperFailure(message: "无法将 Surge 置于最前方（当前前台：\(frontmostName)），未执行\(description)点击")
        }
        let originalPosition = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(clickPoint)
        Thread.sleep(forTimeInterval: 0.08)
        let eventSource = CGEventSource(stateID: .hidSystemState)
        guard let mouseDown = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        ), let mouseUp = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: clickPoint,
            mouseButton: .left
        ) else {
            throw HelperFailure(message: "无法为\(description)创建安全点击事件")
        }
        mouseDown.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseUp.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)
        mouseUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.12)
        if let originalPosition { CGWarpMouseCursorPosition(originalPosition) }
    }

    private func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func debugDescription(of element: AXUIElement) -> String {
        let elementRole = role(of: element)
        let elementSubrole = stringAttribute(element, kAXSubroleAttribute)
        let actions = actionNames(of: element).joined(separator: "/")
        let geometry: String
        if let elementFrame = frame(of: element) {
            geometry = "x=\(Int(elementFrame.minX)), y=\(Int(elementFrame.minY)), w=\(Int(elementFrame.width)), h=\(Int(elementFrame.height))"
        } else {
            geometry = "frame=-"
        }
        return "role=\(elementRole), subrole=\(elementSubrole.isEmpty ? "-" : elementSubrole), actions=\(actions.isEmpty ? "-" : actions), \(geometry)"
    }

    private func boolAttribute(_ element: AXUIElement, _ attributeName: String) -> Bool? {
        (attribute(element, attributeName) as? NSNumber)?.boolValue
    }

    private func controlIsOn(_ element: AXUIElement) throws -> Bool {
        guard let value = attribute(element, kAXValueAttribute) else {
            throw HelperFailure(message: "无法读取网关模式开关状态")
        }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            return ["1", "true", "on"].contains(text.lowercased())
        }
        throw HelperFailure(message: "网关模式开关返回了未知状态")
    }

    private func center(of element: AXUIElement) -> CGPoint? {
        guard let elementPosition = position(of: element),
              let elementSize = size(of: element) else { return nil }
        return CGPoint(
            x: elementPosition.x + elementSize.width / 2,
            y: elementPosition.y + elementSize.height / 2
        )
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let elementPosition = position(of: element),
              let elementSize = size(of: element) else { return nil }
        return CGRect(origin: elementPosition, size: elementSize)
    }

    private func position(of element: AXUIElement) -> CGPoint? {
        guard let value = attribute(element, kAXPositionAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private func size(of element: AXUIElement) -> CGSize? {
        guard let value = attribute(element, kAXSizeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var elementSize = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &elementSize) ? elementSize : nil
    }

    private func pressEscape() {
        let keyCode: CGKeyCode = 53
        CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

private let application = NSApplication.shared
private let delegate = ProductAppDelegate()
application.delegate = delegate
application.run()
