import SwiftUI

struct WorkspaceSearchField: View {
  let prompt: LocalizedStringKey
  @Binding var text: String
  @FocusState<Bool>.Binding var focused: Bool
  var height: CGFloat = WorkspaceControlLayout.height

  var body: some View {
    Group {
      if #available(macOS 26, *) {
        field.glassEffect(.regular, in: .capsule)
      } else {
        field.background(.primary.opacity(0.08), in: .capsule)
          .overlay {
            Capsule().strokeBorder(.primary.opacity(0.12)).allowsHitTesting(false)
          }
      }
    }
    .overlay {
      if focused {
        Capsule().strokeBorder(Ink.sea).allowsHitTesting(false)
      }
    }
  }

  private var field: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
        .onTapGesture { focused = true }
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .focused($focused)
        .onExitCommand {
          if text.isEmpty { focused = false } else { text = "" }
        }
      if !text.isEmpty {
        Button {
          text = ""
          focused = true
        } label: {
          Label("Clear search", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Clear search")
      }
    }
    .padding(.horizontal, 11)
    .frame(height: height)
  }
}

private struct WorkspaceSearchFocusKey: FocusedValueKey {
  typealias Value = () -> Void
}

extension FocusedValues {
  var focusWorkspaceSearch: (() -> Void)? {
    get { self[WorkspaceSearchFocusKey.self] }
    set { self[WorkspaceSearchFocusKey.self] = newValue }
  }
}

struct WorkspaceSearchCommands: Commands {
  @FocusedValue(\.focusWorkspaceSearch) private var focusSearch

  var body: some Commands {
    CommandGroup(after: .textEditing) {
      Button("Find") { focusSearch?() }
        .keyboardShortcut("f")
        .disabled(focusSearch == nil)
    }
  }
}
