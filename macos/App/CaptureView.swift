import SwiftUI

/// The capture editor: a focused multiline field, Save (⌘S / ⌘Return), and a
/// Discard. Esc hides the panel (draft file stays, recoverable next open).
struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $model.text)
                .font(.system(size: 16))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(16)
                .onChange(of: model.text) { model.textChanged() }
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 260)
        .background(.ultraThinMaterial)
        .onExitCommand { model.requestHide() }
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Discard", role: .destructive) { Task { await model.discard() } }
            Spacer()
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                // Prominent buttons default to a white label, which fails
                // contrast on the pale dark-mode accent; OnAccent adapts.
                .foregroundStyle(Color("OnAccent"))
            saveOnReturn
        }
        .padding(12)
    }

    // ponytail: hidden twin so ⌘Return also saves (one button = one shortcut).
    private var saveOnReturn: some View {
        Button("") { Task { await model.save() } }
            .keyboardShortcut(.return, modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}
