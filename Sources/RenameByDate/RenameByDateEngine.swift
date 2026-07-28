import Foundation
import os

public struct RenameByDateConfig {
    public let inputFolder: String
    public let outputFolder: String?
    public let recursive: Bool
    public let stamp: Bool
    public let apply: Bool
    public let prefixFormat: String

    public init(inputFolder: String, outputFolder: String? = nil, recursive: Bool = false, stamp: Bool = false, apply: Bool = false, prefixFormat: String = "yyyyMMdd") {
        self.inputFolder = inputFolder
        self.outputFolder = outputFolder
        self.recursive = recursive
        self.stamp = stamp
        self.apply = apply
        self.prefixFormat = prefixFormat
    }
}

public struct PlannedRename {
    public let old: String
    public let new: String
    public let note: String

    public init(old: String, new: String, note: String) {
        self.old = old
        self.new = new
        self.note = note
    }
}

public struct RunResult {
    public let planned: [PlannedRename]
    public let skipped: [String]
    public let failed: [String]
    public let stamped: [String]
    public let outFolder: String

    public init(planned: [PlannedRename], skipped: [String], failed: [String], stamped: [String], outFolder: String) {
        self.planned = planned
        self.skipped = skipped
        self.failed = failed
        self.stamped = stamped
        self.outFolder = outFolder
    }
}

public protocol FileSystem {
    func exists(_ path: String) -> Bool
    func list(_ path: String) throws -> [String]
    func copy(from src: String, to dst: String) throws
    func move(from src: String, to dst: String) throws
    func makeDir(_ path: String) throws
    func setAttributes(_ attributes: [FileAttributeKey : Any], ofItemAtPath path: String) throws
    func enumerateRecursively(_ path: String) throws -> [String]
}

public final class DefaultFileSystem: FileSystem {
    private let fm = FileManager.default

    public init() {}

    public func exists(_ path: String) -> Bool {
        return fm.fileExists(atPath: path)
    }

    public func list(_ path: String) throws -> [String] {
        return try fm.contentsOfDirectory(atPath: path)
    }

    public func copy(from src: String, to dst: String) throws {
        try fm.copyItem(atPath: src, toPath: dst)
    }

    public func move(from src: String, to dst: String) throws {
        try fm.moveItem(atPath: src, toPath: dst)
    }

    public func makeDir(_ path: String) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
    }

    public func setAttributes(_ attributes: [FileAttributeKey : Any], ofItemAtPath path: String) throws {
        try fm.setAttributes(attributes, ofItemAtPath: path)
    }

    public func enumerateRecursively(_ path: String) throws -> [String] {
        var result: [String] = []
        let enumerator = fm.enumerator(atPath: path)
        while let element = enumerator?.nextObject() as? String {
            result.append((path as NSString).appendingPathComponent(element))
        }
        return result
    }
}

public final class RenameByDateEngine {
    let fs: FileSystem

    /// Unified logging; view with:
    /// log stream --predicate 'subsystem == "se.redseven.RenameByDate"' --level debug
    private let logger = Logger(subsystem: "se.redseven.RenameByDate", category: "engine")

    public init(fs: FileSystem = DefaultFileSystem()) {
        self.fs = fs
    }

    public func run(config: RenameByDateConfig) throws -> RunResult {
        // Resolve input folder
        let inputFolder = (config.inputFolder as NSString).expandingTildeInPath
        guard fs.exists(inputFolder) else {
            throw NSError(domain: "RenameByDateEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Input folder does not exist: \(inputFolder)"])
        }

        // Resolve output folder
        let outFolder: String
        if let output = config.outputFolder {
            outFolder = (output as NSString).expandingTildeInPath
            if !fs.exists(outFolder) {
                try fs.makeDir(outFolder)
            }
        } else {
            outFolder = inputFolder
        }

        // Enumerate pdf files
        let allFiles: [String]
        if config.recursive {
            allFiles = try fs.enumerateRecursively(inputFolder)
        } else {
            let names = try fs.list(inputFolder)
            allFiles = names.map { (inputFolder as NSString).appendingPathComponent($0) }
        }

