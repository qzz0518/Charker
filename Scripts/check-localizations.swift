#!/usr/bin/env swift

import Darwin
import Foundation

private let localeIDs = ["zh-Hans", "en"]
private let requiredTables: Set<String> = [
    "Core.strings",
    "InfoPlist.strings",
    "Localizable.strings",
]

private struct ArgumentUse: Hashable {
    let index: Int
    let type: String
}

private struct FormatSignature {
    var argumentUses: [ArgumentUse: Int] = [:]
    var conversionCount = 0
    var placeholders: [String] = []
    var problems: [String] = []

    var description: String {
        let arguments = argumentUses
            .sorted {
                if $0.key.index != $1.key.index {
                    return $0.key.index < $1.key.index
                }
                return $0.key.type < $1.key.type
            }
            .map { use, count in
                let suffix = count == 1 ? "" : " x\(count)"
                return "#\(use.index) \(use.type)\(suffix)"
            }
            .joined(separator: ", ")
        let raw = placeholders.isEmpty ? "none" : placeholders.joined(separator: ", ")
        return "\(conversionCount) placeholder(s); arguments [\(arguments)]; raw [\(raw)]"
    }
}

// Captures, in order: conversion position, width, width star, width-star
// position, precision, precision star, precision-star position, length and
// conversion. A literal %% is handled before this expression is evaluated.
private let printfExpression = try! NSRegularExpression(
    pattern: #"%(?:(\d+)\$)?[-+#0']*(?:(\d+)|(\*)(?:(\d+)\$)?)?(?:\.(?:(\d+)|(\*)(?:(\d+)\$)?))?(hh|h|ll|l|j|z|t|L|q)?([@diuoxXfFeEgGaAcCsSpnDUO])"#
)

private func capture(
    _ index: Int,
    from match: NSTextCheckingResult,
    in string: NSString
) -> String? {
    let range = match.range(at: index)
    guard range.location != NSNotFound else { return nil }
    return string.substring(with: range)
}

private func integerWidth(for length: String) -> String {
    switch length {
    case "hh": return "char"
    case "h": return "short"
    case "l": return "long"
    case "ll", "q": return "long-long"
    case "j": return "intmax"
    case "z": return "size"
    case "t": return "ptrdiff"
    default: return "int"
    }
}

private func argumentType(length: String, conversion: Character) -> String {
    switch conversion {
    case "@":
        return "object"
    case "d", "i":
        return "signed-\(integerWidth(for: length))"
    case "u", "o", "x", "X":
        return "unsigned-\(integerWidth(for: length))"
    case "f", "F", "e", "E", "g", "G", "a", "A":
        return length == "L" ? "long-double" : "double"
    case "c":
        return length == "l" ? "wide-character" : "character"
    case "C":
        return "wide-character"
    case "s":
        return length == "l" ? "wide-string" : "c-string"
    case "S":
        return "wide-string"
    case "p":
        return "pointer"
    case "n":
        return "count-pointer-\(integerWidth(for: length))"
    case "D":
        return "signed-long"
    case "U", "O":
        return "unsigned-long"
    default:
        return "unknown-\(conversion)"
    }
}

