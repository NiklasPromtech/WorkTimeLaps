import AppKit
import SwiftUI

/// The Highlights window — the brag-sheet view of WorkTimeLaps. Shows
/// every recognition the analyzer captured (compliments, callouts,
/// thank-yous worth quoting), grouped by period, ranked by who said it
/// and what work it was tied to. Standalone window, opened from the
/// menu bar with ⌘H.

// MARK: - Period selector

/// How far back the dashboard looks when summing recognitions. The
/// longest reasonable horizon for a single review cycle is "this year",
/// so we don't bother with multi-year aggregations yet — the file is
/// preserved long-term so future-us can extend.
enum HighlightPeriod: String, CaseIterable, Identifiable, Hashable {
    case last7    = "7d"
    case last30   = "30d"
    case last90   = "90d"
    case yearToDate = "ytd"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .last7:      return "7 days"
        case .last30:     return "30 days"
        case .last90:     return "90 days"
        case .yearToDate: return "Year"
        }
    }

    /// Returns the start..<end window (lower-bound inclusive,
    /// upper-bound exclusive). End is always "now" so the period rolls
    /// forward in real time.
    func range(now: Date = Date()) -> ClosedRange<Date> {
        let cal = Calendar.current
        switch self {
        case .last7:
            let start = cal.date(byAdding: .day, value: -7, to: now) ?? now
            return start...now
        case .last30:
            let start = cal.date(byAdding: .day, value: -30, to: now) ?? now
            return start...now
        case .last90:
            let start = cal.date(byAdding: .day, value: -90, to: now) ?? now
            return start...now
        case .yearToDate:
            let comps = cal.dateComponents([.year], from: now)
            let start = cal.date(from: comps) ?? now
            return start...now
        }
    }
}

// MARK: - Recognition store wrapper

/// Observable wrapper around the file-backed RecognitionStore. Reloads
/// from disk when the recorder appends a new entry; the views observe
/// this so the brag sheet refreshes live during recording.
@MainActor
final class HighlightsStore: ObservableObject {

    static let shared = HighlightsStore()

    @Published private(set) var entries: [Recognition] = []
    private var observer: NSObjectProtocol?

    private init() {
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: .worktimelapsRecognitionAppended,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in HighlightsStore.shared.reload() }
        }
    }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }

    func reload() {
        entries = RecognitionStore.loadAll()
    }

    func entries(in period: HighlightPeriod, now: Date = Date()) -> [Recognition] {
        let r = period.range(now: now)
        return entries.filter { $0.capturedAt >= r.lowerBound && $0.capturedAt <= r.upperBound }
    }
}

// MARK: - Root view

struct HighlightsRootView: View {
    @ObservedObject var store: HighlightsStore
    @State private var period: HighlightPeriod = .last30

    private var visible: [Recognition] {
        store.entries(in: period)
    }