        let pdfFiles = allFiles.filter { $0.lowercased().hasSuffix(".pdf") }

        logger.info("Run started: input=\(inputFolder, privacy: .public) output=\(outFolder, privacy: .public) recursive=\(config.recursive) apply=\(config.apply) prefix=\(config.prefixFormat, privacy: .public) pdfCount=\(pdfFiles.count)")

        var planned: [PlannedRename] = []
        var skipped: [String] = []
        var failed: [String] = []
        var stamped: [String] = []

        // Names claimed by earlier files in this run, so planned targets stay
        // unique even in a dry run where nothing is written to disk.
        var reservedNames = Set<String>()

        // Plan renames and optionally perform them
        for oldPath in pdfFiles {
            let fileName = (oldPath as NSString).lastPathComponent

            // Already named with a leading date
            if DateExtraction.hasDatePrefix(fileName) {
                logger.debug("Skipping (already has date prefix): \(fileName, privacy: .public)")
                skipped.append(oldPath)
                continue
            }

            let stem = (fileName as NSString).deletingPathExtension
            let text = DateExtraction.extractText(fromPDFAt: oldPath)

            // Prefer a date embedded in the filename, then one found in the PDF text
            var vendorFallback = stem
            var date: Date?
            if let hit = DateExtraction.date(inFileName: stem) {
                date = hit.date
                vendorFallback = hit.remainder
            } else if let text {
                date = DateExtraction.bestDate(inText: text)
            }
            guard let date else {
                logger.debug("Skipping (no date found): \(fileName, privacy: .public)")
                skipped.append(oldPath)
                continue
            }

            // Compose new name
            let vendor = DateExtraction.vendorName(fromText: text, fallback: vendorFallback)
            let ref = DateExtraction.reference(fromText: text) ?? ""
            let dateString = DateExtraction.format(date, pattern: config.prefixFormat)
            let newName = uniqueName(vendor: vendor, ref: ref, dateString: dateString, outputFolder: outFolder, reserved: &reservedNames)
            let newPath = (outFolder as NSString).appendingPathComponent(newName)

            logger.debug("Planned: \(fileName, privacy: .public) -> \(newName, privacy: .public)")
            planned.append(PlannedRename(old: oldPath, new: newPath, note: "Renamed by date"))

            if config.apply {
                do {
                    if inputFolder != outFolder {
                        try fs.copy(from: oldPath, to: newPath)
                    } else {
                        try fs.move(from: oldPath, to: newPath)
                    }

                    if config.stamp {
                        // Stamp the file's dates with the extracted document date
                        try fs.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: newPath)
                        stamped.append(newPath)
                    }
                } catch {
                    logger.error("Rename failed: \(oldPath, privacy: .public) -> \(newPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    failed.append(oldPath)
                }
            }
        }

        logger.info("Run finished: planned=\(planned.count) skipped=\(skipped.count) failed=\(failed.count) stamped=\(stamped.count)")
        return RunResult(planned: planned, skipped: skipped, failed: failed, stamped: stamped, outFolder: outFolder)
    }

    // MARK: - Collision handling

    // Builds a destination filename that collides neither with files on disk
    // nor with names already claimed earlier in this run. Reserved names are
    // compared case-insensitively because the default macOS file system is
    // case-insensitive, so "Acme.pdf" and "acme.pdf" would still collide.
    func uniqueName(vendor: String, ref: String, dateString: String, outputFolder: String, reserved: inout Set<String>) -> String {
        let stem = [dateString, vendor, ref]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "/", with: "-")

        var candidate = stem + ".pdf"
        var counter = 1
        while isTaken(candidate, in: outputFolder, reserved: reserved) {
            candidate = "\(stem)-\(counter).pdf"
            counter += 1
        }
        reserved.insert(candidate.lowercased())
        return candidate
    }

    private func isTaken(_ name: String, in folder: String, reserved: Set<String>) -> Bool {
        if reserved.contains(name.lowercased()) { return true }
        return fs.exists((folder as NSString).appendingPathComponent(name))
    }
}
