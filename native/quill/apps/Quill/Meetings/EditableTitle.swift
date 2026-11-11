import SwiftUI

/// A meeting's name that can be changed where it is shown: a click (or the pencil that
/// appears on hover) turns it into a field; Return or clicking away keeps the new name,
/// Escape keeps the old one. An empty name is not kept.
struct EditableTitle: View {
    let title: String
    let size: CGFloat
    let rename: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField(MeetingCopy.t("meeting.rename.placeholder"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: size, weight: .bold))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                    .accessibilityLabel(MeetingCopy.t("meeting.rename"))
            } else {
                Button(action: begin) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .font(.system(size: size, weight: .bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Image(systemName: "pencil")
                            .font(.system(size: size * 0.55, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .opacity(hovering ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help(MeetingCopy.t("meeting.rename"))
                .accessibilityLabel(title)
                .accessibilityHint(MeetingCopy.t("meeting.rename"))
            }
        }
    }

    private func begin() {
        draft = title
        editing = true
        focused = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != title { rename(trimmed) }
    }
}
