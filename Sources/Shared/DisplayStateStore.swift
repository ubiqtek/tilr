import Foundation

public struct DisplayState: Codable {
    public var uuidToId: [String: Int]
    public var nextId: Int

    public init(uuidToId: [String: Int] = [:], nextId: Int = 1) {
        self.uuidToId = uuidToId
        self.nextId = nextId
    }
}

public enum DisplayStateStore {
    private static var stateFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tilr/display-state.json")
    }

    public static func load() -> DisplayState {
        guard let data = try? Data(contentsOf: stateFile) else { return DisplayState() }
        return (try? JSONDecoder().decode(DisplayState.self, from: data)) ?? DisplayState()
    }

    public static func save(_ state: DisplayState) throws {
        let url = stateFile
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }

    public static func resolveId(for uuid: String, state: inout DisplayState) -> Int {
        if let existing = state.uuidToId[uuid] { return existing }
        let id = state.nextId
        state.uuidToId[uuid] = id
        state.nextId += 1
        return id
    }
}
