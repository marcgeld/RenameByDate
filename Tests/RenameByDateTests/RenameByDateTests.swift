//
//  RenameByDateTests.swift
//  RenameByDateTests
//
//  Created by Marcus Gelderman on 2026-07-28.
//

import Foundation
import Testing

@testable import RenameByDate

/// In-memory file system so engine behavior can be tested without touching disk.
final class MockFileSystem: FileSystem {
    private(set) var files: Set<String>
    private(set) var directories: Set<String>
    private(set) var attributesByPath: [String: [FileAttributeKey: Any]] = [:]

    init(files: Set<String> = [], directories: Set<String> = []) {
        self.files = files
        self.directories = directories
    }

    func exists(_ path: String) -> Bool {
        return files.contains(path) || directories.contains(path)
    }

    func list(_ path: String) throws -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return files
            .filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
            .map { ($0 as NSString).lastPathComponent }
            .sorted()
    }

    func copy(from src: String, to dst: String) throws {
        files.insert(dst)
    }

    func move(from src: String, to dst: String) throws {
        files.remove(src)
        files.insert(dst)
    }

    func makeDir(_ path: String) throws {
        directories.insert(path)
    }

    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        attributesByPath[path] = attributes
    }

    func enumerateRecursively(_ path: String) throws -> [String] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return files.filter { $0.hasPrefix(prefix) }.sorted()
    }
}

struct DateExtractionTests {
    @Test func detectsDatePrefixes() {
        #expect(DateExtraction.hasDatePrefix("2024-03-05 Acme.pdf"))
        #expect(DateExtraction.hasDatePrefix("20240305 Acme.pdf"))
        #expect(!DateExtraction.hasDatePrefix("Acme invoice.pdf"))
        // 8 digits that are not a plausible date must not count as one
        #expect(!DateExtraction.hasDatePrefix("12345678 order.pdf"))
    }

    @Test func findsDateInsideFileName() throws {
        let hit = try #require(DateExtraction.date(inFileName: "Acme invoice 2024-03-05"))
        #expect(DateExtraction.format(hit.date) == "2024-03-05")
        #expect(hit.remainder == "Acme invoice")
    }

    @Test func prefersGoodLabelOverBadLabelInText() throws {
        let text = """
        Acme AB
        Förfallodatum: 2024-04-04
        Fakturadatum: 2024-03-05
        """
        let date = try #require(DateExtraction.bestDate(inText: text))
        #expect(DateExtraction.format(date) == "2024-03-05")
    }

    @Test func parsesSlashDates() throws {
        let usStyle = try #require(DateExtraction.firstDate(in: "Date: 6/23/2018"))
        #expect(DateExtraction.format(usStyle) == "2018-06-23")

        // Day-first is used when it is the only valid reading
        let dayFirst = try #require(DateExtraction.firstDate(in: "23/6/2018"))
        #expect(DateExtraction.format(dayFirst) == "2018-06-23")

        // Ambiguous readings prefer US month/day order
        let ambiguous = try #require(DateExtraction.firstDate(in: "3/4/2018"))
        #expect(DateExtraction.format(ambiguous) == "2018-03-04")

        #expect(DateExtraction.firstDate(in: "13/13/2018") == nil)
    }

    @Test func parsesDottedEuropeanDates() throws {
        let dayFirst = try #require(DateExtraction.firstDate(in: "Datum: 23.6.2018"))
        #expect(DateExtraction.format(dayFirst) == "2018-06-23")

        // Ambiguous readings prefer European day/month order
        let ambiguous = try #require(DateExtraction.firstDate(in: "3.4.2018"))
        #expect(DateExtraction.format(ambiguous) == "2018-04-03")

        // Month-first is used when it is the only valid reading
        let monthFirst = try #require(DateExtraction.firstDate(in: "12.25.2018"))
        #expect(DateExtraction.format(monthFirst) == "2018-12-25")

        #expect(DateExtraction.firstDate(in: "13.13.2018") == nil)
        // Amounts with thousand separators are not dates
        #expect(DateExtraction.firstDate(in: "Total 1.240.00") == nil)
    }

    @Test func parsesTwoDigitYears() throws {
        let dotted = try #require(DateExtraction.firstDate(in: "23.6.18"))
        #expect(DateExtraction.format(dotted) == "2018-06-23")

        let slashed = try #require(DateExtraction.firstDate(in: "6/23/18"))
        #expect(DateExtraction.format(slashed) == "2018-06-23")

        // 50-99 map to the 1900s (years before 1990 are rejected as implausible)
        let nineties = try #require(DateExtraction.firstDate(in: "1.2.99"))
        #expect(DateExtraction.format(nineties) == "1999-02-01")
        #expect(DateExtraction.firstDate(in: "1.2.85") == nil)
    }

    @Test func parsesMonthNameDates() throws {
        for line in ["January 25, 2016", "Jan 25 2016", "25 januari 2016", "25th January 2016"] {
            let date = try #require(DateExtraction.firstDate(in: line), "failed for: \(line)")
            #expect(DateExtraction.format(date) == "2016-01-25", "failed for: \(line)")
        }
        #expect(DateExtraction.firstDate(in: "February 30, 2016") == nil)
    }

    @Test func formatsDatesWithUserSuppliedPatterns() throws {
        let hit = try #require(DateExtraction.date(inFileName: "Acme 2024-03-05"))
        #expect(DateExtraction.format(hit.date, pattern: "YYYYMMDD") == "20240305")
        #expect(DateExtraction.format(hit.date, pattern: "YYYY-MM-DD") == "2024-03-05")
        #expect(DateExtraction.format(hit.date, pattern: "%Y%m%d") == "20240305")
        #expect(DateExtraction.format(hit.date, pattern: "yyyyMMdd") == "20240305")
    }

