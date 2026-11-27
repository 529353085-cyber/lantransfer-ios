//
//  FolderBundle.swift
//  局域网快传
//
//  LFTB1 文件夹整包：把所选文件夹作为「一个文件」送过既有分块/校验状态机，
//  接收端校验通过后一次性解包为原目录树。与桌面 FolderBundle.ts / Android FolderBundle.kt 一致。
//
//  布局（所有整数 big-endian，不压缩，流式支持 ≥2GB）：
//  [8B MAGIC="LFTB1\r\n\u0000"][文件裸字节按 manifest 顺序拼接]
//  [manifest JSON][4B manifestLength BE][8B FOOTER="LFTBEND1"]
//

import Foundation
import CryptoKit

enum FolderBundleError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let m): return m }
    }
}

struct BundleEntry: Codable {
    var path: String
    var size: Int64
    var sha256: String
}

struct BundleManifest: Codable {
    var version: Int = 1
    var rootName: String
    var totalSize: Int64
    var files: [BundleEntry]
    var dirs: [String]
}

struct BuiltBundle {
    var bundlePath: URL
    var size: Int64
    var sha256: String
    var manifest: BundleManifest
}

struct ExtractedBundle {
    var folderPath: URL
    var fileCount: Int
}

enum FolderBundle {
    /// MAGIC 恰好 8 字节："LFTB1\r\n\0"。
    static let magic = Data([0x4C, 0x46, 0x54, 0x42, 0x31, 0x0D, 0x0A, 0x00])
    static let footer = Data("LFTBEND1".utf8)
    static let maxManifestBytes = 64 * 1024 * 1024

    // MARK: - 打包

    /// 把文件夹打包为临时 LFTB1 文件（系统临时目录），返回包路径、大小、整包 SHA-256 与清单。
    static func build(folderURL: URL, tempDir: URL) throws -> BuiltBundle {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw FolderBundleError.invalid("不是文件夹：\(folderURL.lastPathComponent)")
        }

        // 收集普通文件与目录（跳过符号链接），稳定排序保证可复现。
        var files: [(url: URL, relative: String)] = []
        var dirs: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        while let itemURL = enumerator?.nextObject() as? URL {
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if resourceValues?.isSymbolicLink == true { continue }
            let relative = relativePath(of: itemURL, root: folderURL)
            guard let relative, let safe = PathSanitizer.sanitizeRelativePath(relative) else { continue }
            if resourceValues?.isDirectory == true {
                dirs.append(safe)
            } else {
                files.append((itemURL, safe))
            }
        }
        files.sort { $0.relative < $1.relative }
        dirs.sort()

        // 文件名冲突检测（大小写不敏感）。
        var seen = Set<String>()
        for item in files {
            let key = item.relative.lowercased()
            guard seen.insert(key).inserted else {
                throw FolderBundleError.invalid("文件名冲突：\(item.relative)")
            }
        }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let bundleURL = tempDir.appendingPathComponent("folder-\(UUID().uuidString).lftb", isDirectory: false)
        guard FileManager.default.createFile(atPath: bundleURL.path, contents: nil) else {
            throw FolderBundleError.invalid("无法创建临时包文件")
        }
        let output = try FileHandle(forWritingTo: bundleURL)
        defer { try? output.close() }

        var bundleHasher = SHA256()
        var writeOffset: Int64 = 0
        // 写 MAGIC
        try output.write(contentsOf: magic)
        bundleHasher.update(data: magic)
        writeOffset += Int64(magic.count)

        var manifestFiles: [BundleEntry] = []
        var totalSize: Int64 = 0
        for item in files {
            let size = try fileSize(item.url)
            var entryHasher = SHA256()
            let input = try FileHandle(forReadingFrom: item.url)
            defer { try? input.close() }
            var remaining = size
            while remaining > 0 {
                let chunk = try input.read(upToCount: Int(min(Int64(DISK_IO_BUFFER_SIZE), remaining))) ?? Data()
                if chunk.isEmpty { throw FolderBundleError.invalid("源文件提前结束：\(item.relative)") }
                entryHasher.update(data: chunk)
                bundleHasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            manifestFiles.append(BundleEntry(path: item.relative, size: size, sha256: entryHasher.finalize().hexString))
            totalSize += size
        }

        let manifest = BundleManifest(
            version: 1,
            rootName: PathSanitizer.sanitizeFileName(folderURL.lastPathComponent),
            totalSize: totalSize,
            files: manifestFiles,
            dirs: dirs
        )
        let manifestBytes = try JSONEncoder().encode(manifest)
        guard manifestBytes.count <= maxManifestBytes else {
            throw FolderBundleError.invalid("文件夹条目过多，清单超出上限")
        }
        bundleHasher.update(data: manifestBytes)
        try output.write(contentsOf: manifestBytes)

        var lengthBytes = BE.u32(UInt32(manifestBytes.count))
        bundleHasher.update(data: lengthBytes)
        try output.write(contentsOf: lengthBytes)
        bundleHasher.update(data: footer)
        try output.write(contentsOf: footer)
        try output.synchronize()

        let size = writeOffset + totalSize + Int64(manifestBytes.count) + 4 + Int64(footer.count)
        return BuiltBundle(
            bundlePath: bundleURL,
            size: size,
            sha256: bundleHasher.finalize().hexString,
            manifest: manifest
        )
    }

    // MARK: - 解包

