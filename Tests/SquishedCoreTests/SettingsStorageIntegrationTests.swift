import XCTest
@testable import SquishedCore

/// Exercise the real defaults store and JSON codec across upgrade and restart boundaries.
final class SettingsStorageIntegrationTests: XCTestCase {
    func testLayoutUpgradeAndRestart() throws {
        let suite = "squished-settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = HostConfig(kind: .ssh("server"), displayName: "server", menuBarLabel: "SRV")
        let original = FleetSettings(hosts: [host], refreshInterval: 3, showNetworkInMenuBar: false,
                                     showSimulators: false)
        var oldSettings = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        oldSettings.removeValue(forKey: "panelLayout")
        oldSettings["retiredSetting"] = "preserve during migration"
        let oldData = try JSONSerialization.data(withJSONObject: oldSettings)

        defaults.set(oldData, forKey: "settings")
        XCTAssertEqual(FleetSettings.load(from: defaults).panelLayout, .extreme)
        XCTAssertEqual(defaults.data(forKey: "settings"), oldData, "loading defaults alone must not rewrite settings")

        for layout in PanelLayout.allCases {
            defaults.set(oldData, forKey: "settings")
            defaults.set(layout.rawValue, forKey: "panelDensity")
            var expected = original
            expected.panelLayout = layout
            XCTAssertEqual(FleetSettings.load(from: defaults), expected)
            XCTAssertNil(defaults.object(forKey: "panelDensity"))
            let migratedData = try XCTUnwrap(defaults.data(forKey: "settings"))
            let migrated = try XCTUnwrap(JSONSerialization.jsonObject(with: migratedData) as? [String: Any])
            var expectedJSON = oldSettings
            expectedJSON["panelLayout"] = layout.rawValue
            XCTAssertEqual(NSDictionary(dictionary: migrated), NSDictionary(dictionary: expectedJSON))
            XCTAssertEqual(FleetSettings.load(from: defaults), expected, "migration must survive restart")

            // A real saved choice takes priority over any leftover trial preference.
            defaults.set("current", forKey: "panelDensity")
            XCTAssertEqual(FleetSettings.load(from: defaults), expected)
            XCTAssertNil(defaults.object(forKey: "panelDensity"))
        }

        oldSettings["panelLayout"] = "future-layout"
        defaults.set(try JSONSerialization.data(withJSONObject: oldSettings), forKey: "settings")
        defaults.set("current", forKey: "panelDensity")
        XCTAssertEqual(FleetSettings.load(from: defaults), original)
        XCTAssertNil(defaults.object(forKey: "panelDensity"))

        defaults.removeObject(forKey: "settings")
        defaults.set("medium", forKey: "panelDensity")
        XCTAssertEqual(FleetSettings.load(from: defaults).panelLayout, .medium)
        XCTAssertNil(defaults.object(forKey: "panelDensity"))
        XCTAssertEqual(FleetSettings.load(from: defaults).panelLayout, .medium)

        defaults.removeObject(forKey: "settings")
        defaults.set("unknown-trial", forKey: "panelDensity")
        XCTAssertEqual(FleetSettings.load(from: defaults).panelLayout, .extreme)
        XCTAssertNil(defaults.object(forKey: "panelDensity"))
    }
}
