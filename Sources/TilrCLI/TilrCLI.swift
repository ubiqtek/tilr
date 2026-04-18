import AppKit
import ArgumentParser
import Foundation

@main
struct Tilr: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tilr",
        abstract: "Tilr CLI — query and control the Tilr menu bar app.",
        subcommands: [Status.self, Logs.self, Config.self, Spaces.self, Displays.self, ReloadConfig.self, System.self, Context.self],
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
        let pipeline = #"trap 'kill 0' EXIT; /usr/bin/log stream --predicate 'subsystem == "io.ubiqtek.tilr"' --level debug --style compact | awk '$1 ~ /^[0-9]{4}-/ { abbr=$3; type=(abbr=="I"?"Info":abbr=="Db"?"Debug":abbr=="E"?"Error":abbr=="Fa"?"Fault":"Default"); msg=""; for(i=5;i<=NF;i++) msg=msg (i==5?"":OFS) $i; cat=""; rest=msg; if (match(msg, /\[[^]]+\] /)) { cat=substr(msg,RSTART+1,RLENGTH-3); rest=substr(msg,RSTART+RLENGTH) }; if (length(cat)>30) cat=substr(cat,1,30); printf "%-8s %-30s %s\n", type, cat, rest; fflush() }'"#
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

          displays:
            "1":                          # Tilr display ID (1 = first screen by index order)
              name: <label>              # user-chosen label, e.g. "Main"
              defaultSpace: <name|id>    # space to activate on launch (name or single-char id)

          spaces:
            <Name>:                       # display name shown in menu bar and popup
              id: <0-9|a-z>              # single char; appended to modifier to form hotkey
              apps:                      # bundle IDs to show/hide when activating this space
                - <bundle-id>
              layout:                    # optional window layout
                type: sidebar            # sidebar: main pane + sidebars at a fixed ratio
                main: <bundle-id>        # app occupying the large (main) pane
                ratio: 0.65             # fraction of screen width for main pane (0.0–1.0)

                type: fill-screen        # fill-screen: all apps fill the entire screen; OS picks foreground
                main: <bundle-id>        # app brought to focus when the space activates (no ratio)

        Commands:
          tilr spaces add <name> <id> [bundle-ids...]
          tilr spaces set-layout <name-or-id> --type sidebar [--main <bundle-id>] [--ratio <float>]
          tilr spaces set-layout <name-or-id> --type fill-screen [--main <bundle-id>]
          tilr displays list
          tilr displays configure <id> <name> <default-space>
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
        } catch {
            print("Error: \(error)")
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
        let separator = String(repeating: "-", count: 2).padding(toLength: idW, withPad: " ", startingAt: 0)
            + String(repeating: "-", count: 9).padding(toLength: nameW, withPad: " ", startingAt: 0)
            + String(repeating: "-", count: 11).padding(toLength: hotkeyW, withPad: " ", startingAt: 0)
            + String(repeating: "-", count: 33).padding(toLength: appsW, withPad: " ", startingAt: 0)
            + String(repeating: "-", count: 10)
        print(header)
        print(separator)

        for (name, space) in sorted {
            let hotkey = "\(config.keyboardShortcuts.switchToSpace)+\(space.id)"

            let appsCol: String
            if space.apps.isEmpty {
                appsCol = "—"
            } else {
                let names = space.apps.map { appName(for: $0) }
                if let mainBundleId = space.layout?.main,
                   let mainIdx = space.apps.firstIndex(of: mainBundleId) {
                    let mainDisplayName = names[mainIdx]
                    var rest = names
                    rest.remove(at: mainIdx)
                    let parts = ["[\(mainDisplayName)]"] + rest
                    appsCol = parts.joined(separator: ", ")
                } else {
                    appsCol = names.joined(separator: ", ")
                }
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

// MARK: - Displays

struct Displays: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage display configuration.",
        subcommands: [DisplaysList.self, DisplaysConfigure.self]
    )
}

struct DisplaysList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List displays with Tilr configuration.")

    func run() throws {
        let config = try ConfigStore.load()
        let screens = NSScreen.screens

        let idW = 4, nameW = 12, systemW = 26
        print(pad("ID", idW) + pad("Tilr Name", nameW) + pad("System Name", systemW) + "Default Space")
        print(String(repeating: "-", count: 2).padding(toLength: idW, withPad: " ", startingAt: 0)
            + String(repeating: "-", count: 9).padding(toLength: nameW, withPad: " ", startingAt: 0)
            + String(repeating: "-", count: 11).padding(toLength: systemW, withPad: " ", startingAt: 0)
            + String(repeating: "-", count: 13))

        for (i, screen) in screens.enumerated() {
            let displayId = "\(i + 1)"
            let displayConfig = config.displays[displayId]
            let tilrName = displayConfig?.name ?? "—"
            let systemName = screen.localizedName
            let defaultSpace = displayConfig?.defaultSpace ?? "—"
            print(pad(displayId, idW) + pad(tilrName, nameW) + pad(systemName, systemW) + defaultSpace)
        }
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.padding(toLength: max(s.count, width), withPad: " ", startingAt: 0)
            .padding(toLength: width, withPad: " ", startingAt: 0)
    }
}

