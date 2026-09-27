import Foundation

/// Installs only this user's watchdog files. The app's signed resources are the
/// payload; no download, compiler, administrator access, or Surge changes occur.
enum RuntimeInstaller {
    static let label = "com.shenhan.surge-watchdog"

    static func install(
        resources: URL,
        home: URL,
        appURL: URL,
        version: String,
        activate: (URL) throws -> Void
    ) throws {
        let fm = FileManager.default
        let support = home.appendingPathComponent("Library/Application Support/surge-watchdog")
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        let logs = home.appendingPathComponent("Library/Logs/Surge Watchdog")
        let configURL = support.appendingPathComponent("config")
        let binaryURL = support.appendingPathComponent("bin/surge-watchdog")
        let agentURL = agents.appendingPathComponent("\(label).plist")
        let loginURL = agents.appendingPathComponent("\(label).app.plist")
        let revisionURL = support.appendingPathComponent("runtime-version")
        let probeURL = support.appendingPathComponent("state/ui_probe_success_epoch")
        let payload = resources.appendingPathComponent("Runtime")
        let defaults = try String(contentsOf: payload.appendingPathComponent("config.example"), encoding: .utf8)
        let oldConfig = try? String(contentsOf: configURL, encoding: .utf8)
        var lines = (oldConfig ?? defaults).components(separatedBy: .newlines)
        func set(_ key: String, _ value: String, onlyIfMissing: Bool = false) {
            if let index = lines.firstIndex(where: { $0.hasPrefix(key + "=") }) {
                if !onlyIfMissing { lines[index] = "\(key)=\(value)" }
            } else {
                lines.append("\(key)=\(value)")
            }
        }
        for line in defaults.components(separatedBy: .newlines) where !line.hasPrefix("#") {
            if let separator = line.firstIndex(of: "=") {
                set(String(line[..<separator]), String(line[line.index(after: separator)...]), onlyIfMissing: true)
            }
        }
        // First-run installation never starts unattended recovery automatically.
        if oldConfig == nil { set("MONITORING_ENABLED", "0") }
        set("LAUNCH_AT_LOGIN", "1", onlyIfMissing: true)
        set("SURGE_UI_HELPER_APP", appURL.path)
        let oldRevision = try? String(contentsOf: revisionURL, encoding: .utf8)
        let changedVersion = oldRevision?.trimmingCharacters(in: .whitespacesAndNewlines) != version
        if changedVersion { set("ENABLE_UI_FALLBACK", "0") }
        let config = lines.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"

        func plist(_ value: [String: Any]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        }
        let agent: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryURL.path, "--run"],
            "EnvironmentVariables": [
                "SURGE_WATCHDOG_CONFIG": configURL.path,
                "SURGE_WATCHDOG_LOG_DIR": logs.path
            ],
            "RunAtLoad": true, "StartInterval": 10, "ThrottleInterval": 10,
            "ProcessType": "Background", "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": home.appendingPathComponent("Library/Logs/surge-watchdog.error.log").path
        ]
        var updates: [(URL, Data, Int)] = [
            (binaryURL, try Data(contentsOf: payload.appendingPathComponent("bin/surge-watchdog")), 0o755),
            (configURL, Data(config.utf8), 0o600),
            (agentURL, try plist(agent), 0o644),
            (revisionURL, Data((version + "\n").utf8), 0o600)
        ]
        if lines.contains("LAUNCH_AT_LOGIN=1") {
            updates.append((loginURL, try plist([
                "Label": label + ".app",
                "ProgramArguments": ["/usr/bin/open", "-g", appURL.path, "--args", "--background"],
                "RunAtLoad": true, "ProcessType": "Interactive", "LimitLoadToSessionType": "Aqua"
            ]), 0o644))
        }
        // Capture exact prior contents and permissions for a failed installation.
        var backups: [(URL, Data?, Int)] = []
        for (url, _, _) in updates {
            let exists = fm.fileExists(atPath: url.path)
            let data = exists ? try Data(contentsOf: url) : nil
            let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
            backups.append((url, data, mode))
        }
        let previousProbe = fm.fileExists(atPath: probeURL.path) ? try Data(contentsOf: probeURL) : nil
        let hadAgent = fm.fileExists(atPath: agentURL.path)
        do {
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
            for (url, data, mode) in updates {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            }
            if changedVersion && previousProbe != nil { try fm.removeItem(at: probeURL) }
            try activate(agentURL)
        } catch {
            let originalError = error
            var rollbackErrors: [String] = []
            for (url, data, mode) in backups.reversed() {
                do {
                    if let data {
                        try data.write(to: url, options: .atomic)
                        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
                    } else if fm.fileExists(atPath: url.path) {
                        try fm.removeItem(at: url)
                    }
                } catch { rollbackErrors.append(error.localizedDescription) }
            }
            if changedVersion, let previousProbe {
                do { try previousProbe.write(to: probeURL, options: .atomic) }
                catch { rollbackErrors.append(error.localizedDescription) }
            }
            if hadAgent {
                do { try activate(agentURL) }
                catch { rollbackErrors.append(error.localizedDescription) }
            }
            if !rollbackErrors.isEmpty {
                throw NSError(domain: "SurgeWatchdog.Install", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "\(originalError.localizedDescription)；恢复旧安装时仍有错误：\(rollbackErrors.joined(separator: "；"))"
                ])
            }
            throw originalError
        }
    }
}
