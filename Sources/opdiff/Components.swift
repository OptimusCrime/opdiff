import AppKit
import SwiftUI

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension View {
    /// The look of a text input: text background inside a thin rounded border.
    func inputBox() -> some View {
        background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Multi-line text input with a placeholder. Return adds a line, so pair it with a ⌘↩ button.
struct PlaceholderTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var focus: FocusState<Bool>.Binding?
    var height: CGFloat = 96

    var body: some View {
        editor
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 4).padding(.vertical, 6)
            .frame(height: height)
            .inputBox()
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var editor: some View {
        if let focus {
            TextEditor(text: $text).focused(focus)
        } else {
            TextEditor(text: $text)
        }
    }
}

/// Reports the NSWindow a view lives in.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}
