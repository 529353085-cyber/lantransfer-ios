//
//  PathSanitizer.swift
//  局域网快传
//
//  文件名 / 相对路径清洗 —— 对齐桌面 SaveDirResolver.sanitizeFileName 与
//  FolderSource.sanitizeRelativePath，防止路径穿越。iOS 沙盒下同样必须校验，
//  因为相对路径用于 Documents 内重建目录树。
//

import Foundation

enum PathSanitizer {
    /// 清洗文件名：移除路径分隔符与非法字符，截断到 180 字符。
    /// 与桌面 sanitizeFileName 的正则 [\\/:*?"<>|\r\n] 完全一致。
    static func sanitizeFileName(_ name: String) -> String {
        var cleaned = ""
        for ch in name {
            if ch == "\\" || ch == "/" || ch == ":" || ch == "*" || ch == "?"
                || ch == "\"" || ch == "<" || ch == ">" || ch == "|"
                || ch == "\r" || ch == "\n" {
                cleaned.append("_")
            } else {
                cleaned.append(ch)
            }
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "未命名文件" }
        return String(cleaned.prefix(180))
    }

    /// 逐段清洗相对路径。返回 nil 表示非法（调用方必须拒绝，不得回退到根目录）。
    /// 拒绝：空串、绝对路径、Windows 盘符、控制字符、空段、'.'、'..'。
    static func sanitizeRelativePath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        // 控制字符 U+0000-U+001F 与 U+007F
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            if v <= 0x1F || v == 0x7F { return nil }
        }
        if raw.hasPrefix("/") || raw.hasPrefix("\\") { return nil }
        // Windows 盘符 X:
        if raw.count >= 2 {
            let first = raw.first!
            let second = raw[raw.index(after: raw.startIndex)]
            if first.isLetter && second == ":" { return nil }
        }

        let segments = raw.split(separator: "/", omittingEmptySubsequences: false)
            .flatMap { $0.split(separator: "\\", omittingEmptySubsequences: false) }
        var cleaned: [String] = []
        for seg in segments {
            let s = String(seg)
            if s.isEmpty || s == "." || s == ".." { return nil }
            let safe = sanitizeFileName(s)
            if safe.isEmpty || safe == "." || safe == ".." { return nil }
            cleaned.append(safe)
        }
        return cleaned.joined(separator: "/")
    }

    /// 计算接收落点：有相对路径时按目录树重建，否则 basename 落根目录。
    /// 返回 (目标目录, 安全文件名, 最终路径, part路径)；非法返回 nil。
    static func resolveTargets(
        saveDir: URL,
        name: String,
        relativePath: String?,
        fileId: String
    ) -> (targetDir: URL, safeName: String, finalPath: URL, partPath: URL)? {
        let root = saveDir.standardizedFileURL
        let safeName: String
        let targetDir: URL
        if let relativePath {
            guard let safeRelative = sanitizeRelativePath(relativePath) else { return nil }
            let segments = safeRelative.split(separator: "/").map(String.init)
            guard let last = segments.last else { return nil }
            safeName = last
            var dir = root
            for segment in segments.dropLast() {
                dir = dir.appendingPathComponent(segment, isDirectory: true)
            }
            targetDir = dir
        } else {
            safeName = sanitizeFileName(name)
            targetDir = root
        }
        let finalPath = targetDir.appendingPathComponent(safeName, isDirectory: false)
        let partPath = targetDir.appendingPathComponent("\(safeName).\(fileId).part", isDirectory: false)

        // containment 校验：目标必须在 saveDir 之内。
        let rootPath = root.path
        for candidate in [finalPath, partPath] {
            let path = candidate.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { return nil }
        }
        return (targetDir, safeName, finalPath, partPath)
    }

    /// 为文件夹根名生成不覆盖已有目录的目标路径，与桌面 uniqueFolderPath 一致。
    static func uniqueFolderPath(saveDir: URL, rootName: String) -> URL {
        let root = saveDir.standardizedFileURL
        let base = root.appendingPathComponent(sanitizeFileName(rootName), isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) { return base }
        var index = 2
        while true {
            let candidate = root.appendingPathComponent("\(rootName) (\(index))", isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
