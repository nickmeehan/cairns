@testable import CairnsKit
import XCTest

/// Filename + commit-message contract, byte-compatible with trailhead's
/// `formatLocalTimestamp` / `describeCaptureFilename` / `conflictSiblingPath`.
/// All assertions pin an explicit TimeZone so the machine's zone never leaks in.
final class FilenamesTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC") ?? .current

    /// Build a Date from explicit wall-clock components in a given zone.
    private func date(in timeZone: TimeZone, _ components: DateComponents) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: captureFilename (== formatLocalTimestamp + ".md")

    func testCaptureFilenameFormatsAndZeroPads() {
        let june = date(in: utc, DateComponents(year: 2024, month: 6, day: 15, hour: 9, minute: 5, second: 3))
        XCTAssertEqual(Filenames.captureFilename(date: june, timeZone: utc), "2024-06-15-090503.md")
        let jan = date(in: utc, DateComponents(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5))
        XCTAssertEqual(Filenames.captureFilename(date: jan, timeZone: utc), "2024-01-02-030405.md")
    }

    func testCaptureFilenameMidnightAndEndOfDay() {
        let midnight = date(in: utc, DateComponents(year: 2024, month: 12, day: 31, hour: 0, minute: 0, second: 0))
        XCTAssertEqual(Filenames.captureFilename(date: midnight, timeZone: utc), "2024-12-31-000000.md")
        let endOfDay = date(in: utc, DateComponents(year: 2024, month: 12, day: 31, hour: 23, minute: 59, second: 59))
        XCTAssertEqual(Filenames.captureFilename(date: endOfDay, timeZone: utc), "2024-12-31-235959.md")
    }

    func testCaptureFilenameHonorsTimeZone() {
        // Same instant, two zones → two wall-clock stamps.
        let instant = date(in: utc, DateComponents(year: 2024, month: 6, day: 15, hour: 9, minute: 5, second: 3))
        let newYork = TimeZone(identifier: "America/New_York") ?? utc // UTC-4 in June
        XCTAssertEqual(Filenames.captureFilename(date: instant, timeZone: utc), "2024-06-15-090503.md")
        XCTAssertEqual(Filenames.captureFilename(date: instant, timeZone: newYork), "2024-06-15-050503.md")
    }

    // MARK: describeCaptureFilename

    func testDescribeRendersLocalDate() {
        // Replicate the exact formatters the impl uses so the assertion is
        // deterministic on any machine locale (as trailhead's own test does).
        let when = date(in: utc, DateComponents(year: 2024, month: 11, day: 15, hour: 14, minute: 23, second: 5))
        let expected = "\(localized(when, template: "MMMdyyyy")) \u{00B7} \(localized(when, template: "jmm"))"
        XCTAssertEqual(Filenames.describeCaptureFilename("2024-11-15-142305.md", timeZone: utc), expected)
    }

    func testDescribeContainsMiddleDotAndDropsSeconds() {
        let out = Filenames.describeCaptureFilename("2024-11-15-142305.md", timeZone: utc)
        XCTAssertNotNil(out)
        XCTAssertTrue(out?.contains(" \u{00B7} ") ?? false, "must join parts with a spaced middle dot")
        XCTAssertTrue(out?.contains("2024") ?? false)
    }

    func testDescribeReturnsNilForNonCaptureNames() {
        XCTAssertNil(Filenames.describeCaptureFilename("meeting-notes.md", timeZone: utc))
        XCTAssertNil(Filenames.describeCaptureFilename("2024-11-15.md", timeZone: utc))
        XCTAssertNil(Filenames.describeCaptureFilename("2024-11-15-142305.txt", timeZone: utc))
        XCTAssertNil(Filenames.describeCaptureFilename("2024-11-15-142305.md.md", timeZone: utc))
    }

    // MARK: conflictSiblingPath

    private var conflictDate: Date {
        date(in: utc, DateComponents(year: 2026, month: 4, day: 19, hour: 14, minute: 30, second: 22))
    }

    func testConflictSiblingWithDirectoryAndExtension() {
        XCTAssertEqual(Filenames.conflictSiblingPath("notes/foo.md", date: conflictDate, timeZone: utc),
                       "notes/foo--local-2026-04-19-143022.md")
    }

    func testConflictSiblingNoDirectory() {
        XCTAssertEqual(Filenames.conflictSiblingPath("foo.md", date: conflictDate, timeZone: utc),
                       "foo--local-2026-04-19-143022.md")
    }

    func testConflictSiblingNoExtension() {
        XCTAssertEqual(Filenames.conflictSiblingPath("foo", date: conflictDate, timeZone: utc),
                       "foo--local-2026-04-19-143022")
        XCTAssertEqual(Filenames.conflictSiblingPath("notes/foo", date: conflictDate, timeZone: utc),
                       "notes/foo--local-2026-04-19-143022")
    }

    func testConflictSiblingLeadingDotIsNotAnExtension() {
        XCTAssertEqual(Filenames.conflictSiblingPath("notes/.gitignore", date: conflictDate, timeZone: utc),
                       "notes/.gitignore--local-2026-04-19-143022")
    }

    func testConflictSiblingUsesLastDot() {
        XCTAssertEqual(Filenames.conflictSiblingPath("a/b.c.md", date: conflictDate, timeZone: utc),
                       "a/b.c--local-2026-04-19-143022.md")
    }

    // MARK: CommitMessages

    func testCommitMessages() {
        XCTAssertEqual(CommitMessages.add("2024-11-15-142305.md"), "Add: 2024-11-15-142305.md")
        XCTAssertEqual(CommitMessages.update("2024-11-15-142305.md"), "Update: 2024-11-15-142305.md")
        XCTAssertEqual(CommitMessages.addConflictCopy("foo--local-x.md"),
                       "Add (conflict copy): foo--local-x.md")
    }

    // MARK: formatter replica (matches Filenames.describeCaptureFilename exactly)

    private func localized(_ when: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = utc
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: when)
    }
}
