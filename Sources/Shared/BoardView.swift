import SwiftUI

/// The task board: one day at a time, newest thing on top.
struct BoardView: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var day: String { app.selectedDay }
    private var entries: [Entry] { store.entries(on: day) }

    var body: some View {
        VStack(spacing: 0) {
            header.putsKeyboardAway($inputFocused)
            entryField
            Divider().opacity(0.4)
            board.putsKeyboardAway($inputFocused)
        }
        .background(Palette.board)
        // Grabbing focus on appear is right with a keyboard always present and wrong
        // with one that slides up over the board - on a phone it would bury both the
        // list and the tab bar before you had seen either. Typing there is a tap away.
        #if os(macOS)
        .onAppear { inputFocused = true }
        .onChange(of: day) { _, _ in inputFocused = true }
        #endif
        .onChange(of: app.focusTick) { _, _ in inputFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        // At the largest text sizes the title, the date, the arrows and the ring can't share a
        // line - "Today" broke in two and the ring went off the edge - so the controls go below.
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        return layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(for: day, today: app.today))
                    .scaledFont(size: 27, weight: .bold, design: .rounded)
                dateLabel
            }

            if !stacked { Spacer(minLength: 8) }

            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    stepButton("chevron.left", "Previous day", enabled: true) {
                        app.show(DayKey.adding(-1, to: day))
                    }
                    stepButton("chevron.right", "Next day", enabled: !app.isFuture(DayKey.adding(1, to: day))) {
                        app.show(DayKey.adding(1, to: day))
                    }
                }

                GoalRing(count: entries.count, goal: store.dailyGoal)
                    .onTapGesture {
                        guard entries.count >= store.dailyGoal else { return }
                        app.celebrate(.goalReached(count: entries.count))
                    }
                    .help(entries.count >= store.dailyGoal ? "Run it again" : "Today's progress")
                    // The count has to fit inside the ring, which grows with it only so far.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var dateLabel: some View {
        Text(Self.subtitle(for: day))
            .scaledFont(size: 12)
            .foregroundStyle(.secondary)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
    }

    private func stepButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 12, weight: .semibold)
                .frame(minWidth: 26, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: - Entry

    private var entryField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .scaledFont(size: 16)
                .foregroundStyle(inputFocused ? Color.accentColor : Color.secondary.opacity(0.55))
                .accessibilityHidden(true)

            TextField(placeholder, text: $draft)
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

    private var placeholder: String {
        day == app.today ? "What did you get done?" : "What did you get done that day?"
    }

    private func commit() {
        let text = draft
        draft = ""
        withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) {
            if let earned = store.add(text, to: day) {
                app.celebrate(earned)
            }
        }
        inputFocused = true
    }

    // MARK: - Board

    private var board: some View {
        ScrollView {
            if entries.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        EntryRow(entry: entry,
                                 today: app.today,
                                 onDelete: { delete(entry) },
                                 onMove: { destination in move(entry, to: destination) })
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
        // And dragging the board pulls the keyboard down with it, the way a message list does.
        .scrollDismissesKeyboard(.interactively)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .scaledFont(size: 34, weight: .light)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(day == app.today ? "Nothing up yet" : "Nothing was logged this day")
                .scaledFont(size: 15, weight: .medium)
            Text("Do something, then throw it up here.")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 74)
    }

    private func delete(_ entry: Entry) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            store.delete(entry)
        }
    }

    private func move(_ entry: Entry, to destination: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            store.move(entry, to: destination)
        }
    }

    // MARK: - Titles

    static func title(for day: String, today: String) -> String {
        if day == today { return "Today" }
        if day == DayKey.adding(-1, to: today) { return "Yesterday" }
        guard let date = DayKey.date(day) else { return day }
        return date.formatted(.dateTime.weekday(.wide))
    }

    static func subtitle(for day: String) -> String {
        guard let date = DayKey.date(day) else { return "" }
        return date.formatted(.dateTime.month(.wide).day().year())
    }
}

/// Progress toward the day's goal. Turns gold the moment you cross it - and, if you get
/// three times the way there in one day, quietly stops being gold.
struct GoalRing: View {
    let count: Int
    let goal: Int
    /// Grows with the count inside it.
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 58

    private var progress: Double {
        guard goal > 0 else { return 0 }
        return min(Double(count) / Double(goal), 1)
    }
    private var met: Bool { count >= goal }

    /// Three times the goal in a single day. Nothing announces this; you just find it.
    private var tripled: Bool { goal > 0 && count >= goal * 3 }

    /// Ends on the hue it starts on, so the rotation has no seam.
    private static let spectrum: [Color] = (0...6).map {
        Color(hue: Double($0) / 6, saturation: 0.85, brightness: 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.09), lineWidth: 6)

            if tripled {
                spinningRing
            } else {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        AngularGradient(
                            colors: met
                                ? [Color(hue: 0.11, saturation: 0.9, brightness: 1),
                                   Color(hue: 0.05, saturation: 0.8, brightness: 1),
                                   Color(hue: 0.11, saturation: 0.9, brightness: 1)]
                                : [Color.accentColor.opacity(0.75), Color.accentColor],
                            center: .center),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }

