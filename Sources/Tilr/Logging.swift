import OSLog

extension Logger {
    private static let subsystem = "io.ubiqtek.tilr"

    static let app      = Logger(subsystem: subsystem, category: "app")
    static let space    = Logger(subsystem: subsystem, category: "space")
    static let menuBar  = Logger(subsystem: subsystem, category: "menubar")
    static let hotkey   = Logger(subsystem: subsystem, category: "hotkey")
    static let config   = Logger(subsystem: subsystem, category: "config")
    static let state    = Logger(subsystem: subsystem, category: "state")
    static let socket   = Logger(subsystem: subsystem, category: "socket")
    static let windows  = Logger(subsystem: subsystem, category: "windows")
}
