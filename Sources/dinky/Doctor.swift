import AppKit
import DinkyCommands
import DinkyConfig
import DinkyPrivate

// `dinky doctor [--config <path>]`: checks the config and the environment without needing the app. Exit 1 on errors.
func runDoctor(_ args: [String]) -> Int32 {
    var errors = 0, warnings = 0
    func ok(_ text: String) { print("  ok: \(text)") }
    func warn(_ text: String) { warnings += 1; print("  warning: \(text)") }
    func fail(_ text: String) { errors += 1; print("  error: \(text)") }

    let os = ProcessInfo.processInfo.operatingSystemVersion
    print("dinky doctor")
    print("  macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion); dinky is developed and tested on macOS 27")

    var url = Config.userConfigURL
    if let i = args.firstIndex(of: "--config"), i + 1 < args.count { url = URL(fileURLWithPath: args[i + 1]) }
    print("  config: \(url.path)")
    print("  log: \(logURL.path)")
    var config = Config.default
    if !FileManager.default.fileExists(atPath: url.path) {
        warn("no config file yet; the app writes the default one on first run")
    } else {
        do {
            config = try Config.load(from: url)
            ok("parses: \(config.workspaces) workspaces, \(config.modes.count) modes, \(config.rules.count) window rules")
        } catch {
            fail("\(error)")
        }
    }
    for finding in checkConfig(config) {
        finding.level == .error ? fail(finding.message) : warn(finding.message)
    }

    // Dock settings the design depends on. Both default to on when unset.
    if dockSetting("mru-spaces") ?? true {
        warn("\"Automatically rearrange Spaces based on most recent use\" is on; workspace numbers will move around. Turn it off in System Settings > Desktop & Dock")
    } else {
        ok("Spaces are not auto-rearranged")
    }
    if config.followAppActivation.enabled {
        if dockSetting("workspaces-auto-swoosh") ?? true {
            warn("\"When switching to an application, switch to a Space with open windows\" is on; Cmd-Tab will use macOS's slow switch instead of dinky's. The app's onboarding can turn it off")
        } else {
            ok("Cmd-Tab switching goes through dinky")
        }
    }

    // Where the workspaces go with the displays connected now; the app arranges the Spaces to match.
    let connected = dinky_displays()
    let displays = connected.enumerated().map { i, d in
        PlanDisplay(uuid: d.uuid, monitor: Monitor(name: screen(of: d.displayID)?.localizedName ?? "",
                                                   isMain: CGDisplayIsMain(d.displayID) != 0, count: connected.count,
                                                   number: i + 1),
                    spaces: d.spaces.filter(\.isUser).map(\.spaceID), current: d.currentSpaceID)
    }
    let homes = WorkspacePlan(config).homes(displays)
    for (n, patterns) in config.workspaceDisplays.sorted(by: { $0.key < $1.key })
    where !patterns.contains(where: { p in displays.contains { p.matches($0.monitor) } }) {
        // Not connected is fine (a side display at the desk only); secondary with three displays never matches.
        let message = "workspace \(n): no connected display matches \(patterns.map { "'\($0.text)'" }.joined(separator: ", ")), so it is on the main display"
        patterns.contains(.secondary) && displays.count > 2
            ? warn(message + "; secondary only means the other of exactly two displays, use a display number or name")
            : ok(message)
    }
    for (i, display) in displays.enumerated() {
        let label = display.monitor.name.isEmpty ? "display \(i + 1)" : "display \(i + 1) (\(display.monitor.name))"
        let here = homes.filter { $0.value == display.uuid }.keys.sorted()
        let spaces = "\(display.spaces.count) Space\(display.spaces.count == 1 ? "" : "s")"
        ok(here.isEmpty ? "\(label) has \(spaces) and no workspaces"
                        : "\(label) has \(spaces) for workspace\(here.count == 1 ? "" : "s") \(here.map(String.init).joined(separator: ", "))")
    }

    let tilers = runningOtherTilers()
    tilers.isEmpty ? ok("no other tiling window manager is running") : warn(otherTilersWarning(tilers))

    ok(AXIsProcessTrusted() ? "this terminal has Accessibility (the app needs its own grant)" : "this terminal has no Accessibility grant; only the app needs one")
    if let reply = sendToApp("list-monitors --focused --format '%{monitor-name}'"), reply.ok {
        ok("app is running, focused display: \(reply.text)")
    } else {
        warn("app is not running (\(socketPath))")
    }

    print("\(errors) errors, \(warnings) warnings")
    return errors == 0 ? 0 : 1
}

/// A boolean Dock setting, nil when unset.
func dockSetting(_ key: String) -> Bool? {
    CFPreferencesCopyAppValue(key as CFString, "com.apple.dock" as CFString) as? Bool
}
