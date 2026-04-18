import AppKit
import ArgumentParser
import Foundation

@main
struct Tilr: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tilr",
        abstract: "Tilr CLI — query and control the Tilr menu bar app.",
        subcommands: [Status.self, Logs.self, Config.self, Spaces.self, ReloadConfig.self, System.self],
        defaultSubcommand: Status.self
    )
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print app health.")

    func run() throws {
        let client = SocketClient()
        let response: TilrResponse
        do {
            response = try client.send(TilrRequest(cmd: "status"))
        } catch SocketError.notRunning {
            print("Tilr.app is not running.\n\n  Start with: open -a Tilr.app")
            throw ExitCode(1)
        } catch {
            print("Error: \(error)")
            throw ExitCode(1)
        }

        guard response.ok, let data = response.status else {
            print("Error: \(response.error ?? "unknown")")
            throw ExitCode(1)
        }

        let uptime = formatUptime(data.uptimeSeconds)
        print(row("Tilr.app", "running"))
        print(row("PID", "\(data.pid)"))
        print(row("Uptime", uptime))
        print(row("Spaces", "\(data.spacesCount)"))
        print(row("Active", data.activeSpace ?? "-"))
    }

    private func row(_ label: String, _ value: String) -> String {
        label.padding(toLength: 14, withPad: " ", startingAt: 0) + value
    }

    private func formatUptime(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 {
            return "\(seconds / 60)m \(seconds % 60)s"
        }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return "\(h)h \(m)m"
    }
}

struct Logs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stream app logs.")

    func run() throws {
        signal(SIGINT, SIG_DFL)
        let pipeline = #"/usr/bin/log stream --predicate 'subsystem == "io.ubiqtek.tilr"' --level debug | awk 'NR>1 { type=$4; msg=""; for(i=8;i<=NF;i++) msg=msg (i==8?"":OFS) $i; cat=""; rest=msg; if (match(msg, /\[[^]]+\] /)) { cat=substr(msg,RSTART+1,RLENGTH-3); rest=substr(msg,RSTART+RLENGTH) } if (length(cat)>30) cat=substr(cat,1,30); printf "%-8s %-30s %s\n", type, cat, rest; fflush() }'"#
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", pipeline]
        try proc.run()
        proc.waitUntilExit()
    }
}

// MARK: - Config

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or get help for the config file.",
        subcommands: [ConfigShow.self, ConfigHelp.self],
        defaultSubcommand: ConfigShow.self
    )
}

struct ConfigShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print config file path and contents.")

    func run() throws {
        let path = ConfigPaths.configFile.path
        let raw = (try? ConfigStore.rawYAML()) ?? "(empty)"
        print("Config: \(path)\n")
        print(raw)
    }
}

struct ConfigHelp: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "help", abstract: "Print config format reference.")

    func run() throws {
        print("""
        Config file: \(ConfigPaths.configFile.path)

        Format:

          keyboardShortcuts:
            switchToSpace: <modifier>     # modifier + space id = hotkey, e.g. cmd+opt → cmd+opt+1
            moveAppToSpace: <modifier>    # e.g. cmd+shift+opt → cmd+shift+opt+1

          spaces:
            <Name>:                       # display name shown in menu bar and popup
              id: <0-9|a-z>              # single char; appended to modifier to form hotkey
              apps:                      # bundle IDs to show/hide when activating this space
                - <bundle-id>
              layout:                    # optional window layout
                type: sidebar            # only supported type currently
                main: <bundle-id>        # app occupying the large (main) pane
                ratio: 0.65             # fraction of screen width for main pane (0.0–1.0)

        Commands:
          tilr spaces add <name> <id> [bundle-ids...]
          tilr spaces set-layout <name-or-id> --type sidebar [--main <bundle-id>] [--ratio <float>]
        """)
    }
}

// MARK: - Spaces

struct Spaces: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage spaces.",
        subcommands: [SpacesAdd.self, SpacesSetLayout.self, SpacesList.self, SpacesDelete.self]
    )
}

struct SpacesAdd: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a new space.")

    @Argument var name: String
    @Argument var id: String
    @Argument var apps: [String] = []

    func run() throws {
        var config = try ConfigStore.load()
        guard config.spaces[name] == nil else {
            print("Error: space '\(name)' already exists"); throw ExitCode(1)
        }
        guard config.spaces.values.first(where: { $0.id == id }) == nil else {
            print("Error: id '\(id)' already in use"); throw ExitCode(1)
        }
        guard id.count == 1, id.first.map({ $0.isNumber || $0.isLetter }) == true else {
            print("Error: id must be a single character 0-9 or a-z"); throw ExitCode(1)
        }
        config.spaces[name] = SpaceDefinition(id: id, apps: apps)
        try ConfigStore.save(config)
        print("Added space '\(name)' (id: \(id), hotkey: \(config.keyboardShortcuts.switchToSpace)+\(id))")
    }
}

// MARK: - ReloadConfig