private func parseFormatSignature(_ value: String) -> FormatSignature {
    let nsValue = value as NSString
    var signature = FormatSignature()
    var searchOffset = 0
    var nextSequentialIndex = 1
    var sawSequential = false
    var sawPositional = false

    func resolvedIndex(_ explicitPosition: String?, rawPlaceholder: String) -> Int? {
        if let explicitPosition {
            sawPositional = true
            guard let position = Int(explicitPosition), position > 0 else {
                signature.problems.append("invalid argument position in \(rawPlaceholder)")
                return nil
            }
            return position
        }

        sawSequential = true
        defer { nextSequentialIndex += 1 }
        return nextSequentialIndex
    }

    func recordArgument(
        explicitPosition: String?,
        type: String,
        rawPlaceholder: String
    ) {
        guard let index = resolvedIndex(explicitPosition, rawPlaceholder: rawPlaceholder) else {
            return
        }
        let use = ArgumentUse(index: index, type: type)
        signature.argumentUses[use, default: 0] += 1
    }

    while searchOffset < nsValue.length {
        let remainingRange = NSRange(
            location: searchOffset,
            length: nsValue.length - searchOffset
        )
        let percentRange = nsValue.range(of: "%", options: [], range: remainingRange)
        guard percentRange.location != NSNotFound else { break }

        let percentOffset = percentRange.location
        if percentOffset + 1 < nsValue.length,
           nsValue.substring(with: NSRange(location: percentOffset + 1, length: 1)) == "%" {
            searchOffset = percentOffset + 2
            continue
        }

        let candidateRange = NSRange(
            location: percentOffset,
            length: nsValue.length - percentOffset
        )
        guard let match = printfExpression.firstMatch(
            in: value,
            options: [.anchored],
            range: candidateRange
        ) else {
            // A plain percent sign is valid in a non-format string. Only
            // syntactically complete printf conversions are signatures here.
            searchOffset = percentOffset + 1
            continue
        }

        let rawPlaceholder = nsValue.substring(with: match.range)
        signature.placeholders.append(rawPlaceholder)

        if capture(3, from: match, in: nsValue) != nil {
            recordArgument(
                explicitPosition: capture(4, from: match, in: nsValue),
                type: "signed-int",
                rawPlaceholder: rawPlaceholder
            )
        }
        if capture(6, from: match, in: nsValue) != nil {
            recordArgument(
                explicitPosition: capture(7, from: match, in: nsValue),
                type: "signed-int",
                rawPlaceholder: rawPlaceholder
            )
        }

        let length = capture(8, from: match, in: nsValue) ?? ""
        let conversionString = capture(9, from: match, in: nsValue)!
        let conversion = conversionString.first!
        recordArgument(
            explicitPosition: capture(1, from: match, in: nsValue),
            type: argumentType(length: length, conversion: conversion),
            rawPlaceholder: rawPlaceholder
        )
        signature.conversionCount += 1
        searchOffset = match.range.location + match.range.length
    }

    if sawSequential && sawPositional {
        signature.problems.append(
            "mixes positional and non-positional arguments; use one style consistently"
        )
    }

    let usesByIndex = Dictionary(grouping: signature.argumentUses.keys, by: \.index)
    for (index, uses) in usesByIndex.sorted(by: { $0.key < $1.key }) {
        let types = Set(uses.map(\.type))
        if types.count > 1 {
            signature.problems.append(
                "argument #\(index) is used with incompatible types: "
                    + types.sorted().joined(separator: ", ")
            )
        }
    }

    return signature
}

private func relativeStringsFiles(in directory: URL) throws -> Set<String> {
    guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
        throw NSError(
            domain: "LocalizationCheck",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "cannot enumerate \(directory.path)"]
        )
    }

    var files: Set<String> = []
    for case let relativePath as String in enumerator {
        guard !relativePath
            .split(separator: "/")
            .contains(where: { $0.hasPrefix(".") }) else {
            continue
        }
        let fileURL = directory.appendingPathComponent(relativePath)
        guard fileURL.pathExtension == "strings" else { continue }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        files.insert(relativePath)
    }
    return files
}

private func loadStrings(
    at url: URL,
    label: String,
    errors: inout [String]
) -> [String: String]? {
    do {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        )
        guard let dictionary = propertyList as? [String: Any] else {
            errors.append("[\(label)] top level must be a string dictionary")
            return nil
        }

        var strings: [String: String] = [:]
        for key in dictionary.keys.sorted() {
            guard let value = dictionary[key] as? String else {
                errors.append("[\(label)] key \(key.debugDescription) has a non-string value")
                continue
            }
            strings[key] = value
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("[\(label)] key \(key.debugDescription) has an empty value")
            }
        }
        return strings
    } catch {
        errors.append("[\(label)] cannot parse .strings file: \(error.localizedDescription)")
        return nil
    }
}

private func writeErrors(_ errors: [String]) {
    let lines = ["Localization validation failed with \(errors.count) error(s):"]
        + errors.map { "error: \($0)" }
    let output = lines.joined(separator: "\n") + "\n"
    FileHandle.standardError.write(Data(output.utf8))
}

private func explicitLocalizationKeys(
    in sourcesDirectory: URL,
    errors: inout [String]
) -> [String: [String]] {
    let expression = try! NSRegularExpression(
        pattern: #"L10n\.(?:text|format)\s*\(\s*\"((?:\\.|[^\"\\])*)\""#,
        options: [.dotMatchesLineSeparators]
    )
    guard let enumerator = FileManager.default.enumerator(
        at: sourcesDirectory,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
        errors.append("cannot enumerate sources: \(sourcesDirectory.path)")
        return [:]
    }

    var locationsByKey: [String: [String]] = [:]
    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        guard let source = try? String(contentsOf: fileURL, encoding: .utf8) else {
            errors.append("cannot read source: \(fileURL.path)")
            continue
        }
        let nsSource = source as NSString
        let matches = expression.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        )
        for match in matches {
            let rawKey = nsSource.substring(with: match.range(at: 1))
            let snippet = "\"value\" = \"\(rawKey)\";"
            guard let data = snippet.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data,
                      options: [],
                      format: nil
                  ) as? [String: String],
                  let key = plist["value"] else {
                errors.append("cannot decode L10n key in \(fileURL.lastPathComponent): \(rawKey)")
                continue
            }
            let prefix = nsSource.substring(to: match.range.location)
            let line = prefix.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
            locationsByKey[key, default: []].append("\(fileURL.lastPathComponent):\(line)")
        }
    }
    return locationsByKey
}

