import SwiftUI

/// The one input box: "记点什么，或者问点什么" with send. Sending hands the text to 提问 (AskView),
/// which records it, answers it, or breaks it into a project. Dictation comes from the keyboard.
/// In a List row on 新建; `floating` is the rounded field pinned under a conversation.
struct CaptureBar: View {
    @Binding var text: String
    var placeholder = "记点什么，或者问点什么"
    var busy = false
    var floating = false
    var focus: FocusState<Bool>.Binding
    var idPrefix = "capture"
    let onSend: (String) -> Void

    private var canSend: Bool { !text.trimmedText.isEmpty && !busy }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused(focus)
                .submitLabel(.send)
                .padding(.vertical, floating ? 7 : 6)
                .onChange(of: text) { old, new in
                    // Return sends (a vertical field would otherwise take it as a new line).
                    if new.count == old.count + 1, new.hasSuffix("\n") {
                        text = String(new.dropLast())
                        send()
                    }
                }
                .accessibilityLabel(placeholder)
                .accessibilityIdentifier("\(idPrefix)-input")
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, canSend ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.tertiaryText))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.bottom, floating ? 2 : 1)
            .accessibilityLabel("发送")
            .accessibilityIdentifier("\(idPrefix)-send")
        }
        .padding(.leading, floating ? 14 : 0)
        .padding(.trailing, floating ? 4 : 0)
        .padding(.vertical, floating ? 3 : 0)
        .background {
            if floating {
                RoundedRectangle(cornerRadius: 20).fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.hairline, lineWidth: 0.5))
            }
        }
    }

    private func send() {
        let t = text.trimmedText
        guard !t.isEmpty, !busy else { return }
        text = ""
        onSend(t)
    }
}
