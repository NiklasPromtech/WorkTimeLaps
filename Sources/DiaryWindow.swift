import AppKit
import SwiftUI

// MARK: - Model

/// Backs the Diary window: the list of recorded days and their entries.
/// Reloads when a diary is written or the journal changes.
@MainActor
final class DiaryViewModel: ObservableObject {

    static let shared = DiaryViewModel()

    struct Day: Identifiable, Hashable {
        let key: String
        let date: Date
        let isInProgress: Bool
        let activeSeconds: Double
        let headline: String?
        let shape: WorkDiary.DayShape?
        var id: String { key }
    }

    @Published private(set) var days: [Day] = []
    @Published private(set) var diaries: [String: WorkDiary] = [:]
    @Published private(set) var writing: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published var selection: String?

    private var observers: [NSObjectProtocol] = []

    private init() {
        reload()
        let names: [Notification.Name] = [.worktimelapsDiaryUpdated, .worktimelapsJournalDidUpdate]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { DiaryViewModel.shared.reload() }
            })
        }
    }

    func reload() {
        let todayKey = WorkDay.key(for: Date())
        var keys = Set(Journal.loadAllDays().map(\.date))
        keys.insert(todayKey)

        var loaded: [String: WorkDiary] = [:]
        var result: [Day] = []
        for key in keys.sorted(by: >) {
            guard let date = WorkDay.date(fromKey: key) else { continue }
            let diary = DiaryStore.load(dayKey: key)
            if let diary { loaded[key] = diary }
            let active = diary?.stats.activeSeconds ?? JournalStore.shared.cell(for: date).totalDuration
            result.append(Day(
                key: key,
                date: date,
                isInProgress: key == todayKey,
                activeSeconds: active,
                headline: diary?.headline,
                shape: diary?.dayShape
            ))
        }
        days = result
        diaries = loaded
        writing = DiaryScheduler.shared.inProgress
        if let selection, keys.contains(selection) { return }
        selection = latestKey
    }

    /// The most recent finished day, preferring one with an entry.
    var latestKey: String? {
        days.first(where: { !$0.isInProgress && diaries[$0.key] != nil })?.key
            ?? days.first(where: { !$0.isInProgress })?.key
            ?? days.first?.key
    }

    /// Writes (or rewrites) a day's entry on demand.
    func write(_ key: String) {
        errors[key] = nil
        Task { @MainActor in
            await DiaryScheduler.shared.write(dayKey: key, notify: false)
            errors[key] = DiaryScheduler.shared.lastErrors[key]
            reload()
        }
    }
}

// MARK: - Root

struct DiaryRootView: View {
    @ObservedObject var model: DiaryViewModel

    var body: some View {
        ZStack {
            BackgroundCanvas()
            HStack(spacing: 0) {
                DiarySidebar(model: model)
                    .frame(width: 276)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1060, minHeight: 720)
    }

    @ViewBuilder
    private var detail: some View {
        if let key = model.selection, let day = model.days.first(where: { $0.key == key }) {
            ScrollView {
                Group {
                    if let diary = model.diaries[key] {
                        DiaryPage(diary: diary, model: model)
                    } else if day.isInProgress {
                        InProgressPage(day: day)
                    } else {
                        MissingEntryPage(day: day, model: model)
                    }
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 44)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollClipDisabled()
            .id(key)
        } else {
            EmptyDiaryState()
        }
    }
}

// MARK: - Sidebar

private struct DiarySidebar: View {
    @ObservedObject var model: DiaryViewModel

    private struct Section: Identifiable {
        let id: String
        let title: String
        let days: [DiaryViewModel.Day]
    }

    private var sections: [Section] {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        var result: [Section] = []
        for day in model.days {
            let title = f.string(from: day.date)
            if let last = result.last, last.title == title {
                result[result.count - 1] = Section(id: last.id, title: title, days: last.days + [day])
            } else {
                result.append(Section(id: title, title: title, days: [day]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Diary")
                    .font(.system(size: 30, weight: .bold, design: .serif))
                Text("A page for every day you worked.")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 30)
            .padding(.bottom, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(sections) { section in
                        Text(section.title.uppercased())
                            .font(.system(.caption2, design: .rounded).weight(.semibold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(section.days) { day in
                            DiarySidebarRow(
                                day: day,
                                isSelected: model.selection == day.key,
                                isWriting: model.writing.contains(day.key)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.15)) { model.selection = day.key }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 24)
            }
        }
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 0.5)
                }
                .ignoresSafeArea()
        }
    }
}

private struct DiarySidebarRow: View {
    let day: DiaryViewModel.Day
    let isSelected: Bool
    let isWriting: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(dayNumber)
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .monospacedDigit()
                Text(weekday)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(day.isInProgress ? Color.accentColor : .secondary)
            }
            .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.callout, design: .serif).weight(day.headline == nil ? .regular : .semibold))
                    .foregroundStyle(day.headline == nil ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if isWriting {
                        ProgressView().controlSize(.mini)
                        Text("Writing…")
                    } else {
                        Text(DiaryFormat.duration(day.activeSeconds))
                        if let shape = day.shape {
                            Text("·")
                            Text(shape.label)
                        }
                    }
                }
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.78))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
        }
    }

    private var title: String {
        if let headline = day.headline { return headline }
        return day.isInProgress ? "Today, in progress" : "No entry yet"
    }

    private var dayNumber: String {
        String(WorkDay.calendar.component(.day, from: day.date))
    }

    private var weekday: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: day.date).uppercased()
    }
}

