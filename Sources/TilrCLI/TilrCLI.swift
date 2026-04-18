import ArgumentParser
import Foundation

@main
struct Tilr: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tilr",
        abstract: "Tilr CLI — query and control the Tilr menu bar app.",
        subcommands: [Status.self, Logs.self],
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
