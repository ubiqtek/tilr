import XCTest
import Yams

final class ConfigTests: XCTestCase {

    let hammerspoonEquivalentYAML = """
    keyboardShortcuts:
      switchToSpace: cmd+opt
      moveAppToSpace: cmd+shift+opt

    spaces:
      Coding:
        id: "1"
        apps:
          - com.github.wez.wezterm
          - com.google.Chrome
        layout:
          type: sidebar
          main: com.github.wez.wezterm
          ratio: 0.65
      Reference:
        id: "2"
        apps:
          - com.apple.Safari
      Scratch:
        id: "3"
        apps:
          - com.apple.Notes
    """

    func testParsesThreeSpaces() throws {
        let config = try YAMLDecoder().decode(TilrConfig.self, from: hammerspoonEquivalentYAML)
        XCTAssertEqual(config.spaces.count, 3)
    }

    func testSpaceIDs() throws {
        let config = try YAMLDecoder().decode(TilrConfig.self, from: hammerspoonEquivalentYAML)
        XCTAssertEqual(config.spaces["Coding"]?.id, "1")
        XCTAssertEqual(config.spaces["Reference"]?.id, "2")
        XCTAssertEqual(config.spaces["Scratch"]?.id, "3")
    }

    func testKeyboardShortcuts() throws {
        let config = try YAMLDecoder().decode(TilrConfig.self, from: hammerspoonEquivalentYAML)
        XCTAssertEqual(config.keyboardShortcuts.switchToSpace, "cmd+opt")
        XCTAssertEqual(config.keyboardShortcuts.moveAppToSpace, "cmd+shift+opt")
    }

    func testDerivedHotkey() throws {
        let config = try YAMLDecoder().decode(TilrConfig.self, from: hammerspoonEquivalentYAML)
        XCTAssertEqual(config.derivedHotkey(for: "Coding"), "cmd+opt+1")
    }

    func testLayout() throws {
        let config = try YAMLDecoder().decode(TilrConfig.self, from: hammerspoonEquivalentYAML)
        let layout = config.spaces["Coding"]?.layout
        XCTAssertEqual(layout?.type, .sidebar)
        XCTAssertEqual(layout?.main, "com.github.wez.wezterm")
        XCTAssertEqual(layout?.ratio, 0.65)
        XCTAssertNil(config.spaces["Reference"]?.layout)
        XCTAssertNil(config.spaces["Scratch"]?.layout)
    }

    func testApps() throws {
        let config = try YAMLDecoder().decode(TilrConfig.self, from: hammerspoonEquivalentYAML)
        XCTAssertEqual(config.spaces["Coding"]?.apps, ["com.github.wez.wezterm", "com.google.Chrome"])
        XCTAssertEqual(config.spaces["Scratch"]?.apps, ["com.apple.Notes"])
    }

    func testDefaultConfigRoundTrip() throws {
        let original = TilrConfig()
        let encoded = try YAMLEncoder().encode(original)
        let decoded = try YAMLDecoder().decode(TilrConfig.self, from: encoded)
        XCTAssertEqual(decoded.keyboardShortcuts.switchToSpace, original.keyboardShortcuts.switchToSpace)
        XCTAssertEqual(decoded.keyboardShortcuts.moveAppToSpace, original.keyboardShortcuts.moveAppToSpace)
        XCTAssertEqual(decoded.spaces.count, 0)
    }

    func testMalformedYAMLThrows() {
        let bad = "spaces: [this is not valid yaml for a dict: {"
        XCTAssertThrowsError(try YAMLDecoder().decode(TilrConfig.self, from: bad))
    }

    func testFillScreenLayout() throws {
        let yaml = """
        keyboardShortcuts:
          switchToSpace: cmd+opt
          moveAppToSpace: cmd+shift+opt
        spaces:
          Reference:
            id: "r"
            apps:
              - app.zen-browser.zen
            layout:
              type: fill-screen
              main: app.zen-browser.zen
        """
        let config = try YAMLDecoder().decode(TilrConfig.self, from: yaml)
        let layout = config.spaces["Reference"]?.layout
        XCTAssertEqual(layout?.type, .fillScreen)
        XCTAssertEqual(layout?.main, "app.zen-browser.zen")
        XCTAssertNil(layout?.ratio)
    }
}
