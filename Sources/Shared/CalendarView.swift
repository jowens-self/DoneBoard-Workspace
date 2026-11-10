import SwiftUI

/// A month at a glance. Every day you did something is lit; days you hit the goal
/// go gold. Click one to put that day's board up.
struct CalendarSidebar: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app

    /// Any date inside the month currently on screen.
    @State private var anchor = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonthGrid(anchor: $anchor, selected: app.selectedDay,
                      pick: { app.show($0) }, today: { app.show(app.today) })
            Spacer(minLength: 12)
            stats
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var monthStart: Date { MonthLayout(containing: anchor).start }

    // MARK: - Stats

    private var stats: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().padding(.bottom, 5)
            statRow("This month", "\(store.monthTotal(monthStart))")
            statRow("Best day", "\(store.monthBest(monthStart))")
            statRow("All time", "\(store.allTimeTotal)")
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .scaledFont(size: 11, weight: .semibold, design: .rounded)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// One month of days, lit by how much got done on each, with arrows to step between
/// months. Picking a day puts its board up; days after today can't be picked.
struct MonthGrid: View {
    @Environment(Store.self) private var store
    @Environment(AppState.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Any date inside the month on screen.
    @Binding var anchor: Date
    /// The day outlined, if any.
    let selected: String?
    let pick: (String) -> Void
    /// When given, a "Today" button appears whenever today isn't what's showing.
    var today: (() -> Void)?

    private var month: MonthLayout { MonthLayout(containing: anchor) }

    private var isCurrentMonth: Bool { month.prefix == String(app.today.prefix(7)) }

    /// Between squares, both ways.
    private static let spacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            monthHeader
            VStack(spacing: 0) {
                weekdayRow
                grid
            }
            // The squares are as wide as a seventh of the screen and no wider, so the numbers in them
            // grow with the phone's text size only as far as they still fit.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
    }

    // MARK: - Header

    private var monthHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                // On the phone the name and the arrows take equal halves, so "Today" sits in the
                // middle of the screen, well clear of the arrows: right beside them, a thumb going
                // back a month kept landing on it instead. A long name wraps rather than reach it.
                #if os(iOS)
                monthName
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize {
                    todayButton
                        .padding(.horizontal, 8)
                }
                arrows
                    .frame(maxWidth: .infinity, alignment: .trailing)
                #else
                monthName
                Spacer(minLength: 4)
                todayButton
                    .padding(.trailing, 4)
                arrows
                #endif
            }
            // At the largest text sizes the name, "Today" and the arrows don't fit on one line.
            #if os(iOS)
            if typeSize.isAccessibilitySize {
                todayButton
                    .padding(.bottom, 6)
            }
            #endif
        }
        .padding(.bottom, Self.headerGap)
    }

    private var monthName: some View {
        Text(month.start.formatted(.dateTime.month(.wide).year()))
            .scaledFont(size: 15, weight: .semibold, design: .rounded)
    }

    private var arrows: some View {
        HStack(spacing: 2) {
            arrow("chevron.left", "Previous month", enabled: true) { step(-1) }
            arrow("chevron.right", "Next month", enabled: !isCurrentMonth) { step(1) }
        }
    }

    @ViewBuilder
    private var todayButton: some View {
        if let today, selected != app.today || !isCurrentMonth {
            Button {
                today()
                anchor = DayKey.date(app.today) ?? Date()
            } label: {
                Text("Today")
                    #if os(iOS)
                    // Away from the arrows it needs to look like a button on its own.
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .frame(minHeight: Self.target)
                    .contentShape(Rectangle())
                    #endif
            }
            .buttonStyle(.plain)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(Color.accentColor)
        }
    }

    #if os(iOS)
    /// The least a fingertip can hit without catching what's beside it.
    private static let target: CGFloat = 44
    /// The arrows' taller targets already leave room below the name.
    private static let headerGap: CGFloat = 0
    #else
    private static let target: CGFloat = 22
    private static let headerGap: CGFloat = 10
    #endif

    private func arrow(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 11, weight: .semibold)
                .frame(minWidth: Self.target, minHeight: Self.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.28))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func step(_ months: Int) {
        let moved = month.adding(months).start
        withAnimation(.easeOut(duration: 0.18)) { anchor = moved }
    }

    // MARK: - Days

    private var weekdayRow: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(month.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 5)
        // One letter each, and two of them are "T". Every day says its weekday instead.
        .accessibilityHidden(true)
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: 7),
                  spacing: Self.spacing) {
            ForEach(0..<(month.leadingBlanks + month.dayCount), id: \.self) { index in
                if index < month.leadingBlanks {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                } else {
                    let number = index - month.leadingBlanks + 1
                    let key = month.key(number)
                    let isFuture = app.isFuture(key)
                    let cell = DayCell(
                        number: number,
                        date: DayKey.date(key),
                        count: store.count(on: key),
                        goal: store.dailyGoal,
                        isToday: key == app.today,
                        isSelected: key == selected,
                        isFuture: isFuture)
                    if !isFuture {
                        cell.onTapGesture { pick(key) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { pick(key) }
                    } else {
                        cell
                    }
                }
            }
        }
    }
}

/// One square in the month grid.
struct DayCell: View {
    let number: Int
    /// For VoiceOver, which can't see which column the square is in.
    let date: Date?
    let count: Int
    let goal: Int
    let isToday: Bool
    let isSelected: Bool
    let isFuture: Bool

    /// How full the day was, 0...1 against the goal.
    private var intensity: Double {
        guard goal > 0, count > 0 else { return 0 }
        return min(Double(count) / Double(goal), 1)
    }
    private var met: Bool { count >= goal && count > 0 }

    private var fill: AnyShapeStyle {
        if met {
            return AnyShapeStyle(LinearGradient(
                colors: [Color(hue: 0.13, saturation: 0.82, brightness: 1),
                         Color(hue: 0.07, saturation: 0.85, brightness: 0.97)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        // Short of the goal, a day takes more colour the more was done.
        let share = 0.18 + 0.5 * intensity
        return AnyShapeStyle(count > 0 ? Color.accentColor.opacity(share) : Color.clear)
    }

    private var numberColor: Color {
        if met { return .black.opacity(0.72) }
        if isFuture { return .secondary.opacity(0.3) }
        if count > 0 && intensity > 0.55 { return .primary }
        if isToday { return .accentColor }
        return .secondary
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isSelected ? Color.primary.opacity(0.75) : Color.clear, lineWidth: 1.6)
            Text("\(number)")
                .scaledFont(size: 11, weight: isToday || met ? .bold : .regular, design: .rounded)
                .foregroundStyle(numberColor)
                .monospacedDigit()
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .opacity(isFuture ? 0.45 : 1)
        .allowsHitTesting(!isFuture)
        .help(isFuture ? "" : "\(count) done")
        .animation(.easeOut(duration: 0.18), value: count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The square read out: "Monday, November 3, today, 4 done, goal reached". Its colour is all
    /// that shows how much got done, and a number in a coloured square says nothing to VoiceOver.
    private var spoken: String {
        var parts = [date?.formatted(.dateTime.weekday(.wide).month(.wide).day()) ?? "\(number)"]
        if isToday { parts.append("today") }
        if !isFuture { parts.append(count == 0 ? "nothing done" : "\(count) done") }
        if met { parts.append("goal reached") }
        return parts.joined(separator: ", ")
    }
}
