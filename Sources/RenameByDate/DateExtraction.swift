import Foundation
import os
import PDFKit

/// Shared PDF text, date, and label extraction used by the engine and tests.
/// All text-based functions are pure so they can be tested without PDF fixtures.
public enum DateExtraction {

    /// Unified logging; view with:
    /// log stream --predicate 'subsystem == "se.redseven.RenameByDate"' --level debug
    private static let logger = Logger(subsystem: "se.redseven.RenameByDate", category: "extraction")

    // MARK: - Label patterns

    /// Labels that mark the document's own date (checked case-insensitively).
    public static let goodLabels: [String] = [
        "invoice date", "date of issue", "issue date", "document date",
        "fakturadatum", "dokumentdatum", "datum", "date",
    ]

    /// Lines matching this pattern carry dates that are not the document date
    /// (due dates, payment dates, delivery dates, and similar).
    public static let badLabelPattern =
        #"(?i)(due date|payment date|delivery date|expiry|valid (until|through)|förfallodatum|betaldatum|leveransdatum)"#

    // MARK: - PDF text

    /// Concatenated text of all pages, or nil if the file is not a readable
    /// PDF or contains no extractable text (e.g. a scan without OCR).
    public static func extractText(fromPDFAt path: String) -> String? {
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            logger.debug("Not a readable PDF: \(path, privacy: .public)")
            return nil
        }
        var text = ""
        for index in 0..<document.pageCount {
            if let pageText = document.page(at: index)?.string {
                text += pageText
                text += "\n"
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            logger.debug("No text layer (scanned PDF?): \(path, privacy: .public)")
            return nil
        }
        return trimmed
    }

    // MARK: - Dates

    /// A regex for locating a date in text plus the parser that turns the
    /// matched substring into a Date.
    private struct DateMatcher: Sendable {
        let pattern: String
        let parse: @Sendable (String) -> Date?
    }