struct DisplaysConfigure: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "configure", abstract: "Set name and default space for a display.")

    @Argument var id: Int
    @Argument var name: String
    @Argument var defaultSpace: String

    func run() throws {
        var config = try ConfigStore.load()

        // Validate that the display ID corresponds to a real screen
        let screenCount = NSScreen.screens.count
        guard id >= 1, id <= screenCount else {
            print("Error: display \(id) does not exist (found \(screenCount) screen(s))")
            throw ExitCode(1)
        }

        // Resolve the space: single char → by id, else → by name
        let resolvedName: String?
        if defaultSpace.count == 1 {
            resolvedName = config.spaces.first(where: { $0.value.id == defaultSpace })?.key
        } else {
            resolvedName = config.spaces[defaultSpace] != nil ? defaultSpace : nil
        }
        guard let spaceName = resolvedName else {
            print("Error: no space found for '\(defaultSpace)'")
            throw ExitCode(1)
        }

        config.displays["\(id)"] = DisplayConfig(name: name, defaultSpace: spaceName)
        try ConfigStore.save(config)
        print("Display \(id) configured: name=\(name), defaultSpace=\(spaceName)")
    }
}

// MARK: - Context

struct Context: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print a compact JSON briefing about Tilr for an AI agent.")

    func run() throws {
        let config = try? ConfigStore.load()
        let configPath = ConfigPaths.configFile.path
        let socketPath = TilrPaths.socket.path

        // Build spaces array sorted by id
        struct SpaceEntry: Encodable {
            let id: String
            let name: String
            let hotkey: String
            let apps: [String]
            let layout: String?
        }

        var spacesEntries: [SpaceEntry] = []
        if let config {
            let sorted = config.spaces.sorted { $0.value.id < $1.value.id }
            for (name, space) in sorted {
                let hotkey = "\(config.keyboardShortcuts.switchToSpace)+\(space.id)"
                let apps = space.apps.map { appName(for: $0) }
                let layout: String? = space.layout.map { $0.type.rawValue }
                spacesEntries.append(SpaceEntry(id: space.id, name: name, hotkey: hotkey, apps: apps, layout: layout))
            }
        }

        // Build commands array
        struct CommandEntry: Encodable {
            let cmd: String
            let desc: String
        }
        let commands: [CommandEntry] = [
            CommandEntry(cmd: "tilr context", desc: "Print this JSON summary"),
            CommandEntry(cmd: "tilr status", desc: "Check if Tilr.app is running; exit 0=running, 1=not running"),
            CommandEntry(cmd: "tilr logs", desc: "Stream live app logs"),
            CommandEntry(cmd: "tilr reload-config", desc: "Tell running app to reload config file"),
            CommandEntry(cmd: "tilr config", desc: "Show raw config YAML and path"),
            CommandEntry(cmd: "tilr config help", desc: "Show config format reference"),
            CommandEntry(cmd: "tilr spaces list", desc: "List spaces as a table"),
            CommandEntry(cmd: "tilr spaces add <name> <id> [bundle-ids...]", desc: "Add a space; id is single char 0-9 or a-z"),
            CommandEntry(cmd: "tilr spaces delete <name-or-id>", desc: "Delete a space"),
            CommandEntry(cmd: "tilr spaces set-layout <name-or-id> --type sidebar|fill-screen [--main <bundle-id>] [--ratio <float>]", desc: "Set window layout for a space (sidebar: ratio split; fill-screen: all apps full-screen)"),
            CommandEntry(cmd: "tilr displays list", desc: "List displays with Tilr ID, user name, system name, and default space"),
            CommandEntry(cmd: "tilr displays configure <id> <name> <default-space>", desc: "Set user label and default space for a display; id is integer 1-N"),
            CommandEntry(cmd: "tilr system", desc: "List running apps (name + bundle ID) and displays"),
        ]

        // Top-level encodable struct
        struct ContextPayload: Encodable {
            let description: String
            let config: String
            let socket: String
            let spaces: [SpaceEntry]
            let commands: [CommandEntry]
        }

        let payload = ContextPayload(
            description: "Tilr: macOS workspace manager. Use the CLI to inspect and control spaces. The app must be running for hotkeys and socket commands (status, reload-config) to work.",
            config: configPath,
            socket: socketPath,
            spaces: spacesEntries,
            commands: commands
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let data = try encoder.encode(payload)
        print(String(data: data, encoding: .utf8)!)
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