let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let repositoryRoot = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let localizationsRoot = repositoryRoot
    .appendingPathComponent("Resources", isDirectory: true)
    .appendingPathComponent("Localizations", isDirectory: true)

var errors: [String] = []
var tablesByLocale: [String: Set<String>] = [:]

for localeID in localeIDs {
    let directory = localizationsRoot
        .appendingPathComponent("\(localeID).lproj", isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        errors.append("missing localization directory: \(directory.path)")
        tablesByLocale[localeID] = []
        continue
    }

    do {
        let tables = try relativeStringsFiles(in: directory)
        tablesByLocale[localeID] = tables
        if tables.isEmpty {
            errors.append("[\(localeID)] contains no .strings tables")
        }
        for table in requiredTables.subtracting(tables).sorted() {
            errors.append("[\(localeID)] missing required table: \(table)")
        }
    } catch {
        errors.append("[\(localeID)] \(error.localizedDescription)")
        tablesByLocale[localeID] = []
    }
}

let zhTables = tablesByLocale["zh-Hans"] ?? []
let enTables = tablesByLocale["en"] ?? []

for table in zhTables.subtracting(enTables).sorted() {
    errors.append("[en] missing table present in zh-Hans: \(table)")
}
for table in enTables.subtracting(zhTables).sorted() {
    errors.append("[zh-Hans] missing table present in en: \(table)")
}

let allTables = zhTables.union(enTables).sorted()
var checkedKeyCount = 0

for table in allTables {
    var stringsByLocale: [String: [String: String]] = [:]

    for localeID in localeIDs where tablesByLocale[localeID]?.contains(table) == true {
        let url = localizationsRoot
            .appendingPathComponent("\(localeID).lproj", isDirectory: true)
            .appendingPathComponent(table)
        if let strings = loadStrings(
            at: url,
            label: "\(localeID)/\(table)",
            errors: &errors
        ) {
            stringsByLocale[localeID] = strings
        }
    }

    guard let zhStrings = stringsByLocale["zh-Hans"],
          let enStrings = stringsByLocale["en"] else {
        continue
    }

    let zhKeys = Set(zhStrings.keys)
    let enKeys = Set(enStrings.keys)
    for key in zhKeys.subtracting(enKeys).sorted() {
        errors.append("[en/\(table)] missing key \(key.debugDescription)")
    }
    for key in enKeys.subtracting(zhKeys).sorted() {
        errors.append("[zh-Hans/\(table)] missing key \(key.debugDescription)")
    }

    for key in zhKeys.intersection(enKeys).sorted() {
        checkedKeyCount += 1
        if enStrings[key]!.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
            errors.append(
                "[en/\(table)] key \(key.debugDescription) still contains Han characters"
            )
        }
        let zhSignature = parseFormatSignature(zhStrings[key]!)
        let enSignature = parseFormatSignature(enStrings[key]!)

        for problem in zhSignature.problems {
            errors.append("[zh-Hans/\(table)] key \(key.debugDescription): \(problem)")
        }
        for problem in enSignature.problems {
            errors.append("[en/\(table)] key \(key.debugDescription): \(problem)")
        }

        if zhSignature.conversionCount != enSignature.conversionCount
            || zhSignature.argumentUses != enSignature.argumentUses {
            errors.append(
                "[\(table)] key \(key.debugDescription) has incompatible printf placeholders\n"
                    + "  zh-Hans: \(zhSignature.description)\n"
                    + "  en:      \(enSignature.description)"
            )
        }
    }
}

let sourceChecks = [
    (target: "CharkerApp", table: "Localizable.strings"),
    (target: "CharkerCore", table: "Core.strings"),
]
for check in sourceChecks {
    let sources = repositoryRoot
        .appendingPathComponent("Sources", isDirectory: true)
        .appendingPathComponent(check.target, isDirectory: true)
    let explicitKeys = explicitLocalizationKeys(in: sources, errors: &errors)
    let englishTableURL = localizationsRoot
        .appendingPathComponent("en.lproj", isDirectory: true)
        .appendingPathComponent(check.table)
    guard FileManager.default.fileExists(atPath: englishTableURL.path),
          let englishTable = loadStrings(
              at: englishTableURL,
              label: "en/\(check.table)",
              errors: &errors
          ) else {
        continue
    }
    for key in explicitKeys.keys.sorted() where englishTable[key] == nil {
        let locations = explicitKeys[key]!.joined(separator: ", ")
        errors.append(
            "[en/\(check.table)] missing explicit L10n key "
                + "\(key.debugDescription) used at \(locations)"
        )
    }
}

if !errors.isEmpty {
    writeErrors(errors)
    exit(EXIT_FAILURE)
}

print(
    "Localization validation passed: \(allTables.count) table(s), "
        + "\(checkedKeyCount) shared key(s), languages \(localeIDs.joined(separator: ", "))."
)
