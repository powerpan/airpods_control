#!/usr/bin/env swift
import Foundation

// Convert project Markdown with the system's ICU transliterator. No package
// download is required. Content review and anonymisation remain separate work.
enum Mode { case check, write }

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
用法：swift script/convert_docs.swift [--check | --write] [--root PATH]
  --check  檢查是否仍有可轉換的簡體字；有變更時傳回 1（預設）
  --write  原地轉換專案 Markdown 文件為繁體中文
  --root   指定專案根目錄；預設為目前工作目錄

略過隱藏目錄、建置產物、套件和第三方相依目錄；不處理符號連結。
"""

var mode = Mode.check
var explicitMode = false
var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--help", "-h": print(usage); exit(0)
    case "--check", "--write":
        guard !explicitMode else { fail("請只指定一種執行模式。") }
        explicitMode = true
        mode = argument == "--write" ? .write : .check
    case "--root":
        guard !arguments.isEmpty else { fail("--root 需要目錄參數。") }
        root = URL(fileURLWithPath: arguments.removeFirst(), isDirectory: true)
    default: fail(usage)
    }
}

root = root.standardizedFileURL.resolvingSymlinksInPath()
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    fail("專案根目錄不存在或不是目錄。")
}

let excluded = Set(["build", "DerivedData", "node_modules", "vendor", "Pods", "Carthage"])
let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
guard let enumerator = FileManager.default.enumerator(
    at: root, includingPropertiesForKeys: keys,
    options: [.skipsHiddenFiles, .skipsPackageDescendants],
    errorHandler: { _, _ in fail("無法完整讀取專案目錄。") }
) else { fail("無法列出專案文件。") }

var documents: [URL] = []
for case let url as URL in enumerator {
    guard let values = try? url.resourceValues(forKeys: Set(keys)) else { fail("無法檢查專案文件。") }
    if values.isSymbolicLink == true {
        // DirectoryEnumerator does not descend into symbolic links. Calling
        // skipDescendants for a leaf can affect a later sibling directory.
        continue
    }
    if values.isDirectory == true, excluded.contains(url.lastPathComponent) {
        enumerator.skipDescendants()
        continue
    }
    if values.isRegularFile == true, ["md", "markdown"].contains(url.pathExtension.lowercased()) {
        documents.append(url)
    }
}

let transform = StringTransform(rawValue: "Hans-Hant")
// ICU cannot resolve every ambiguous character from context. Keep a small,
// explicit list of technical phrases used by the project documentation.
let phraseCorrections = [
    ("校准", "校準"), ("對准", "對準"), ("恢複", "恢復"),
    ("重復", "重複"), ("錄制", "錄製"), ("標注", "標註"),
    ("復核", "複核"), ("復用", "複用"), ("注明", "註明"), ("設置里", "設置裡")
]
let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
var changed = 0
for url in documents.sorted(by: { $0.path < $1.path }) {
    let relative = String(url.path.dropFirst(prefix.count))
    guard let original = try? String(contentsOf: url, encoding: .utf8) else {
        fail("無法讀取 UTF-8 文件：\(relative)")
    }
    guard var converted = original.applyingTransform(transform, reverse: false) else {
        fail("系統不支援簡繁轉換。")
    }
    for (source, replacement) in phraseCorrections {
        converted = converted.replacingOccurrences(of: source, with: replacement)
    }
    guard converted != original else { continue }
    changed += 1
    if mode == .write {
        do { try converted.write(to: url, atomically: true, encoding: .utf8) }
        catch { fail("無法寫入文件：\(relative)") }
        print("已轉換：\(relative)")
    } else {
        print("待轉換：\(relative)")
    }
}

print("檢查 \(documents.count) 份文件；\(changed) 份\(mode == .write ? "已轉換" : "需要轉換")。")
exit(mode == .check && changed > 0 ? 1 : 0)