// MARK: - Diary page

private struct DiaryPage: View {
    let diary: WorkDiary
    @ObservedObject var model: DiaryViewModel

    private var date: Date { WorkDay.date(fromKey: diary.dayKey) ?? diary.generatedAt }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if let error = model.errors[diary.dayKey] {
                NoticeBanner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error, showsSettings: false)
            } else if let note = diary.note {
                NoticeBanner(symbol: "info.circle.fill", tint: .blue, text: note, showsSettings: !diary.isWrittenByClaude)
            }
            EntryPaper(paragraphs: diary.entry)
            HStack(alignment: .top, spacing: 18) {
                if !diary.highlights.isEmpty {
                    HighlightsCard(items: diary.highlights)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                TimeBreakdownCard(stats: diary.stats)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if !diary.timeline.isEmpty {
                TimelineCard(items: diary.timeline)
            }
            if !diary.recognition.isEmpty {
                KindWordsCard(quotes: diary.recognition)
            }
            if !diary.looseEnds.isEmpty {
                LooseEndsCard(items: diary.looseEnds)
            }
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(DiaryFormat.longDate(date).uppercased())
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            Text(diary.headline)
                .font(.system(size: 36, weight: .bold, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let shape = diary.dayShape {
                    StatChip(symbol: shape.symbol, text: shape.label, tint: .accentColor)
                }
                StatChip(symbol: "clock", text: "\(DiaryFormat.duration(diary.stats.activeSeconds)) worked")
                if let first = diary.stats.firstActivity, let last = diary.stats.lastActivity {
                    StatChip(symbol: "sun.horizon", text: "\(DiaryFormat.time(first)) – \(DiaryFormat.time(last))")
                }
                if diary.stats.longestStretchSeconds >= 1200 {
                    StatChip(symbol: "bolt", text: "\(DiaryFormat.duration(diary.stats.longestStretchSeconds)) longest stretch")
                }
            }
            .padding(.top, 2)
        }
    }

    private var footer: some View {
        let isWriting = model.writing.contains(diary.dayKey)
        return HStack(spacing: 10) {
            Image(systemName: diary.isWrittenByClaude ? "sparkles" : "list.bullet.rectangle")
            Text(authorLine)
                .lineLimit(1)
            Spacer()
            Button("Copy") { copyMarkdown() }
                .help("Copy this entry as Markdown")
            Button("Show in Journal") {
                JournalWindowController.shared.show(recorder: JournalStore.shared.recorder, dayKey: diary.dayKey)
            }
            Button {
                model.write(diary.dayKey)
            } label: {
                if isWriting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Writing…")
                    }
                } else {
                    Text(diary.isWrittenByClaude ? "Rewrite" : "Write with Claude")
                }
            }
            .disabled(isWriting)
        }
        .font(.system(.caption, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    private var authorLine: String {
        let when = DiaryFormat.timestamp(diary.generatedAt)
        if let model = diary.model {
            return "Written by \(DiaryFormat.modelName(model)) from your activity log · \(when)"
        }
        return "Assembled on this Mac from your activity log · \(when)"
    }

    private func copyMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(DiaryStore.markdown(for: diary), forType: .string)
    }
}