    var body: some View {
        ZStack {
            BackgroundCanvas()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    heroStats
                    if !visible.isEmpty {
                        HStack(alignment: .top, spacing: 16) {
                            topVoices
                            topProjects
                        }
                    }
                    quoteFeed
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
        }
        .frame(minWidth: 980, minHeight: 720)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Highlights")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text("Moments worth remembering — for your next review.")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HighlightPeriodPicker(selection: $period)
        }
    }

    // MARK: Hero

    private var heroStats: some View {
        let totalCount = visible.count
        let majorCount = visible.filter { $0.level == .major }.count
        let specificCount = visible.filter { $0.level == .specific }.count
        let weakCount = visible.filter { $0.level == .weak }.count

        return VStack(alignment: .leading, spacing: 12) {
            Text("\(totalCount)")
                .font(.system(size: 64, design: .rounded).weight(.bold).monospacedDigit())
                .contentTransition(.numericText(value: Double(totalCount)))
            Text(totalCount == 1
                 ? "moment worth remembering in the last \(period.label)."
                 : "moments worth remembering in the last \(period.label).")
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(.secondary)

            if totalCount > 0 {
                HStack(spacing: 16) {
                    if majorCount > 0    { levelBadge(label: "major",    count: majorCount,    tint: Color.yellow) }
                    if specificCount > 0 { levelBadge(label: "specific", count: specificCount, tint: Color.blue) }
                    if weakCount > 0     { levelBadge(label: "mention",  count: weakCount,     tint: Color.gray) }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20, padding: 24)
    }

    private func levelBadge(label: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text("\(count)").monospacedDigit().font(.system(.callout, design: .rounded).weight(.semibold))
            Text(label).font(.system(.callout, design: .rounded)).foregroundStyle(.secondary)
        }
    }

    // MARK: Top voices

    private var topVoices: some View {
        let speakers = aggregatedSpeakers(visible).prefix(6)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Top voices")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            if speakers.isEmpty {
                Text("Recognition without an attributed speaker shows up here once we can extract names.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(speakers.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(LinearGradient(colors: [Color.indigo, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Text(item.speaker.prefix(1).uppercased())
                                    .font(.system(.caption2, design: .rounded).weight(.bold))
                                    .foregroundStyle(.white)
                            )
                        Text(item.speaker)
                            .font(.system(.callout, design: .rounded).weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text("\(item.count)")
                            .font(.system(.callout, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: Top projects

    private var topProjects: some View {
        let projects = aggregatedActivities(visible).prefix(6)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Top projects")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            if projects.isEmpty {
                Text("Recognition tied to specific work shows up here as your activity vocabulary builds out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(projects.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 10) {
                        // Use the cluster's most-common category as the chip color.
                        let chipCat = dominantCategory(for: item.activity, in: visible) ?? .other
                        CategoryChip(category: chipCat, size: 22, cornerRadius: 6)
                        Text(item.activity)
                            .font(.system(.callout, design: .rounded).weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text("\(item.count)")
                            .font(.system(.callout, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    // MARK: Quote feed

    private var quoteFeed: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Receipts")
                .font(.system(.title3, design: .rounded).weight(.semibold))

            if visible.isEmpty {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(visible) { rec in
                        RecognitionCard(rec: rec)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No recognition captured yet for this window.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
            Text("As clients, peers, and managers say nice things on screen, they'll start showing up here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .glassCard(cornerRadius: 18, padding: 24)
    }

    // MARK: Aggregations

    private func aggregatedSpeakers(_ entries: [Recognition]) -> [(speaker: String, count: Int, weight: Int)] {
        var bag: [String: (count: Int, weight: Int)] = [:]
        for r in entries {
            guard let s = r.speaker, !s.isEmpty else { continue }
            var current = bag[s] ?? (0, 0)
            current.count += 1
            current.weight += r.level.weight
            bag[s] = current
        }
        return bag
            .map { (speaker: $0.key, count: $0.value.count, weight: $0.value.weight) }
            .sorted(by: { $0.weight > $1.weight })
    }

    private func aggregatedActivities(_ entries: [Recognition]) -> [(activity: String, count: Int, weight: Int)] {
        var bag: [String: (count: Int, weight: Int)] = [:]
        for r in entries {
            guard let a = r.activity, !a.isEmpty else { continue }
            var current = bag[a] ?? (0, 0)
            current.count += 1
            current.weight += r.level.weight
            bag[a] = current
        }
        return bag
            .map { (activity: $0.key, count: $0.value.count, weight: $0.value.weight) }
            .sorted(by: { $0.weight > $1.weight })
    }

    private func dominantCategory(for activity: String, in entries: [Recognition]) -> FrameCategory? {
        var counts: [FrameCategory: Int] = [:]
        for r in entries where r.activity == activity {
            counts[r.category, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}

// MARK: - Period picker

private struct HighlightPeriodPicker: View {
    @Binding var selection: HighlightPeriod

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HighlightPeriod.allCases) { p in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        selection = p
                    }
                } label: {
                    Text(p.label)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .frame(minWidth: 44)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            if selection == p {
                                Capsule(style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [Color.white, Color.white.opacity(0.85)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ))
                                    .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 1)
                            }
                        }
                        .foregroundStyle(selection == p ? .primary : .secondary)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            Capsule(style: .continuous).fill(.thinMaterial)
        }
        .overlay {
            Capsule(style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

// MARK: - Recognition card

/// Single quote card. The headline is the recognition itself in
/// quotable typography; underneath is the source row (speaker · time ·
/// app · activity tag). Designed so the card alone could anchor a
/// brag-sheet entry without anything else.
private struct RecognitionCard: View {
    let rec: Recognition

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Quote — large rounded type so each card reads as the
            // hero of its own row. Limit to 5 lines so multi-paragraph
            // quotes don't blow up the layout.
            HStack(alignment: .top, spacing: 12) {
                levelMark
                Text("\u{201C}\(rec.quote)\u{201D}")
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            // Source strip — speaker, time, source app, activity.
            HStack(spacing: 10) {
                if let speaker = rec.speaker, !speaker.isEmpty {
                    Text(speaker)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                }
                if rec.speaker?.isEmpty == false {
                    Text("·").foregroundStyle(.tertiary)
                }
                Text(formatDate(rec.capturedAt))
                    .font(.system(.callout, design: .rounded))
                if let app = rec.sourceAppName, !app.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(app).font(.system(.callout, design: .rounded))
                }
                Spacer(minLength: 0)
                if let activity = rec.activity, !activity.isEmpty {
                    HStack(spacing: 6) {
                        CategoryChip(category: rec.category, size: 18, cornerRadius: 5)
                        Text(activity)
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .lineLimit(1)
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
        .glassCard(cornerRadius: 16, padding: 18)
    }

    @ViewBuilder
    private var levelMark: some View {
        let tint: Color = {
            switch rec.level {
            case .major:    return .yellow
            case .specific: return .blue
            case .weak:     return .gray
            case .none:     return .gray.opacity(0.5)
            }
        }()
        Image(systemName: rec.level == .major ? "star.fill" : "quote.opening")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background {
                Circle()
                    .fill(LinearGradient(
                        colors: [tint, tint.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
            }
            .shadow(color: tint.opacity(0.4), radius: 4, x: 0, y: 1)
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: d)
    }
}

// MARK: - Window controller

/// Lazy singleton wrapper for the Highlights window — same pattern as
/// SettingsWindowController and JournalWindowController. Pinned to the
/// light appearance so the BackgroundCanvas's blobs read clearly.
@MainActor
final class HighlightsWindowController {

    static let shared = HighlightsWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: HighlightsRootView(store: HighlightsStore.shared)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "WorkTimeLaps Highlights"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1080, height: 800))
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
