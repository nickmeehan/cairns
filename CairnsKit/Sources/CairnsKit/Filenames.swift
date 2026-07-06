import Foundation

/// Capture filename contract, byte-compatible with trailhead's shared
/// `formatLocalTimestamp` / `conflictSiblingPath` / `describeCaptureFilename`
/// so one notes repo can be written by both generations of apps.
public enum Filenames {
    /// `YYYY-MM-DD-HHMMSS.md` in the local timezone, e.g. `2026-04-19-143022.md`.
    public static func captureFilename(date _: Date = Date(), timeZone _: TimeZone = .current) -> String {
        fatalError("unimplemented")
    }

    /// Human display for a capture filename, e.g. "Apr 19, 2026 · 2:30 PM".
    /// Returns nil when the name is not a capture-timestamp filename.
    public static func describeCaptureFilename(_: String, timeZone _: TimeZone = .current) -> String? {
        fatalError("unimplemented")
    }

    /// Sibling path for true 409 conflicts:
    /// `notes/foo.md` → `notes/foo--local-2026-04-19-143022.md`.
    public static func conflictSiblingPath(_: String, date _: Date = Date(),
                                           timeZone _: TimeZone = .current) -> String
    {
        fatalError("unimplemented")
    }
}

/// Commit-message contract shared by both sync engines (matches trailhead).
public enum CommitMessages {
    /// `Add: <filename>`
    public static func add(_: String) -> String { fatalError("unimplemented") }
    /// `Update: <filename>`
    public static func update(_: String) -> String { fatalError("unimplemented") }
    /// `Add (conflict copy): <filename>`
    public static func addConflictCopy(_: String) -> String { fatalError("unimplemented") }
}
