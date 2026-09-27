import Foundation

@main
enum RuntimeInstallerTests {
    static func main() throws {
        let fm = FileManager.default
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let home = URL(fileURLWithPath: CommandLine.arguments[2])
        let app = home.appendingPathComponent("Applications/Surge Watchdog.app")
        let support = home.appendingPathComponent("Library/Application Support/surge-watchdog")
        let config = support.appendingPathComponent("config")
        let binary = support.appendingPathComponent("bin/surge-watchdog")
        let revision = support.appendingPathComponent("runtime-version")
        let probe = support.appendingPathComponent("state/ui_probe_success_epoch")
        let agent = home.appendingPathComponent("Library/LaunchAgents/com.shenhan.surge-watchdog.plist")
        var activations = 0
        try RuntimeInstaller.install(resources: resources, home: home, appURL: app, version: "11") { url in
            activations += 1
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
            precondition((plist["ProgramArguments"] as! [String])[0] == binary.path)
            precondition(fm.isExecutableFile(atPath: binary.path))
        }
        precondition(activations == 1)
        var text = try String(contentsOf: config, encoding: .utf8)
        precondition(text.contains("MONITORING_ENABLED=0\n"))
        precondition(text.contains("ENABLE_UI_FALLBACK=0\n"))
        precondition(text.contains("SURGE_UI_HELPER_APP=\(app.path)\n"))

        // Upgrades preserve existing user settings, but invalidate a UI probe.
        text = text.replacingOccurrences(of: "MONITORING_ENABLED=0", with: "MONITORING_ENABLED=1")
            .replacingOccurrences(of: "ENABLE_UI_FALLBACK=0", with: "ENABLE_UI_FALLBACK=1")
            .replacingOccurrences(of: "LOG_RETENTION_DAYS=7", with: "LOG_RETENTION_DAYS=31")
        try Data(text.utf8).write(to: config)
        try fm.createDirectory(at: probe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("12345".utf8).write(to: probe)
        try RuntimeInstaller.install(resources: resources, home: home, appURL: app, version: "12") { _ in }
        let upgraded = try String(contentsOf: config, encoding: .utf8)
        precondition(upgraded.contains("MONITORING_ENABLED=1\n"))
        precondition(upgraded.contains("LOG_RETENTION_DAYS=31\n"))
        precondition(upgraded.contains("ENABLE_UI_FALLBACK=0\n"))
        precondition(!fm.fileExists(atPath: probe.path))

        // A launchd failure must restore every old file and reactivate the old job.
        try Data("preserved-probe".utf8).write(to: probe)
        let snapshots = try [config, binary, revision, agent, probe].map { ($0, try Data(contentsOf: $0)) }
        var activationAttempts = 0
        do {
            try RuntimeInstaller.install(resources: resources, home: home, appURL: app, version: "13") { _ in
                activationAttempts += 1
                if activationAttempts == 1 { throw NSError(domain: "Test", code: 42) }
            }
            preconditionFailure("Activation failure was not returned")
        } catch { precondition((error as NSError).code == 42) }
        precondition(activationAttempts == 2)
        for (url, data) in snapshots {
            let restored = try Data(contentsOf: url)
            precondition(restored == data)
        }

        let freshFailureHome = home.appendingPathComponent("failed first install")
        do {
            try RuntimeInstaller.install(resources: resources, home: freshFailureHome, appURL: app, version: "11") { _ in
                throw NSError(domain: "Test", code: 43)
            }
            preconditionFailure("First-install activation failure was not returned")
        } catch { precondition((error as NSError).code == 43) }
        precondition(!fm.fileExists(atPath: freshFailureHome.appendingPathComponent("Library/Application Support/surge-watchdog/config").path))
        precondition(!fm.fileExists(atPath: freshFailureHome.appendingPathComponent("Library/LaunchAgents/com.shenhan.surge-watchdog.plist").path))
        print("Runtime installation, upgrade, and rollback checks passed")
    }
}
