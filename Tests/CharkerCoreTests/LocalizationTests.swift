import Foundation
import XCTest
@testable import CharkerCore

final class LocalizationTests: XCTestCase {
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func stringsURL(_ localization: String) -> URL {
        packageRoot
            .appendingPathComponent("Resources/Localizations", isDirectory: true)
            .appendingPathComponent("\(localization).lproj", isDirectory: true)
            .appendingPathComponent("Core.strings")
    }

    private func strings(_ localization: String) throws -> [String: String] {
        let data = try Data(contentsOf: stringsURL(localization))
        let value = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        return try XCTUnwrap(value as? [String: String])
    }

    private func bundle(localization: String) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("LocalizationFixture.bundle", isDirectory: true)
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let lproj = resources.appendingPathComponent("\(localization).lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: stringsURL(localization),
            to: lproj.appendingPathComponent("Core.strings")
        )

        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.charker.tests.localization.\(UUID().uuidString)",
            "CFBundleName": "LocalizationFixture",
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

    func testMissingEntryFallsBackToSourceKey() throws {
        let english = try bundle(localization: "en")
        XCTAssertEqual(L10n.text("没有这个键", table: "Core", bundle: english), "没有这个键")
        // The public default remains Localizable; Core callers opt into Core explicitly.
        XCTAssertEqual(L10n.text("未启动", bundle: english), "未启动")
    }

    func testEnglishCoreLookupAndFormatting() throws {
        let english = try bundle(localization: "en")
        XCTAssertTrue(L10n.locale(for: english).identifier.hasPrefix("en"))
        XCTAssertEqual(L10n.text("未启动", table: "Core", bundle: english), "Not Started")
        XCTAssertEqual(
            L10n.format(
                "第 %d 次重试 · %.0f 秒后继续", 2, 3.0,
                table: "Core", bundle: english
            ),
            "Attempt 2 · retrying in 3 s"
        )
    }

    func testChineseCoreLookupAndFormatting() throws {
        let chinese = try bundle(localization: "zh-Hans")
        XCTAssertEqual(L10n.text("未启动", table: "Core", bundle: chinese), "未启动")
        XCTAssertEqual(
            L10n.format(
                "第 %d 次重试 · %.0f 秒后继续", 2, 3.0,
                table: "Core", bundle: chinese
            ),
            "第 2 次重试 · 3 秒后继续"
        )
    }

    func testRegionUsesBundleLanguageAndKeepsAnkerCode() throws {
        let english = try bundle(localization: "en")
        let uk = try XCTUnwrap(AnkerRegion.named("UK"))
        let greece = try XCTUnwrap(AnkerRegion.named("EL"))

        XCTAssertEqual(uk.localeRegionCode, "GB")
        XCTAssertEqual(greece.localeRegionCode, "GR")
        XCTAssertEqual(uk.localizedLabel(bundle: english), "United Kingdom (UK)")
        XCTAssertEqual(greece.localizedLabel(bundle: english), "Greece (EL)")
    }

    func testCoreStringTablesHaveMatchingKeysAndFormatPlaceholders() throws {
        let chinese = try strings("zh-Hans")
        let english = try strings("en")
        XCTAssertEqual(Set(chinese.keys), Set(english.keys))

        let expression = try NSRegularExpression(pattern: #"%(?:\.\d+|0\d+)?[dXf@]"#)
        func placeholders(_ value: String) -> [String] {
            let range = NSRange(value.startIndex..., in: value)
            return expression.matches(in: value, range: range).compactMap { match in
                Range(match.range, in: value).map { String(value[$0]) }
            }.sorted()
        }

        for key in chinese.keys {
            XCTAssertEqual(
                placeholders(chinese[key] ?? ""),
                placeholders(english[key] ?? ""),
                "format placeholders differ for \(key)"
            )
        }
    }
}