// MARK: - Page pieces

private struct StatChip: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(.primary.opacity(0.8))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(.thinMaterial))
        .overlay(Capsule(style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

private struct NoticeBanner: View {
    let symbol: String
    let tint: Color
    let text: String
    let showsSettings: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(.callout, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if showsSettings {
                Button("Open Settings") { SettingsWindowController.shared.show() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.2), lineWidth: 0.5))
    }
}

/// The entry itself, set in a serif on a warm paper card.
private struct EntryPaper: View {
    let paragraphs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 17, design: .serif))
                    .lineSpacing(7)
                    .foregroundStyle(Color(red: 0.16, green: 0.15, blue: 0.14))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 1.0, green: 0.992, blue: 0.972).opacity(0.94))
                .shadow(color: .black.opacity(0.09), radius: 18, x: 0, y: 8)
                .shadow(color: .black.opacity(0.04), radius: 2, x: 0, y: 1)
        }
        .overlay(alignment: .leading) {
            // A notebook margin rule.
            Rectangle()
                .fill(Color(red: 0.93, green: 0.45, blue: 0.45).opacity(0.35))
                .frame(width: 1.5)
                .padding(.vertical, 18)
                .padding(.leading, 18)
        }
    }
}

private struct CardTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(.primary)
    }
}

private struct HighlightsCard: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Highlights", symbol: "checkmark.seal")
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.02, green: 0.59, blue: 0.41))
                    Text(item)
                        .font(.system(.body, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, padding: 18)
    }
}

private struct TimeBreakdownCard: View {
    let stats: DayStats

    private var categories: [(category: FrameCategory, seconds: Double)] {
        stats.categoriesByTime.filter { $0.seconds >= 60 }
    }

    var body: some View {
        let total = max(categories.reduce(0) { $0 + $1.seconds }, 1)
        return VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Where the time went", symbol: "chart.bar.xaxis")

            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(categories, id: \.category) { item in
                        Rectangle()
                            .fill(CategoryPalette.color(item.category))
                            .frame(width: max(2, (geo.size.width - CGFloat(categories.count) * 2) * item.seconds / total))
                    }
                }
                .clipShape(Capsule(style: .continuous))
            }
            .frame(height: 10)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(categories.prefix(5), id: \.category) { item in
                    HStack(spacing: 8) {
                        Circle().fill(CategoryPalette.color(item.category)).frame(width: 8, height: 8)
                        Text(item.category.display)
                        Spacer()
                        Text(DiaryFormat.duration(item.seconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(.callout, design: .rounded))
                }
            }

            if !stats.topActivities.isEmpty {
                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(stats.topActivities.prefix(4), id: \.self) { activity in
                        HStack(spacing: 8) {
                            CategoryChip(category: activity.category, size: 18, cornerRadius: 5)
                            Text(activity.name)
                                .lineLimit(1)
                            Spacer()
                            Text(DiaryFormat.duration(activity.seconds))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(.callout, design: .rounded))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, padding: 18)
    }
}

private struct TimelineCard: View {
    let items: [WorkDiary.TimelineItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Timeline", symbol: "clock.arrow.circlepath")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    TimelineRow(item: item, isLast: index == items.count - 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, padding: 18)
    }
}

private struct TimelineRow: View {
    let item: WorkDiary.TimelineItem
    let isLast: Bool

