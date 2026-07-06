import CairnsKit
import Foundation

/// Draft state for the capture panel. Every keystroke debounces (~300ms) to
/// GitSync.writeDraft so a crash mid-thought loses nothing; save commits it.
@MainActor
final class CaptureModel: ObservableObject {
    @Published var text = ""
    /// Bumped on each open so the view can re-focus the editor.
    @Published private(set) var focusToken = 0

    var requestHide: @MainActor () -> Void = {}
    var afterSave: @MainActor () -> Void = {}

    private var filename = ""
    private var sync: GitSync?
    private var debounce: Task<Void, Never>?

    /// Restore an in-progress draft if one survived, else start a fresh note.
    func begin(sync: GitSync) async {
        self.sync = sync
        if let draft = await (try? sync.latestDraft()) ?? nil {
            filename = draft.filename
            text = draft.content
        } else {
            filename = Filenames.captureFilename()
            text = ""
        }
        focusToken += 1
    }

    func textChanged() {
        debounce?.cancel()
        let (name, content, git) = (filename, text, sync)
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? await git?.writeDraft(filename: name, content: content)
        }
    }

    func save() async {
        debounce?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sync, !trimmed.isEmpty {
            _ = try? await sync.saveCapture(filename: filename, content: text)
            afterSave()
        }
        text = ""
        requestHide()
    }

    func discard() async {
        debounce?.cancel()
        if let sync {
            try? await sync.discardDraft(filename: filename)
        }
        text = ""
        requestHide()
    }
}