            VStack(spacing: -1) {
                Text("\(count)")
                    .scaledFont(size: 19, weight: .semibold, design: .rounded)
                Text("of \(goal)")
                    .scaledFont(size: 9, weight: .medium)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: met && !tripled ? Color.orange.opacity(0.35) : .clear, radius: 8)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: count)
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) of \(goal) done")
    }

    /// A spectrum turning slowly around the ring, drawn twice - once blurred for the
    /// glow, once sharp on top. The `TimelineView` only exists while you are at three
    /// times the goal, so on any ordinary day nothing here is redrawing at all.
    /// Not capped at 60 frames in code, unlike the fireworks: it is small, and cap it if freezes
    /// ever point at it. The iPhone build has never opted into more than 60
    /// (`CADisableMinimumFrameDurationOnPhone` isn't set), so on the phone it most likely draws
    /// at 60 anyway.
    private var spinningRing: some View {
        TimelineView(.animation) { timeline in
            // Wrapped to one turn. Left unbounded this is ~4.5e10 degrees, large
            // enough that the gradient loses all precision and collapses to a single
            // colour - a rainbow that renders solid red.
            let turn = (timeline.date.timeIntervalSinceReferenceDate * 55)
                .truncatingRemainder(dividingBy: 360)
            let sweep = AngularGradient(gradient: Gradient(colors: Self.spectrum),
                                        center: .center,
                                        angle: .degrees(turn))
            ZStack {
                Circle()
                    .stroke(sweep, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .blur(radius: 7)
                Circle()
                    .stroke(sweep, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
        }
    }
}

/// One card on the board. Right-click it - or use the button that appears on hover -
/// for everything you can do to it. Double-click to change its words or its time.
struct EntryRow: View {
    let entry: Entry
    /// Today, as the window sees it - the menu's move commands go no later than this.
    let today: String
    let onDelete: () -> Void
    let onMove: (String) -> Void

    @Environment(Store.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @State private var draftTime = Date()
    @FocusState private var editFocused: Bool

    private var tomorrow: String { DayKey.adding(1, to: entry.day) }

    /// At the largest text sizes the time goes under the words. Beside them it left the
    /// words a column so narrow that "Laundry" broke in two.
    private var stacked: Bool { typeSize.isAccessibilitySize && !editing }

    private var words: some View {
        Text(entry.text)
            .scaledFont(size: 14)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var time: some View {
        Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
            .scaledFont(size: 11, design: .rounded)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
    }

    /// A pointer can reveal controls on hover; a finger cannot, so on iOS the menu
    /// button is simply always there. The quick-remove ✕ is pointer-only - beside a
    /// finger it is mostly a way to delete something by accident, and the menu's
    /// Remove (or a long press) covers it.
    private var showsControls: Bool {
        #if os(macOS)
        hovering && !editing
        #else
        !editing
        #endif
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .scaledFont(size: 14)
                .foregroundStyle(Color.accentColor.opacity(0.85))
                .accessibilityHidden(true)

            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .scaledFont(size: 14)
                    .focused($editFocused)
                    .onSubmit(commitEdit)
                    #if os(macOS)
                    .onExitCommand { editing = false }
                    #endif
            } else if stacked {
                VStack(alignment: .leading, spacing: 4) {
                    words
                    time
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                words
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if editing {
                // Capped at the present, so today's card won't offer an hour that hasn't
                // happened yet. That only works because `draftTime` is placed on the
                // entry's own day - see `beginEdit`.
                DatePicker("Time", selection: $draftTime, in: ...Date(),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    #if os(macOS)
                    .datePickerStyle(.field)
                    #endif
                    .fixedSize()

                // Return in the text field commits too, but a change to only the time
                // leaves nothing to press Return in.
                Button("Done", action: commitEdit)
                    .buttonStyle(.borderless)
                    .scaledFont(size: 12, weight: .semibold)
                    .fixedSize()
            } else {
                if !stacked { time }

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
                .help("Edit, copy, move\u{2026}")
                .accessibilityLabel("More")
            }

            #if os(macOS)
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .scaledFont(size: 9, weight: .bold)
                    .frame(width: 17, height: 17)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(showsControls ? 1 : 0)
            .help("Remove")
            .accessibilityLabel("Remove")
            #endif
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
        Button("Edit\u{2026}") { beginEdit() }
        Button("Copy") { Clipboard.copy(entry.text) }

        Divider()

        Button("Move to Previous Day") { onMove(DayKey.adding(-1, to: entry.day)) }
        Button("Move to Next Day") { onMove(tomorrow) }
            .disabled(tomorrow > today)
        if entry.day != today {
            Button("Move to Today") { onMove(today) }
        }

        Divider()

        Button("Remove", role: .destructive) { onDelete() }
    }

    private func beginEdit() {
        guard !editing else { return }
        draft = entry.text
        draftTime = DayKey.at(entry.createdAt, on: entry.day) ?? entry.createdAt
        editing = true
        // A menu is still dismissing when this fires, and focus won't stick until
        // it has gone, so ask for it again on the next pass of the run loop.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            editFocused = true
        }
    }

    private func commitEdit() {
        store.update(entry, text: draft, time: draftTime)
        editing = false
    }
}
