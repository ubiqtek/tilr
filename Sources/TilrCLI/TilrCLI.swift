import AppKit
import ArgumentParser
import Foundation

@main
struct Tilr: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tilr",
        abstract: "Tilr CLI — query and control the Tilr menu bar app.",
        subcommands: [Status.self, Logs.self, Config.self, Spaces.self, Displays.self, ReloadConfig.self, System.self, Context.self, Doctor.self, DebugMarker.self],
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

        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigintSource.setEventHandler { proc.terminate() }
        sigintSource.resume()

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
          tilr spaces config add-app <name-or-id> <bundle-id>
          tilr spaces config remove-app <name-or-id> <bundle-id>
          tilr displays list
          tilr displays configure <id> [--name <label>] [--number <n>] [--default-space <space>]
        """)
    }
}

// MARK: - Spaces

struct Spaces: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage spaces.",
        subcommands: [SpacesAdd.self, SpacesSetLayout.self, SpacesList.self, SpacesDelete.self, SpacesConfig.self]
    )
}

struct SpacesConfig: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Configure space properties.",
        subcommands: [SpacesConfigAddApp.self, SpacesConfigRemoveApp.self]
    )
}

struct SpacesConfigAddApp: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-app", abstract: "Add a bundle ID to a space's apps list.")

    @Argument var nameOrId: String
    @Argument var bundleId: String

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
        guard !config.spaces[name]!.apps.contains(bundleId) else {
            print("Error: '\(bundleId)' is already in space '\(name)'"); throw ExitCode(1)
        }
        config.spaces[name]!.apps.append(bundleId)
        try ConfigStore.save(config)
        print("Added '\(bundleId)' to space '\(name)'")
    }
}

struct SpacesConfigRemoveApp: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove-app", abstract: "Remove a bundle ID from a space's apps list.")

    @Argument var nameOrId: String
    @Argument var bundleId: String

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
        guard config.spaces[name]!.apps.contains(bundleId) else {
            print("Error: '\(bundleId)' is not in space '\(name)'"); throw ExitCode(1)
        }
        config.spaces[name]!.apps.removeAll(where: { $0 == bundleId })
        try ConfigStore.save(config)
        print("Removed '\(bundleId)' from space '\(name)'")
    }
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

        // Best-effort: fetch runtime fillScreenLastApp map from the running app.
        // If Tilr isn't running or the call fails, the map is empty and no '*' is shown.
        var fillScreenLastApp: [String: String] = [:]
        do {
            let client = SocketClient()
            let response = try client.send(TilrRequest(cmd: "status"))
            if response.ok, let data = response.status, let map = data.fillScreenLastApp {
                fillScreenLastApp = map
            }
        } catch {
            // silently ignore — the table still prints without stars
        }

        let idW = 4, nameW = 11, hotkeyW = 13, appsW = 35
        print("[] = layout main, * = last foreground (fill-screen only)")
        print("")
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
                let recordedBundleId = fillScreenLastApp[name]
                let formatted: [String] = space.apps.map { bundleId in
                    var display = appName(for: bundleId)
                    if bundleId == recordedBundleId { display += "*" }
                    return display
                }
                if let mainBundleId = space.layout?.main,
                   let mainIdx = space.apps.firstIndex(of: mainBundleId) {
                    let mainDisplayName = formatted[mainIdx]
                    var rest = formatted
                    rest.remove(at: mainIdx)
                    let parts = ["[\(mainDisplayName)]"] + rest
                    appsCol = parts.joined(separator: ", ")
                } else {
                    appsCol = formatted.joined(separator: ", ")
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
        subcommands: [DisplaysList.self, DisplaysConfigure.self, DisplaysIdentify.self]
    )
}

struct DisplaysIdentify: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "identify", abstract: "Flash a labelled popup on each display.")

    func run() throws {
        let client = SocketClient()
        let response: TilrResponse
        do {
            response = try client.send(TilrRequest(cmd: "identify-displays"))
        } catch SocketError.notRunning {
            print("Tilr.app is not running.")
            throw ExitCode(1)
        } catch {
            print("Error: \(error)")
            throw ExitCode(1)
        }
        if response.ok {
            print(response.message ?? "Identifying displays.")
        } else {
            print("Error: \(response.error ?? "unknown")")
            throw ExitCode(1)
        }
    }
}

struct DisplaysList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List displays with Tilr configuration.")

    func run() throws {
        let config = try ConfigStore.load()
        let screens = NSScreen.screens
        var state = DisplayStateStore.load()
        var stateChanged = false

        let idW = 4, nameW = 12, systemW = 26, defaultSpaceW = 15
        print(pad("ID", idW) + pad("Tilr Name", nameW) + pad("System Name", systemW) + pad("Default Space", defaultSpaceW) + "UUID")
        print(String(repeating: "-", count: 2).padding(toLength: idW, withPad: " ", startingAt: 0)
            + String(repeating: "-", count: 9).padding(toLength: nameW, withPad: " ", startingAt: 0)
            + String(repeating: "-", count: 11).padding(toLength: systemW, withPad: " ", startingAt: 0)
            + String(repeating: "-", count: 13).padding(toLength: defaultSpaceW, withPad: " ", startingAt: 0)
            + String(repeating: "-", count: 4))

        for screen in screens {
            let uuid = displayUUID(for: screen)
            let before = state.nextId
            let displayId: Int
            if let uuid {
                displayId = DisplayStateStore.resolveId(for: uuid, state: &state)
                if state.nextId != before { stateChanged = true }
            } else {
                displayId = 0
            }
            let displayKey = "\(displayId)"
            let displayConfig = config.displays[displayKey]
            let tilrName = displayConfig?.name ?? "—"
            let systemName = screen.localizedName
            let defaultSpace = displayConfig?.defaultSpace ?? "—"
            let uuidCol = uuid ?? "—"
            print(pad(displayKey, idW) + pad(tilrName, nameW) + pad(systemName, systemW) + pad(defaultSpace, defaultSpaceW) + uuidCol)
        }

        if stateChanged {
            try? DisplayStateStore.save(state)
        }
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.padding(toLength: max(s.count, width), withPad: " ", startingAt: 0)
            .padding(toLength: width, withPad: " ", startingAt: 0)
    }
}

struct DisplaysConfigure: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "configure", abstract: "Set name, number, or default space for a display.")

    @Argument var id: Int
    @Option var name: String?
    @Option var number: Int?
    @Option var defaultSpace: String?

    func run() throws {
        guard name != nil || number != nil || defaultSpace != nil else {
            print("Error: at least one option required: --name, --number, or --default-space")
            throw ExitCode(1)
        }

        var config = try ConfigStore.load()
        var state = DisplayStateStore.load()
        var changed: [String] = []

        if let newName = name {
            var dc = config.displays["\(id)"] ?? DisplayConfig()
            dc.name = newName
            config.displays["\(id)"] = dc
            changed.append("name=\(newName)")
        }

        if let ds = defaultSpace {
            let resolvedName: String?
            if ds.count == 1 {
                resolvedName = config.spaces.first(where: { $0.value.id == ds })?.key
            } else {
                resolvedName = config.spaces[ds] != nil ? ds : nil
            }
            guard let spaceName = resolvedName else {
                print("Error: no space found for '\(ds)'")
                throw ExitCode(1)
            }
            var dc = config.displays["\(id)"] ?? DisplayConfig()
            dc.defaultSpace = spaceName
            config.displays["\(id)"] = dc
            changed.append("defaultSpace=\(spaceName)")
        }

        if let newNumber = number {
            guard newNumber != id else {
                print("Error: --number \(newNumber) is the same as the current ID")
                throw ExitCode(1)
            }
            guard state.uuidToId.values.first(where: { $0 == newNumber }) == nil else {
                print("Error: number \(newNumber) is already in use")
                throw ExitCode(1)
            }
            guard let uuid = state.uuidToId.first(where: { $0.value == id })?.key else {
                print("Error: display \(id) not found in display state")
                throw ExitCode(1)
            }
            state.uuidToId[uuid] = newNumber
            if let dc = config.displays["\(id)"] {
                config.displays.removeValue(forKey: "\(id)")
                config.displays["\(newNumber)"] = dc
            }
            try DisplayStateStore.save(state)
            changed.append("number: \(id) → \(newNumber)")
        }

        try ConfigStore.save(config)
        print("Display \(id) updated: \(changed.joined(separator: ", "))")
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
            CommandEntry(cmd: "tilr spaces config add-app <name-or-id> <bundle-id>", desc: "Add a bundle ID to a space's apps list"),
            CommandEntry(cmd: "tilr spaces config remove-app <name-or-id> <bundle-id>", desc: "Remove a bundle ID from a space's apps list"),
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

// MARK: - Doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Detect stray Tilr and log-stream processes.")

    @Flag(name: .long, help: "Kill any stray processes found.")
    var clean: Bool = false

    func run() throws {
        let tilrPIDs = findProcesses(pgrepArgs: ["-x", "Tilr"])
        let logPIDs = findProcesses(pgrepArgs: ["-f", #"log stream.*io\.ubiqtek\.tilr"#])

        // Exclude this CLI process itself (shouldn't match either search, but be safe)
        let selfPID = getpid()
        let filteredTilr = tilrPIDs.filter { $0 != selfPID }
        let filteredLog = logPIDs.filter { $0 != selfPID }

        let allPIDs = filteredTilr + filteredLog

        if allPIDs.isEmpty {
            print("No stray processes. You're clean.")
            return
        }

        // Print Tilr processes
        print("Tilr processes:")
        if filteredTilr.isEmpty {
            print("  (none)")
        } else {
            for pid in filteredTilr {
                let cmd = commandLine(for: pid)
                print("  PID \(pid)  \(cmd)")
            }
        }

        print("")

        // Print log stream processes
        print("log stream processes (io.ubiqtek.tilr):")
        if filteredLog.isEmpty {
            print("  (none)")
        } else {
            for pid in filteredLog {
                let cmd = commandLine(for: pid)
                print("  PID \(pid)  \(cmd)")
            }
        }

        print("")
        print("\(allPIDs.count) stray process(es) found.")

        if clean {
            print("")
            killProcesses(allPIDs)
        } else {
            print("")
            print("Run `tilr doctor --clean` to kill them.")
        }
    }

    // MARK: - Helpers

    /// Run pgrep with the given arguments and return the list of matched PIDs.
    private func findProcesses(pgrepArgs: [String]) -> [Int32] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = pgrepArgs
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe() // suppress error output
        do {
            try proc.run()
        } catch {
            return []
        }
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Return the full command line for a PID using `ps -p <pid> -o args=`.
    private func commandLine(for pid: Int32) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", "args="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return "(unknown)"
        }
        proc.waitUntilExit()
        let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(unknown)" : raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Send SIGTERM to each PID, wait 0.3s, then SIGKILL any survivors.
    private func killProcesses(_ pids: [Int32]) {
        var living = pids
        for pid in living {
            if kill(pid, SIGTERM) == 0 {
                print("Sent SIGTERM to PID \(pid)")
            } else {
                print("Could not signal PID \(pid) (already gone?)")
            }
        }

        // Wait ~0.3s for graceful exit
        Thread.sleep(forTimeInterval: 0.3)

        // Check survivors
        living = living.filter { isRunning($0) }
        if !living.isEmpty {
            print("")
            print("The following PIDs did not exit; sending SIGKILL:")
            for pid in living {
                if kill(pid, SIGKILL) == 0 {
                    print("  SIGKILL -> PID \(pid)")
                }
            }
        }
    }

    /// Return true if a process with the given PID still exists.
    private func isRunning(_ pid: Int32) -> Bool {
        // kill(pid, 0) succeeds (returns 0) if the process exists
        return kill(pid, 0) == 0
    }
}

// MARK: - DebugMarker

struct DebugMarker: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-marker",
        abstract: "Write a named marker to the Tilr log file for debugging."
    )

    @Argument(help: "Marker description, e.g. 'before BUG-6 repro'")
    var description: String

    func run() throws {
        TilrLogger.shared.marker(description)
        // TilrLogger writes are async through a serial queue; give it a moment to flush.
        Thread.sleep(forTimeInterval: 0.1)
        print("[tilr] marker written: \(description)")
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
