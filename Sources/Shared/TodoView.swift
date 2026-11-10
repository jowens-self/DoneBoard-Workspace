import SwiftUI

/// The staging area: things you mean to get to.
///
/// Deliberately not the front page. Nothing here counts for anything - the calendar
/// and the goal are still fed only by work that actually happened. Checking something
/// off is the one bridge, and it runs in a single direction: the to-do disappears and
/// the same words land on today's board.
struct TodoView: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var todos: [Todo] { store.openTodos }

    var body: some View {
        VStack(spacing: 0) {
            header.putsKeyboardAway($inputFocused)
            entryField
            Divider().opacity(0.4)
            list.putsKeyboardAway($inputFocused)
        }
        .background(Palette.board)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("To-do")
                    .scaledFont(size: 27, weight: .bold, design: .rounded)
                if !todos.isEmpty {
                    Text("^[\(todos.count) thing](inflect: true) to get to.")
                        .scaledFont(size: 12)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var entryField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .scaledFont(size: 16)
                .foregroundStyle(inputFocused ? Color.accentColor : Color.secondary.opacity(0.55))
                .accessibilityHidden(true)

            TextField("What do you want to get done?", text: $draft)
                .textFieldStyle(.plain)
                .scaledFont(size: 15)
                .focused($inputFocused)
                .onSubmit(commit)

            if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("return")
                    .scaledFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(inputFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                    lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: inputFocused)
        .animation(.easeOut(duration: 0.15), value: draft.isEmpty)
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    private func commit() {
        let text = draft
        draft = ""
        withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) {
            store.addTodo(text)
        }
        inputFocused = true
    }

    private var list: some View {
        ScrollView {
            if todos.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(todos) { todo in
                        TodoRow(todo: todo,
                                onComplete: { complete(todo) },
                                onRemove: { remove(todo) })
                            .transition(.asymmetric(
                                insertion: .move(edge: .top)
                                    .combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.95, anchor: .top)),
                                removal: .opacity.combined(with: .scale(scale: 0.92))))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
        }
        // And dragging the list pulls the keyboard down with it, the way a message list does.
        .scrollDismissesKeyboard(.interactively)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.dashed")
                .scaledFont(size: 34, weight: .light)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Nothing planned")
                .scaledFont(size: 15, weight: .medium)
            Text("Whatever you check off here lands on the board as something you did.")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 74)
    }

    private func complete(_ todo: Todo) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
            if let earned = store.complete(todo, on: app.today) { app.celebrate(earned) }
        }
    }

    private func remove(_ todo: Todo) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            store.removeTodo(todo)
        }
    }
}

/// One line on the list. The circle is the whole point - tapping it is what moves the
/// thing onto the board. Right-click it - or use the button that appears on hover - for
/// everything else, and double-click to change its words.
struct TodoRow: View {
    let todo: Todo
    let onComplete: () -> Void
    let onRemove: () -> Void

    @Environment(Store.self) private var store
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var editFocused: Bool

    /// A pointer can reveal controls on hover; a finger cannot, so on iOS the menu
    /// button is simply always there.
    private var showsControls: Bool {
        #if os(macOS)
        hovering && !editing
        #else
        !editing
        #endif
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Button(action: onComplete) {
                Image(systemName: "circle")
                    .scaledFont(size: 15, weight: .regular)
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.7))
                    .frame(minWidth: 22, minHeight: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark done")
            .help("Mark it done - it moves to today's board")

            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 14)
                    .focused($editFocused)
                    .onSubmit(commitEdit)
                    #if os(macOS)
                    .onExitCommand { editing = false }
                    #endif
            } else {
                Text(todo.text)
                    .scaledFont(size: 14)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis")
                    .scaledFont(size: 11, weight: .bold)
                    #if os(macOS)
                    .frame(width: 18, height: 17)
                    #else
                    .frame(width: 44, height: 34)
                    #endif
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .opacity(showsControls ? 1 : 0)
            .help("Mark done, edit, copy\u{2026}")
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(editing ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { beginEdit() }
        .contextMenu { actions }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Shared by the right-click menu and the hover button, so the two can't drift.
    @ViewBuilder
    private var actions: some View {
        Button("Mark Done") { onComplete() }
        Button("Edit\u{2026}") { beginEdit() }
        Button("Copy") { Clipboard.copy(todo.text) }

        Divider()

        Button("Drop It", role: .destructive) { onRemove() }
    }

    private func beginEdit() {
        guard !editing else { return }
        draft = todo.text
        editing = true
        // A menu is still dismissing when this fires, and focus won't stick until
        // it has gone, so ask for it again on the next pass of the run loop.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            editFocused = true
        }
    }

    private func commitEdit() {
        store.updateTodo(todo, text: draft)
        editing = false
    }
}
