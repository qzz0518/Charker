// Turn `cargo metadata` for the Matter helper into the license notice that
// ships in Resources/Licenses. Run through `mise run matter-licenses`.
//
// Crates reached from charker-matter through normal dependencies, without
// entering a procedural macro, are linked into the binary. Each gets one
// license elected from its SPDX expression: Apache-2.0 when offered, else MIT,
// else BSD-3-Clause. Anything else stops the script for a human to review.
// Apache-2.0 needs one shared copy of its text; MIT and BSD-3-Clause need each
// crate's own copyright notice, so their license files are copied verbatim.
import CryptoKit
import Foundation

typealias JSON = [String: Any]

func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data("matter-licenses: \(message)\n".utf8))
	exit(1)
}

guard let metadata = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? JSON else {
	fail("stdin is not cargo metadata JSON")
}
let workspace = URL(fileURLWithPath: metadata["workspace_root"] as! String)
let packages = Dictionary(uniqueKeysWithValues: (metadata["packages"] as! [JSON]).map { ($0["id"] as! String, $0) })
let resolve = metadata["resolve"] as! JSON
let nodes = Dictionary(uniqueKeysWithValues: (resolve["nodes"] as! [JSON]).map { ($0["id"] as! String, $0) })
let root = resolve["root"] as! String

func isProcMacro(_ id: String) -> Bool {
	(packages[id]!["targets"] as! [JSON]).contains { ($0["kind"] as! [String]).contains("proc-macro") }
}

var linked = Set<String>()
var pending = [root]
while let id = pending.popLast() {
	guard !isProcMacro(id), linked.insert(id).inserted else { continue }
	for dep in nodes[id]!["deps"] as! [JSON] where (dep["dep_kinds"] as! [JSON]).contains(where: { $0["kind"] is NSNull }) {
		pending.append(dep["pkg"] as! String)
	}
}
linked.remove(root)

func name(_ id: String) -> String {
	"\(packages[id]!["name"] as! String) \(packages[id]!["version"] as! String)"
}

func origin(_ id: String) -> String {
	guard let source = packages[id]!["source"] as? String, source.hasPrefix("git+"),
		let hash = source.split(separator: "#").last else { return "" }
	return "  (git \(source.dropFirst(4).split(separator: "?")[0]) @ \(hash.prefix(7)))"
}

func licenseFiles(_ id: String) -> [URL] {
	let directory = URL(fileURLWithPath: packages[id]!["manifest_path"] as! String).deletingLastPathComponent()
	let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
	return names.filter { $0.uppercased().hasPrefix("LICENSE") }.sorted().map { directory.appendingPathComponent($0) }
}

func elect(_ id: String) -> String {
	let expression = packages[id]!["license"] as? String ?? ""
	if expression.contains("(") || expression.contains(" AND ") { fail("\(name(id)) needs review: \(expression)") }
	let choices = expression.replacingOccurrences(of: "/", with: " OR ").components(separatedBy: " OR ")
	guard let license = ["Apache-2.0", "MIT", "BSD-3-Clause"].first(where: choices.contains) else {
		fail("\(name(id)) needs review: \(expression)")
	}
	return license
}

// MIT and BSD-3-Clause: the crate's own license file. A crate that ships none
// gets the MIT text from Charker's LICENSE with its Cargo authors as holders.
func text(_ id: String, _ license: String) -> String {
	let files = licenseFiles(id)
	let token = license == "MIT" ? "MIT" : "BSD"
	let file = files.first { $0.lastPathComponent.uppercased().contains(token) }
		?? (packages[id]!["license"] as? String == license && files.count == 1 ? files[0] : nil)
	if let file { return try! String(contentsOf: file, encoding: .utf8) }
	guard license == "MIT" else { fail("\(name(id)) has no \(license) license file") }
	let authors = (packages[id]!["authors"] as! [String])
		.map { $0.replacingOccurrences(of: #"\s*<[^>]*>"#, with: "", options: .regularExpression) }
	let template = try! String(contentsOf: workspace.deletingLastPathComponent().appendingPathComponent("LICENSE"), encoding: .utf8)
	let holders = "Copyright (c) " + authors.joined(separator: ", ")
	return template.replacingOccurrences(of: #"(?m)^Copyright .*$"#, with: holders, options: .regularExpression)
}

let byName = { (a: String, b: String) in name(a).localizedStandardCompare(name(b)) == .orderedAscending }
let linkedIDs = linked.sorted(by: byName)
let buildIDs = packages.keys.filter { $0 != root && !linked.contains($0) }.sorted(by: byName)
let width = packages.keys.map { name($0).count }.max()! + 2
func row(_ id: String, _ suffix: String = "") -> String {
	let license = packages[id]!["license"] as? String ?? ""
	return "  " + name(id).padding(toLength: width, withPad: " ", startingAt: 0) + license + suffix + origin(id)
}
let rule = String(repeating: "=", count: 78)
let lockHash = SHA256.hash(data: try! Data(contentsOf: workspace.appendingPathComponent("Cargo.lock")))
	.map { String(format: "%02x", $0) }.joined()

var out = """
charker-matter: third-party Rust crates

charker-matter (Contents/MacOS/charker-matter) is Charker's Apple Home bridge.
Its own code is part of Charker and released under the MIT License (LICENSE).
This file is generated by Scripts/matter-licenses.swift from `cargo metadata`
for aarch64-apple-darwin and x86_64-apple-darwin. Do not edit it by hand;
run `mise run matter-licenses` after changing Matter/Cargo.lock.
Cargo.lock SHA-256: \(lockHash)

Linked into charker-matter (\(linkedIDs.count) crates). Where a crate offers a
choice, Charker uses it under the license after "->".


"""
out += linkedIDs.map { id in row(id, " -> \(elect(id))") }.joined(separator: "\n")
out += """


Build time only (\(buildIDs.count) crates): build scripts, procedural macros and
their dependencies. They run while compiling and are not part of the binary.


"""
out += buildIDs.map { row($0) }.joined(separator: "\n")

guard let apacheID = linkedIDs.first(where: { packages[$0]!["name"] as? String == "rs-matter" }) else {
	fail("rs-matter is not linked")
}
out += "\n\n\(rule)\nApache License 2.0: every linked crate shown \"-> Apache-2.0\"\n\(rule)\n\n"
out += try! String(contentsOf: licenseFiles(apacheID)[0], encoding: .utf8)

// One section per distinct notice, so crates by the same holders share it.
var notices: [(key: String, text: String, license: String, crates: [String])] = []
for id in linkedIDs where elect(id) != "Apache-2.0" {
	let body = text(id, elect(id))
	let key = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
	if let index = notices.firstIndex(where: { $0.key == key }) {
		notices[index].crates.append(name(id))
	} else {
		notices.append((key, body, elect(id), [name(id)]))
	}
}
for notice in notices {
	out += "\n\(rule)\n\(notice.license): \(notice.crates.joined(separator: ", "))\n\(rule)\n\n"
	out += notice.text.hasSuffix("\n") ? notice.text : notice.text + "\n"
}
print(out, terminator: "")