    private static let dateMatchers: [DateMatcher] = [
        DateMatcher(pattern: #"\d{4}-\d{2}-\d{2}"#, parse: { parse($0) }),
        DateMatcher(pattern: #"(?<!\d)\d{8}(?!\d)"#, parse: { parse($0) }),
        DateMatcher(pattern: #"(?<!\d)\d{1,2}/\d{1,2}/(?:\d{4}|\d{2})(?!\d)"#, parse: parseSlashDate),
        DateMatcher(pattern: #"(?<!\d)\d{1,2}\.\d{1,2}\.(?:\d{4}|\d{2})(?!\d)"#, parse: parseDottedDate),
        DateMatcher(pattern: monthNamePattern, parse: parseMonthNameDate),
    ]

    /// English (full and abbreviated) and Swedish month names.
    private static let monthNumbers: [String: Int] = [
        "january": 1, "jan": 1, "januari": 1,
        "february": 2, "feb": 2, "februari": 2,
        "march": 3, "mar": 3, "mars": 3,
        "april": 4, "apr": 4,
        "may": 5, "maj": 5,
        "june": 6, "jun": 6, "juni": 6,
        "july": 7, "jul": 7, "juli": 7,
        "august": 8, "aug": 8, "augusti": 8,
        "september": 9, "sept": 9, "sep": 9,
        "october": 10, "oct": 10, "oktober": 10, "okt": 10,
        "november": 11, "nov": 11,
        "december": 12, "dec": 12,
    ]

    /// Matches "January 25, 2016", "Aug 3 2024", and "25 januari 2016" styles.
    /// Longer names first so e.g. "januari" is not cut short by "jan".
    private static let monthNamePattern: String = {
        let names = monthNumbers.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        return #"(?i)\b(?:(?:\#(names))\.?\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}|\d{1,2}(?:st|nd|rd|th)?\.?\s+(?:\#(names))\.?\s+\d{4})\b"#
    }()

    /// True if the name already starts with a plausible yyyy-MM-dd or yyyyMMdd date.
    public static func hasDatePrefix(_ name: String) -> Bool {
        for pattern in [#"^\d{4}-\d{2}-\d{2}"#, #"^\d{8}"#] {
            if let range = name.range(of: pattern, options: .regularExpression),
               parse(String(name[range])) != nil {
                return true
            }
        }
        return false
    }

    /// Parses a yyyy-MM-dd or yyyyMMdd string, rejecting implausible years so
    /// ordinary 8-digit numbers (order numbers, phone numbers) are not treated as dates.
    public static func parse(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "yyyyMMdd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                let year = Calendar.current.component(.year, from: date)
                if (1990...2099).contains(year) {
                    return date
                }
                return nil
            }
        }
        return nil
    }

    /// Formats a date as yyyy-MM-dd for use as a filename prefix.
    public static func format(_ date: Date) -> String {
        return format(date, pattern: "yyyy-MM-dd")
    }

    /// Formats a date with a user-supplied pattern. Accepts macOS
    /// DateFormatter patterns (yyyyMMdd), uppercase variants (YYYYMMDD),
    /// and unix strftime tokens (%Y%m%d).
    public static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = normalizedDatePattern(pattern)
        return formatter.string(from: date)
    }

    /// Normalizes a user-supplied date format to a DateFormatter pattern.
    /// In raw Unicode patterns YYYY is week-based year and DD is day of year,
    /// which is almost never what a user means in a filename, so uppercase
    /// tokens are treated as plain year/day.
    public static func normalizedDatePattern(_ pattern: String) -> String {
        if pattern.contains("%") {
            return pattern
                .replacingOccurrences(of: "%Y", with: "yyyy")
                .replacingOccurrences(of: "%y", with: "yy")
                .replacingOccurrences(of: "%m", with: "MM")
                .replacingOccurrences(of: "%d", with: "dd")
        }
        return pattern
            .replacingOccurrences(of: "YYYY", with: "yyyy")
            .replacingOccurrences(of: "YY", with: "yy")
            .replacingOccurrences(of: "DD", with: "dd")
    }

    /// Finds a date anywhere in a filename (extension already stripped).
    /// Returns the date and the remaining name with the date and stray
    /// separators removed, for reuse as the vendor part of the new name.
    public static func date(inFileName name: String) -> (date: Date, remainder: String)? {
        for matcher in dateMatchers {
            var searchRange = name.startIndex..<name.endIndex
            while let range = name.range(of: matcher.pattern, options: .regularExpression, range: searchRange) {
                if let date = matcher.parse(String(name[range])) {
                    var remainder = name
                    remainder.removeSubrange(range)
                    remainder = remainder
                        .replacingOccurrences(of: #"[\s_-]{2,}"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
                    return (date, remainder)
                }
                searchRange = range.upperBound..<name.endIndex
            }
        }
        return nil
    }

    /// Best document date in extracted PDF text: prefers a date on a line
    /// with a good label, then falls back to the first date on any line
    /// that does not match `badLabelPattern`.
    public static func bestDate(inText text: String) -> Date? {
        var fallback: Date?
        for line in text.components(separatedBy: .newlines) {
            guard let date = firstDate(in: line) else { continue }
            if line.range(of: badLabelPattern, options: .regularExpression) != nil {
                logger.debug("Ignoring date \(format(date), privacy: .public) on bad-label line")
                continue
            }
            let lowered = line.lowercased()
            if goodLabels.contains(where: { lowered.contains($0) }) {
                logger.debug("Using date \(format(date), privacy: .public) from good-label line")
                return date
            }
            if fallback == nil {
                fallback = date
            }
        }
        if let fallback {
            logger.debug("Using first unlabeled date \(format(fallback), privacy: .public) as fallback")
        }
        return fallback
    }

    /// First parseable date in a single line of text.
    public static func firstDate(in line: String) -> Date? {
        for matcher in dateMatchers {
            var searchRange = line.startIndex..<line.endIndex
            while let range = line.range(of: matcher.pattern, options: .regularExpression, range: searchRange) {
                if let date = matcher.parse(String(line[range])) {
                    return date
                }
                searchRange = range.upperBound..<line.endIndex
            }
        }
        return nil
    }

    /// Parses "6/23/2018" style dates. Month/day order (US convention, where
    /// slash dates are most common) is preferred; day/month is used when that
    /// is the only valid reading, e.g. "23/6/2018".
    private static func parseSlashDate(_ string: String) -> Date? {
        return parseNumericDate(string, separator: "/", monthFirst: true)
    }

    /// Parses "23.6.2018" style dates. Day/month order (European convention,
    /// where dotted dates are most common) is preferred; month/day is used
    /// when that is the only valid reading, e.g. "12.25.2018".
    private static func parseDottedDate(_ string: String) -> Date? {
        return parseNumericDate(string, separator: ".", monthFirst: false)
    }

    private static func parseNumericDate(_ string: String, separator: Character, monthFirst: Bool) -> Date? {
        let fields = string.split(separator: separator)
        let parts = fields.compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        // Two-digit years: 00-49 -> 2000s, 50-99 -> 1900s
        var year = parts[2]
        if fields[2].count == 2 {
            year += year < 50 ? 2000 : 1900
        }
        let (month, day) = monthFirst ? (parts[0], parts[1]) : (parts[1], parts[0])
        if let date = makeDate(year: year, month: month, day: day) {
            return date
        }
        return makeDate(year: year, month: day, day: month)
    }

    /// Parses month-name dates like "January 25, 2016", "Aug 3 2024",
    /// or "25 januari 2016".
    private static func parseMonthNameDate(_ string: String) -> Date? {
        let tokens = string.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ")

        var month: Int?
        var day: Int?
        var year: Int?
        for token in tokens {
            if let m = monthNumbers[String(token)] {
                month = m
                continue
            }
            // prefix(while:) drops ordinal suffixes such as "25th"
            guard let n = Int(token.prefix(while: { $0.isNumber })) else { continue }
            if n >= 1000 {
                year = n
            } else if day == nil {
                day = n
            }
        }
        guard let month, let day, let year else { return nil }
        return makeDate(year: year, month: month, day: day)
    }

    /// Builds a Date from components, rejecting implausible years and
    /// non-existent calendar days (e.g. February 30).
    private static func makeDate(year: Int, month: Int, day: Int) -> Date? {
        guard (1990...2099).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        let calendar = Calendar.current
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day,
              calendar.component(.month, from: date) == month else {
            return nil
        }
        return date
    }

    // MARK: - Vendor and reference

    /// Company-suffix pattern used to spot a vendor line in PDF text.
    private static let vendorSuffixPattern =
        #"(?i)\b(AB|HB|Inc\.?|LLC|Ltd\.?|GmbH|Oy|ApS|A/S|Co\.)(\b|$)"#

    /// Picks a vendor name from the first lines of the PDF text (a short line
    /// ending in a company suffix), falling back to the given filename-derived string.
    public static func vendorName(fromText text: String?, fallback: String) -> String {
        if let text {
            for line in text.components(separatedBy: .newlines).prefix(15) {
                let candidate = line.trimmingCharacters(in: .whitespaces)
                if candidate.count <= 40,
                   candidate.range(of: vendorSuffixPattern, options: .regularExpression) != nil {
                    return sanitize(candidate)
                }
            }
        }
        let cleaned = sanitize(fallback)
        return cleaned.isEmpty ? "Unknown" : cleaned
    }

    /// Reference (invoice/OCR number) found after a known label. The captured
    /// token must contain a digit so label words themselves are never captured.
    public static func reference(fromText text: String?) -> String? {
        guard let text else { return nil }
        let pattern =
            #"(?i)(?:invoice\s*(?:number|no|#)?|faktura(?:nummer|nr)?|ocr|reference|ref)\s*[:.#]?\s*((?=[A-Za-z0-9-]*\d)[A-Za-z0-9][A-Za-z0-9-]{2,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let captureRange = Range(match.range(at: 1), in: text) else { continue }
            let candidate = String(text[captureRange])
            // In columnar PDF layouts the token after an "invoice ..." label is
            // sometimes a date; a date is never the reference number.
            if candidate.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
                || parse(candidate) != nil {
                logger.debug("Skipping date-like reference candidate: \(candidate, privacy: .public)")
                continue
            }
            logger.debug("Using reference: \(candidate, privacy: .public)")
            return sanitize(candidate)
        }
        return nil
    }

    /// Strips characters that are unsafe or noisy in filenames.
    public static func sanitize(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