struct ReloadConfig: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reload-config",
        abstract: "Tell the running app to reload its config file."
    )
    func run() throws {
        let client = SocketClient()
        let response: TilrResponse
        do {
            response = try client.send(TilrRequest(cmd: "reload-config"))
        } catch SocketError.notRunning {
            print("Tilr.app is not running.\n\n  Start with: open -a Tilr.app")
            throw ExitCode(1)
        }
        if response.ok {
            print(response.message ?? "Config reloaded.")
        } else {
            print("Error: \(response.error ?? "unknown")")
            throw ExitCode(1)
        }
    }
}

struct SpacesSetLayout: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-layout", abstract: "Set layout for a space.")

    @Argument var nameOrId: String
    @Option var type: String = "sidebar"
    @Option var main: String?
    @Option(name: .long) var ratio: Double?

    func run() throws {
        var config = try ConfigStore.load()
        // Resolve: single char → by ID, else → by name
        let resolvedName: String?
        if nameOrId.count == 1 {
            resolvedName = config.spaces.first(where: { $0.value.id == nameOrId })?.key
        } else {
            resolvedName = config.spaces[nameOrId] != nil ? nameOrId : nil
        }
        guard let name = resolvedName else {
            print("Error: no space found for '\(nameOrId)'"); throw ExitCode(1)
        }
        guard let layoutType = LayoutType(rawValue: type) else {
            print("Error: unknown layout type '\(type)'"); throw ExitCode(1)
        }
        config.spaces[name]?.layout = Layout(type: layoutType, main: main, ratio: ratio)
        try ConfigStore.save(config)
        print("Set layout for '\(name)'")
    }
}

// MARK: - SpacesList

struct SpacesList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List all configured spaces.")

    func run() throws {
        let config = try ConfigStore.load()
        let sorted = config.spaces.sorted { $0.value.id < $1.value.id }
        guard !sorted.isEmpty else {
            print("No spaces configured. Run 'tilr spaces add' to add one.")
            return
        }

        let idW = 4, nameW = 11, hotkeyW = 13, appsW = 35
        let header = pad("ID", idW) + pad("Name", nameW) + pad("Hotkey", hotkeyW) + pad("Apps", appsW) + "Layout"
        print(header)

        for (name, space) in sorted {
            let hotkey = "\(config.keyboardShortcuts.switchToSpace)+\(space.id)"

            let appsCol: String
            if space.apps.isEmpty {
                appsCol = "—"
            } else {
                appsCol = space.apps.map { appName(for: $0) }.joined(separator: ", ")
            }

            let layoutCol: String
            if let layout = space.layout {
                var s = layout.type.rawValue
                if let r = layout.ratio { s += " (ratio: \(String(format: "%.2g", r)))" }
                layoutCol = s
            } else {
                layoutCol = "—"
            }

            print(pad(space.id, idW) + pad(name, nameW) + pad(hotkey, hotkeyW) + pad(appsCol, appsW) + layoutCol)
        }
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.padding(toLength: max(s.count, width), withPad: " ", startingAt: 0)
            .padding(toLength: width, withPad: " ", startingAt: 0)
    }
}

// MARK: - Helpers

func appName(for bundleId: String) -> String {
    // 1. Check running applications first
    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }),
       let name = app.localizedName {
        return name
    }
    // 2. Look up installed (but not running) app by bundle ID
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
       let bundle = Bundle(url: url),
       let info = bundle.infoDictionary {
        if let displayName = info["CFBundleDisplayName"] as? String { return displayName }
        if let bundleName = info["CFBundleName"] as? String { return bundleName }
    }
    // 3. Fall back to raw bundle ID
    return bundleId
}

// MARK: - SpacesDelete

struct SpacesDelete: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a space by name or id.")

    @Argument var nameOrId: String

    func run() throws {
        var config = try ConfigStore.load()
        let resolvedName: String?
        if nameOrId.count == 1 {
            resolvedName = config.spaces.first(where: { $0.value.id == nameOrId })?.key
        } else {
            resolvedName = config.spaces[nameOrId] != nil ? nameOrId : nil
        }
        guard let name = resolvedName else {
            print("Error: no space found for '\(nameOrId)'"); throw ExitCode(1)
        }
        let spaceId = config.spaces[name]!.id
        config.spaces.removeValue(forKey: name)
        try ConfigStore.save(config)
        print("Deleted space '\(name)' (id: \(spaceId))")
    }
}

// MARK: - System

struct System: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show running applications and displays.")

    func run() throws {
        // Running applications
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleID: String, name: String)? in
                guard let bid = app.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                return (bid, name)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

        print("Running Applications:")
        print("  \("Name".padding(toLength: 30, withPad: " ", startingAt: 0)) Bundle ID")
        for app in apps {
            let nameCol = app.name.padding(toLength: 30, withPad: " ", startingAt: 0)
            print("  \(nameCol) \(app.bundleID)")
        }

        print("")

        // Displays
        print("Displays:")
        let screens = NSScreen.screens
        for (i, screen) in screens.enumerated() {
            let num = i + 1
            let name = screen.localizedName
            let scale = screen.backingScaleFactor
            let w = Int((screen.frame.width * scale).rounded())
            let h = Int((screen.frame.height * scale).rounded())
            let main = screen == NSScreen.main ? "  [main]" : ""
            print("  \(num)  \(name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(w) × \(h)\(main)")
        }
    }
}
