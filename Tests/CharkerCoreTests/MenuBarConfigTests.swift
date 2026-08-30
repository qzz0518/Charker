import A2687Protocol
import XCTest
@testable import CharkerCore

final class MenuBarConfigTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func localizationBundle(_ localization: String) throws -> Bundle {
        let source = packageRoot
            .appendingPathComponent("Resources/Localizations", isDirectory: true)
            .appendingPathComponent("\(localization).lproj", isDirectory: true)
            .appendingPathComponent("Core.strings")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("MenuBarLocalizationFixture.bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let lproj = resources.appendingPathComponent("\(localization).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: lproj.appendingPathComponent("Core.strings"))

        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.charker.tests.menubar-localization.\(UUID().uuidString)",
            "CFBundleName": "MenuBarLocalizationFixture",
            "CFBundlePackageType": "BNDL",
            "CFBundleDevelopmentRegion": localization,
            "CFBundleLocalizations": [localization],
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return try XCTUnwrap(Bundle(url: root))
    }

    private func snapshot(
        c1: Double? = 65, c2: Double? = 18, c3: Double? = nil
    ) -> SessionSnapshot {
        func port(_ port: A2687.Port, _ watts: Double?) -> PortTelemetry {
            guard let watts else {
                return PortTelemetry(port: port, statusCode: 0, voltage: 0, current: 0, power: 0)
            }
            return PortTelemetry(
                port: port, statusCode: 1, voltage: 20, current: watts / 20, power: watts
            )
        }
        var snapshot = SessionSnapshot()
        snapshot.phase = .monitoring
        snapshot.telemetry = ChargerTelemetry(
            ports: [port(.c1, c1), port(.c2, c2), port(.c3, c3)],
            receivedAt: Date(), sourceOpcode: A2687.Opcode.realtimeReport
        )
        return snapshot
    }

    // MARK: Rendering

    func testRenderMatchesLegacyTemplateOutput() {
        // The structured renderer must say exactly what the template renderer
        // said for the equivalent layout — the migration must be invisible.
        let items = MenuBarConfig.parse("{total}")
        XCTAssertEqual(
            MenuBarConfig.render(items, snapshot: snapshot(), defaultDecimals: 1, hideIdlePorts: false),
            StatusTemplate.render("{total}", snapshot: snapshot(), decimals: 1)
        )

        let perPort = MenuBarConfig.parse("C1 {c1} · C2 {c2}")
        XCTAssertEqual(
            MenuBarConfig.render(perPort, snapshot: snapshot(), defaultDecimals: 0, hideIdlePorts: false),
            "C1 65 W · C2 18 W"
        )
    }

    func testHidingIdlePortDropsItsRunAndSeparator() {
        let items = MenuBarConfig.parse("C1 {c1} · C2 {c2}")
        XCTAssertEqual(
            MenuBarConfig.render(items, snapshot: snapshot(c2: 0), defaultDecimals: 1, hideIdlePorts: true),
            "C1 65.0 W"
        )
        XCTAssertEqual(
            MenuBarConfig.render(items, snapshot: snapshot(c1: 0), defaultDecimals: 1, hideIdlePorts: true),
            "C2 18.0 W"
        )
    }

    func testPerItemOptionsOverrideDefaults() {
        var item = MenuBarItem(kind: .totalPower)
        item.decimals = 2
        item.showsUnit = false
        item.label = "总"
        XCTAssertEqual(
            MenuBarConfig.render([item], snapshot: snapshot(), defaultDecimals: 0, hideIdlePorts: false),
            "总 83.00"
        )
    }

    func testPortNameCanBeHiddenOrRelabelled() {
        var item = MenuBarItem(kind: .portPower, port: 0)
        XCTAssertEqual(
            MenuBarConfig.display(item, snapshot: snapshot(), defaultDecimals: 1, hideIdlePorts: false),
            "C1 65.0 W"
        )
        item.showsPortName = false
        XCTAssertEqual(
            MenuBarConfig.display(item, snapshot: snapshot(), defaultDecimals: 1, hideIdlePorts: false),
            "65.0 W"
        )
        item.showsPortName = true
        item.label = "MacBook"
        XCTAssertEqual(
            MenuBarConfig.display(item, snapshot: snapshot(), defaultDecimals: 1, hideIdlePorts: false),
            "MacBook 65.0 W"
        )
    }

    func testPortNicknameInheritsIntoMenuBarUnlessOverridden() {
        var item = MenuBarItem(kind: .portPower, port: 0)
        let nicknames = ["MacBook", "", ""]
        // Nickname flows in when the item has no label of its own.
        XCTAssertEqual(
            MenuBarConfig.display(
                item, snapshot: snapshot(), defaultDecimals: 1,
                hideIdlePorts: false, portNicknames: nicknames
            ),
            "MacBook 65.0 W"
        )
        // An explicit menu-bar label still wins over the nickname.
        item.label = "外接屏"
        XCTAssertEqual(
            MenuBarConfig.display(
                item, snapshot: snapshot(), defaultDecimals: 1,
                hideIdlePorts: false, portNicknames: nicknames
            ),
            "外接屏 65.0 W"
        )
        // Hiding the port name hides nickname and label alike.
        item.showsPortName = false
        XCTAssertEqual(
            MenuBarConfig.display(
                item, snapshot: snapshot(), defaultDecimals: 1,
                hideIdlePorts: false, portNicknames: nicknames
            ),
            "65.0 W"
        )
    }

    func testNoTelemetryShowsPlaceholders() {
        let items = [MenuBarItem(kind: .totalPower), MenuBarItem(kind: .portPower, port: 0)]
        let rendered = MenuBarConfig.render(
            items, snapshot: SessionSnapshot(), defaultDecimals: 1, hideIdlePorts: false
        )
        XCTAssertEqual(rendered, "— C1 —")
    }

    func testSystemContentUsesTheCurrentBundleLanguage() throws {
        let chinese = try localizationBundle("zh-Hans")
        let english = try localizationBundle("en")
        let count = MenuBarItem(kind: .portsCount, systemContent: .activePortsCount)
        let text = MenuBarItem(kind: .text, systemContent: .sampleText)

        XCTAssertEqual(
            MenuBarConfig.display(
                count, snapshot: snapshot(), defaultDecimals: 1,
                hideIdlePorts: false, bundle: chinese
            ),
            "2 口"
        )
        XCTAssertEqual(
            MenuBarConfig.display(
                count, snapshot: snapshot(), defaultDecimals: 1,
                hideIdlePorts: false, bundle: english
            ),
            "2 active"
        )
        XCTAssertEqual(
            MenuBarConfig.display(
                text, snapshot: snapshot(), defaultDecimals: 1,
                hideIdlePorts: false, bundle: chinese
            ),
            "文本"
        )
        XCTAssertEqual(
            MenuBarConfig.display(
                text, snapshot: snapshot(), defaultDecimals: 1,
                hideIdlePorts: false, bundle: english
            ),
            "Text"
        )
        XCTAssertEqual(MenuBarConfig.serialize([count, text], bundle: english), "{ports} active Text")
    }

    func testUserLabelIsVerbatimAndOverridesSystemContent() throws {
        let english = try localizationBundle("en")
        var count = MenuBarItem(
            kind: .portsCount,
            label: "口",
            systemContent: .activePortsCount
        )
        let text = MenuBarItem(
            kind: .text,
            label: "文本",
            systemContent: .sampleText
        )

        XCTAssertEqual(
            MenuBarConfig.display(
                count, snapshot: snapshot(), defaultDecimals: 1,
                hideIdlePorts: false, bundle: english
            ),
            "口 2"
        )
        XCTAssertEqual(
            MenuBarConfig.display(
                text, snapshot: snapshot(), defaultDecimals: 1,
                hideIdlePorts: false, bundle: english
            ),
            "文本"
        )
        XCTAssertNil(
            MenuBarConfig.display(
                MenuBarItem(kind: .text, label: "", systemContent: .sampleText),
                snapshot: snapshot(), defaultDecimals: 1,
                hideIdlePorts: false, bundle: english
            )
        )

        count.setUserLabel(nil)
        XCTAssertNil(count.label)
        XCTAssertNil(count.systemContent)
        XCTAssertEqual(
            MenuBarConfig.display(
                count, snapshot: snapshot(), defaultDecimals: 1,
                hideIdlePorts: false, bundle: english
            ),
            "2"
        )
    }

    func testBuiltInPresetPersistsSystemRoleInsteadOfLocalizedLabel() throws {
        let systemItems = MenuBarConfig.presets
            .flatMap(\.items)
            .filter { $0.systemContent != nil }

        XCTAssertTrue(systemItems.contains {
            $0.kind == .portsCount && $0.systemContent == .activePortsCount
        })
        XCTAssertTrue(systemItems.allSatisfy { $0.label == nil })
    }

    // MARK: Template bridge

    func testParseMergesPortLabelIntoPortItem() {
        let items = MenuBarConfig.parse("C1 {c1} · C2 {c2}")
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].kind, .portPower)
        XCTAssertEqual(items[0].port, 0)
        XCTAssertTrue(items[0].showsPortName)
        XCTAssertEqual(items[1].kind, .separator)
        XCTAssertEqual(items[2].port, 1)
    }

    func testUnknownTokensSurviveAsText() {
        let items = MenuBarConfig.parse("{total} {rm -rf}")
        XCTAssertEqual(items.map(\.kind), [.totalPower, .text])
        XCTAssertEqual(items[1].label, "{rm -rf}")
        XCTAssertEqual(MenuBarConfig.serialize(items), "{total} {rm -rf}")
    }

    func testSerializeParseRoundTripPreservesStructure() {
        let original = "C1 {c1} · {total} | {state} 已连接"
        let reparsed = MenuBarConfig.parse(MenuBarConfig.serialize(MenuBarConfig.parse(original)))
        XCTAssertEqual(MenuBarConfig.parse(original).map(\.kind), reparsed.map(\.kind))
    }

    // MARK: Persistence

    func testEncodeDecodeRoundTrip() {
        var item = MenuBarItem(kind: .portPower, port: 2)
        item.decimals = 0
        item.label = "外接屏"
        let items = [item, MenuBarItem(kind: .separator, label: "|")]
        XCTAssertEqual(MenuBarConfig.decode(MenuBarConfig.encode(items)), items)
    }

    func testSystemContentEncodeDecodeRoundTrip() throws {
        let item = MenuBarItem(kind: .text, systemContent: .sampleText)
        let json = MenuBarConfig.encode([item])
        XCTAssertTrue(json.contains("\"systemContent\":\"sampleText\""), json)
        XCTAssertEqual(MenuBarConfig.decode(json), [item])
    }

    func testLegacyJSONWithoutSystemContentDecodesVerbatim() throws {
        let json = """
        [{"kind":"portsCount","label":"口","showsUnit":true,"showsPortName":true},
         {"kind":"text","label":"文本","showsUnit":true,"showsPortName":true}]
        """
        let items = try XCTUnwrap(MenuBarConfig.decode(json))
        XCTAssertEqual(items.map(\.kind), [.portsCount, .text])
        XCTAssertEqual(items.map(\.label), ["口", "文本"])
        XCTAssertTrue(items.allSatisfy { $0.systemContent == nil })

        let reencoded = MenuBarConfig.encode(items)
        XCTAssertFalse(reencoded.contains("systemContent"), reencoded)
    }

    func testUnknownSystemContentDoesNotDropTheItem() throws {
        let json = """
        [{"kind":"text","label":"用户原文","systemContent":"futureRole",
          "showsUnit":true,"showsPortName":true},
         {"kind":"state","showsUnit":true,"showsPortName":true}]
        """
        let items = try XCTUnwrap(MenuBarConfig.decode(json))
        XCTAssertEqual(items.map(\.kind), [.text, .state])
        XCTAssertEqual(items.first?.label, "用户原文")
        XCTAssertNil(items.first?.systemContent)
    }

    func testDecodeDropsCorruptEntriesNotTheWholeLayout() {
        let json = """
        [{"kind":"totalPower","showsUnit":true,"showsPortName":true},
         {"kind":"fromTheFuture","exotic":1},
         {"kind":"state","showsUnit":true,"showsPortName":true}]
        """
        let items = MenuBarConfig.decode(json)
        XCTAssertEqual(items?.map(\.kind), [.totalPower, .state])
    }

    func testPreferencesMigrateTemplateOnlyConfigurations() throws {
        let defaults = MemoryDefaults()
        defaults.set("C1 {c1} · C2 {c2}", forKey: "statusTemplate")

        let prefs = PreferencesStore(defaults: defaults).load()
        XCTAssertEqual(prefs.menuBarItems.map(\.kind), [.portPower, .separator, .portPower])
        // And the derived template stays truthful after a structured edit.
        var mutated = prefs
        mutated.menuBarItems = [MenuBarItem(kind: .totalPower)]
        XCTAssertEqual(mutated.template, "{total}")
    }
}