    var body: some View {
        let color = CategoryPalette.color(item.category)
        HStack(alignment: .top, spacing: 14) {
            Text(item.start)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
                .padding(.top, 1)

            VStack(spacing: 0) {
                Circle()
                    .fill(color)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: color.opacity(0.4), radius: 3)
                    .padding(.top, 4)
                if !isLast {
                    Rectangle()
                        .fill(color.opacity(0.25))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 12)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                    Text("\(item.start)–\(item.end)")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, isLast ? 0 : 18)

            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct KindWordsCard: View {
    let quotes: [WorkDiary.Quote]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Kind words", symbol: "quote.bubble")
            ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\u{201C}\(quote.text)\u{201D}")
                        .font(.system(.title3, design: .serif))
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(attribution(quote))
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(quote.level == .major ? Color.yellow : Color.accentColor.opacity(0.5))
                        .frame(width: 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, padding: 18)
    }

    private func attribution(_ quote: WorkDiary.Quote) -> String {
        var parts: [String] = []
        if let speaker = quote.speaker { parts.append("— \(speaker)") }
        parts.append(DiaryFormat.time(quote.at))
        if let app = quote.app { parts.append(app) }
        return parts.joined(separator: " · ")
    }
}

private struct LooseEndsCard: View {
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Pick up next", symbol: "arrow.turn.down.right")
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(item)
                        .font(.system(.body, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, padding: 18)
    }
}

// MARK: - Other states

/// Today: the page fills in after the day ends.
private struct InProgressPage: View {
    let day: DiaryViewModel.Day

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let cell = JournalStore.shared.cell(for: day.date)
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("TODAY · \(DiaryFormat.longDate(day.date).uppercased())")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .tracking(1.4)
                        .foregroundStyle(.secondary)
                    Text("Today's page is still being written")
                        .font(.system(size: 34, weight: .bold, design: .serif))
                    Text(scheduleLine)
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 14) {
                    bigStat("Worked so far", DiaryFormat.duration(cell.totalDuration))
                    bigStat("Started", cell.firstActivity.map(DiaryFormat.time) ?? "—")
                    bigStat("Sessions", "\(cell.sessions.count + (cell.live != nil ? 1 : 0))")
                }
            }
        }
    }

    private var scheduleLine: String {
        let cutoff = WorkDay.interval(forDay: day.date).end
        var c = DateComponents()
        c.hour = Preferences.diaryNotificationHour
        c.minute = Preferences.diaryNotificationMinute
        let notifyAt = Calendar.current.date(from: c).map(DiaryFormat.time) ?? "9:00"
        return "WorkTimeLaps writes it after the day ends at \(DiaryFormat.time(cutoff)), and it arrives at \(notifyAt)."
    }

    private func bigStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, padding: 18)
    }
}

/// A finished day without an entry (older than the automatic window, or
/// every attempt failed).
private struct MissingEntryPage: View {
    let day: DiaryViewModel.Day
    @ObservedObject var model: DiaryViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.closed")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("No entry for \(DiaryFormat.longDate(day.date)) yet")
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .multilineTextAlignment(.center)
            Text("You worked \(DiaryFormat.duration(day.activeSeconds)) that day.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
            if model.writing.contains(day.key) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing…")
                }
                .padding(.top, 6)
            } else {
                Button("Write it now") { model.write(day.key) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
            if let error = model.errors[day.key] ?? DiaryStore.status(for: day.key).lastError {
                Text(error)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }
}

private struct EmptyDiaryState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "book.closed")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(.secondary)
            Text("Your diary starts tomorrow morning")
                .font(.system(size: 26, weight: .semibold, design: .serif))
            Text("Record a day of work and its page is written for you after the day ends.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window controller

/// Lazy singleton wrapper, same pattern as the Journal and Highlights
/// windows. Pinned to the light appearance like the Journal.
@MainActor
final class DiaryWindowController {

    static let shared = DiaryWindowController()

    private var window: NSWindow?

    private init() {}

    /// Opens the Diary, selecting `dayKey` if given.
    func show(dayKey: String? = nil) {
        let model = DiaryViewModel.shared
        model.reload()
        if let dayKey {
            model.selection = dayKey
        }

        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: DiaryRootView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Diary"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1140, height: 840))
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the most recent finished day.
    func showLatest() {
        DiaryViewModel.shared.reload()
        show(dayKey: DiaryViewModel.shared.latestKey)
    }
}
