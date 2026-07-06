import Foundation

/// Capture filename contract, byte-compatible with trailhead's shared
/// `formatLocalTimestamp` / `conflictSiblingPath` / `describeCaptureFilename`
/// so one notes repo can be written by both generations of apps.
public enum Filenames {
    /// `YYYY-MM-DD-HHMMSS.md` in the local timezone, e.g. `2026-04-19-143022.md`.
    public static func captureFilename(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        "\(localTimestamp(date, timeZone)).md"
    }

    /// Human display for a capture filename, e.g. "Apr 19, 2026 · 2:30 PM".
    /// Returns nil when the name is not a capture-timestamp filename.
    public static func describeCaptureFilename(_ name: String, timeZone: TimeZone = .current) -> String? {
        guard let date = captureDate(name, timeZone) else { return nil }
        return "\(localized(date, timeZone, template: "MMMdyyyy")) \u{00B7} "
            + localized(date, timeZone, template: "jmm")
    }

    /// Sibling path for true 409 conflicts:
    /// `notes/foo.md` → `notes/foo--local-2026-04-19-143022.md`.
    public static func conflictSiblingPath(_ path: String, date: Date = Date(),
                                           timeZone: TimeZone = .current) -> String
    {
        let stamp = localTimestamp(date, timeZone)
        let dir: Substring
        let filename: Substring
        if let slash = path.lastIndex(of: "/") {
            dir = path[...slash] // trailing slash included, like trailhead's slice(0, i+1)
            filename = path[path.index(after: slash)...]
        } else {
            dir = ""
            filename = Substring(path)
        }
        // dot <= 0 in trailhead: no dot, or a leading dot (".gitignore") → no extension split.
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else {
            return "\(dir)\(filename)--local-\(stamp)"
        }
        return "\(dir)\(filename[..<dot])--local-\(stamp)\(filename[dot...])"
    }

    // MARK: - Helpers

    /// trailhead's `formatLocalTimestamp`: wall-clock `YYYY-MM-DD-HHMMSS`.
    private static func localTimestamp(_ date: Date, _ timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let parts = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d-%02d%02d%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Parse a `YYYY-MM-DD-HHMMSS.md` name back to a wall-clock Date in `timeZone`.
    private static func captureDate(_ name: String, _ timeZone: TimeZone) -> Date? {
        let pattern = /(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})\.md/
        guard let match = try? pattern.wholeMatch(in: name) else { return nil }
        let parts = [match.1, match.2, match.3, match.4, match.5, match.6].compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                        hour: parts[3], minute: parts[4], second: parts[5])
        return cal.date(from: components)
    }

    /// A localized date/time fragment, matching trailhead's `toLocale*String`
    /// (device locale, given zone). "MMMdyyyy" → "Nov 15, 2024"; "jmm" → "2:23 PM".
    private static func localized(_ date: Date, _ timeZone: TimeZone, template: String) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

/// Commit-message contract shared by both sync engines (matches trailhead).
public enum CommitMessages {
    /// `Add: <filename>`
    public static func add(_ filename: String) -> String { "Add: \(filename)" }
    /// `Update: <filename>`
    public static func update(_ filename: String) -> String { "Update: \(filename)" }
    /// `Add (conflict copy): <filename>`
    public static func addConflictCopy(_ filename: String) -> String { "Add (conflict copy): \(filename)" }
}