    @Test func extractsVendorAndReferenceFromText() {
        let text = """
        Acme AB
        Fakturanummer: A-12345
        Fakturadatum: 2024-03-05
        """
        #expect(DateExtraction.vendorName(fromText: text, fallback: "fallback") == "Acme AB")
        #expect(DateExtraction.reference(fromText: text) == "A-12345")
        #expect(DateExtraction.reference(fromText: "no reference here") == nil)
    }
}

/// Tests against the real invoice PDFs in Resources/.
struct FixturePDFTests {
    private func fixtureText(_ name: String) throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "pdf", subdirectory: "Resources")
        )
        return try #require(DateExtraction.extractText(fromPDFAt: url.path))
    }

    @Test func picksInvoiceDateOverDueDateInColumnarInvoice() throws {
        let text = try fixtureText("sample-pdf-invoice_1")
        let date = try #require(DateExtraction.bestDate(inText: text))
        // The invoice date, not the later "payment due by" date 2025-07-06
        #expect(DateExtraction.format(date) == "2025-06-21")
        // The token after the "Invoice number" label is a date in this layout;
        // it must be skipped rather than returned as the reference
        #expect(DateExtraction.reference(fromText: text) == "1234567")
    }

    @Test func extractsSlashDateAndHashStyleInvoiceNumber() throws {
        let text = try fixtureText("sample-pdf-invoice_2")
        #expect(DateExtraction.reference(fromText: text) == "13594027")
        // "Date: 06/23/2018"
        let date = try #require(DateExtraction.bestDate(inText: text))
        #expect(DateExtraction.format(date) == "2018-06-23")
    }

    @Test func extractsMonthNameDateAndAlphanumericInvoiceNumber() throws {
        let text = try fixtureText("sample-pdf-invoice_3")
        #expect(DateExtraction.reference(fromText: text) == "INV-3337")
        // "Invoice Date January 25, 2016" — not the due date January 31
        let date = try #require(DateExtraction.bestDate(inText: text))
        #expect(DateExtraction.format(date) == "2016-01-25")
    }
}

struct RenameByDateEngineTests {
    @Test func dryRunPlansRenameFromFileNameDate() throws {
        let fs = MockFileSystem(
            files: ["/in/Acme invoice 2024-03-05.pdf"],
            directories: ["/in"]
        )
        let engine = RenameByDateEngine(fs: fs)

        let result = try engine.run(config: RenameByDateConfig(inputFolder: "/in"))

        #expect(result.planned.count == 1)
        #expect(result.planned.first?.new == "/in/20240305 Acme invoice.pdf")
        // Dry run must not touch the file system
        #expect(fs.files == ["/in/Acme invoice 2024-03-05.pdf"])
    }

    @Test func prefixOptionOverridesDateFormat() throws {
        let fs = MockFileSystem(
            files: ["/in/Acme invoice 2024-03-05.pdf"],
            directories: ["/in"]
        )
        let engine = RenameByDateEngine(fs: fs)

        let config = RenameByDateConfig(inputFolder: "/in", prefixFormat: "YYYY-MM-DD")
        let result = try engine.run(config: config)

        #expect(result.planned.first?.new == "/in/2024-03-05 Acme invoice.pdf")
    }

    @Test func skipsFilesAlreadyPrefixedWithDate() throws {
        let fs = MockFileSystem(
            files: ["/in/2024-03-05 Acme.pdf"],
            directories: ["/in"]
        )
        let engine = RenameByDateEngine(fs: fs)

        let result = try engine.run(config: RenameByDateConfig(inputFolder: "/in"))

        #expect(result.planned.isEmpty)
        #expect(result.skipped == ["/in/2024-03-05 Acme.pdf"])
    }

    @Test func collidingTargetsGetNumberedSuffixes() throws {
        // Two sources in different subfolders map to the same target name,
        // and that name is also already taken on disk.
        let fs = MockFileSystem(
            files: [
                "/in/20240305 Acme.pdf",
                "/in/a/Acme 2024-03-05.pdf",
                "/in/b/Acme 2024-03-05.pdf",
            ],
            directories: ["/in", "/in/a", "/in/b"]
        )
        let engine = RenameByDateEngine(fs: fs)

        let result = try engine.run(config: RenameByDateConfig(inputFolder: "/in", recursive: true))

        #expect(result.planned.map(\.new) == [
            "/in/20240305 Acme-1.pdf",
            "/in/20240305 Acme-2.pdf",
        ])
    }

    @Test func reservedNamesAreCaseInsensitive() {
        let engine = RenameByDateEngine(fs: MockFileSystem())
        var reserved: Set<String> = ["2024-03-05 acme.pdf"]

        let name = engine.uniqueName(vendor: "Acme", ref: "", dateString: "2024-03-05", outputFolder: "/out", reserved: &reserved)

        #expect(name == "2024-03-05 Acme-1.pdf")
    }

    @Test func applyMovesFileAndStampsDates() throws {
        let fs = MockFileSystem(
            files: ["/in/Acme invoice 2024-03-05.pdf"],
            directories: ["/in"]
        )
        let engine = RenameByDateEngine(fs: fs)

        let config = RenameByDateConfig(inputFolder: "/in", stamp: true, apply: true)
        let result = try engine.run(config: config)

        let newPath = "/in/20240305 Acme invoice.pdf"
        #expect(fs.files == [newPath])
        #expect(result.stamped == [newPath])
        let stampedDate = fs.attributesByPath[newPath]?[.creationDate] as? Date
        #expect(stampedDate.map(DateExtraction.format) == "2024-03-05")
    }
}