    /// 读取并校验包尾清单。
    private static func readManifest(handle: FileHandle, fileSize: Int64) throws -> BundleManifest {
        let tailLength = 4 + footer.count
        guard fileSize >= Int64(magic.count + tailLength) else {
            throw FolderBundleError.invalid("文件夹包过小")
        }
        try handle.seek(toOffset: 0)
        let magicData = try handle.read(upToCount: magic.count) ?? Data()
        guard magicData == magic else { throw FolderBundleError.invalid("文件夹包格式不正确") }

        try handle.seek(toOffset: UInt64(fileSize - Int64(tailLength)))
        let tail = try handle.read(upToCount: tailLength) ?? Data()
        guard tail.count == tailLength else { throw FolderBundleError.invalid("文件夹包尾部损坏") }
        let tailFooter = Data(tail.dropFirst(4))
        guard tailFooter == footer else { throw FolderBundleError.invalid("文件夹包尾部损坏") }
        let manifestLength = Int(BE.u32(tail, at: 0))
        guard manifestLength > 0, manifestLength <= maxManifestBytes else {
            throw FolderBundleError.invalid("文件夹包清单长度非法")
        }
        let dataEnd = fileSize - Int64(tailLength) - Int64(manifestLength)
        guard dataEnd >= Int64(magic.count) else { throw FolderBundleError.invalid("文件夹包清单越界") }

        try handle.seek(toOffset: UInt64(dataEnd))
        let manifestBytes = try handle.read(upToCount: manifestLength) ?? Data()
        guard let manifest = try? JSONDecoder().decode(BundleManifest.self, from: manifestBytes) else {
            throw FolderBundleError.invalid("文件夹包清单不是合法 JSON")
        }
        guard manifest.version == 1, !manifest.rootName.isEmpty, !manifest.files.isEmpty || manifest.dirs.isEmpty else {
            throw FolderBundleError.invalid("文件夹包清单字段缺失")
        }
        let expectedRoot = PathSanitizer.sanitizeFileName(manifest.rootName)
        guard expectedRoot == manifest.rootName else { throw FolderBundleError.invalid("文件夹包根目录名非法") }

        var seen = Set<String>()
        var sum: Int64 = 0
        for entry in manifest.files {
            guard let safe = PathSanitizer.sanitizeRelativePath(entry.path), safe == entry.path else {
                throw FolderBundleError.invalid("包内文件路径非法：\(entry.path)")
            }
            guard seen.insert(safe.lowercased()).inserted else {
                throw FolderBundleError.invalid("包内文件名冲突：\(safe)")
            }
            guard entry.size >= 0, entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw FolderBundleError.invalid("包内文件元数据非法：\(safe)")
            }
            sum += entry.size
        }
        guard sum == dataEnd - Int64(magic.count) else {
            throw FolderBundleError.invalid("文件夹包数据长度与清单不符")
        }
        var validated = manifest
        validated.totalSize = sum
        return validated
    }

    /// 把已校验的 LFTB1 包解包为 saveDir/rootName 目录，逐文件校验 SHA-256。
    static func extract(
        bundlePath: URL,
        saveDir: URL,
        expectedRootName: String? = nil,
        expectedFileCount: Int? = nil
    ) throws -> ExtractedBundle {
        let handle = try FileHandle(forReadingFrom: bundlePath)
        defer { try? handle.close() }
        let attrs = try FileManager.default.attributesOfItem(atPath: bundlePath.path)
        let fileSize = attrs[.size] as? NSNumber ?? 0
        let manifest = try readManifest(handle: handle, fileSize: fileSize.int64Value)
        if let root = expectedRootName,
           PathSanitizer.sanitizeFileName(root) != manifest.rootName {
            throw FolderBundleError.invalid("文件夹包与传输元数据不一致")
        }
        if let count = expectedFileCount, count != manifest.files.count {
            throw FolderBundleError.invalid("文件夹包内文件数量不一致")
        }

        let folderURL = PathSanitizer.uniqueFolderPath(saveDir: saveDir, rootName: manifest.rootName)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        for dir in manifest.dirs {
            guard let safe = PathSanitizer.sanitizeRelativePath(dir) else {
                throw FolderBundleError.invalid("包内目录越界：\(dir)")
            }
            let target = safe.split(separator: "/").reduce(folderURL) { url, seg in
                url.appendingPathComponent(String(seg), isDirectory: true)
            }
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }

        var offset = Int64(magic.count)
        for entry in manifest.files {
            let segments = entry.path.split(separator: "/").map(String.init)
            guard let safeName = segments.last else { throw FolderBundleError.invalid("包内文件路径非法") }
            let targetDir = segments.dropLast().reduce(folderURL) { url, seg in
                url.appendingPathComponent(seg, isDirectory: true)
            }
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let targetURL = targetDir.appendingPathComponent(safeName, isDirectory: false)
            FileManager.default.createFile(atPath: targetURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: targetURL)
            defer { try? output.close() }

            var hasher = SHA256()
            var remaining = entry.size
            while remaining > 0 {
                let want = Int(min(Int64(DISK_IO_BUFFER_SIZE), remaining))
                try handle.seek(toOffset: UInt64(offset))
                let chunk = try handle.read(upToCount: want) ?? Data()
                if chunk.isEmpty { throw FolderBundleError.invalid("文件夹包提前结束：\(entry.path)") }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                offset += Int64(chunk.count)
                remaining -= Int64(chunk.count)
            }
            try output.synchronize()
            guard hasher.finalize().hexString.lowercased() == entry.sha256.lowercased() else {
                throw FolderBundleError.invalid("包内文件校验失败：\(entry.path)")
            }
        }
        return ExtractedBundle(folderPath: folderURL, fileCount: manifest.files.count)
    }

    // MARK: - 工具

    private static func relativePath(of url: URL, root: URL) -> String? {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}
