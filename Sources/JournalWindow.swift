import AppKit
import SwiftUI
import AVFoundation
import AVKit
import Charts

// MARK: - Category colors

/// Centralized color mapping for FrameCategory. Used by the day timeline,
/// session row chips, and the session-detail category bar. Kept here (rather
/// than on FrameCategory itself) because it's presentation, not data —
/// FrameCategory is used by non-UI code too (analyzer, journal).
///
/// Palette is a Tailwind-leaning set tuned to read well on the Journal's
/// light background — calmer mid-saturation hues that don't fight each
/// other when stacked side-by-side in the donut and bar legend.
enum CategoryPalette {
    static func color(_ c: FrameCategory) -> Color {
        switch c {
        case .coding:   return Color(red: 0.31, green: 0.27, blue: 0.90) // indigo-600
        case .writing:  return Color(red: 0.02, green: 0.59, blue: 0.41) // emerald-600
        case .email:    return Color(red: 0.96, green: 0.62, blue: 0.04) // amber-500
        case .chat:     return Color(red: 0.93, green: 0.28, blue: 0.60) // pink-500
        case .meeting:  return Color(red: 0.55, green: 0.36, blue: 0.96) // violet-500
        case .browsing: return Color(red: 0.39, green: 0.45, blue: 0.55) // slate-500
        case .design:   return Color(red: 0.85, green: 0.27, blue: 0.94) // fuchsia-500
        case .terminal: return Color(red: 0.03, green: 0.57, blue: 0.70) // cyan-600
        case .reading:  return Color(red: 0.71, green: 0.33, blue: 0.04) // amber-700 (earthy)
        case .media:    return Color(red: 0.92, green: 0.70, blue: 0.03) // yellow-500
        case .other:    return Color(red: 0.58, green: 0.64, blue: 0.72) // slate-400
        }
    }

    /// SF Symbol used to mark the category in chips, row icons, and the
    /// metadata header. Picked to read at small sizes (12–16pt).
    static func symbol(_ c: FrameCategory) -> String {
        switch c {
        case .coding:   return "chevron.left.forwardslash.chevron.right"
        case .writing:  return "text.alignleft"
        case .email:    return "envelope.fill"
        case .chat:     return "bubble.left.and.bubble.right.fill"
        case .meeting:  return "video.fill"
        case .browsing: return "safari.fill"
        case .design:   return "paintbrush.pointed.fill"
        case .terminal: return "terminal.fill"
        case .reading:  return "book.fill"
        case .media:    return "play.rectangle.fill"
        case .other:    return "square.dashed"
        }
    }
}

/// Small gradient-filled chip with an SF Symbol inside. Used as the
/// visual anchor for category-keyed rows (activity stream, metadata
/// header). Light shadow tinted to the chip's color gives it a faint
/// glow against the glass card.
struct CategoryChip: View {
    let category: FrameCategory
    var size: CGFloat = 32
    var cornerRadius: CGFloat = 9

    var body: some View {
        let color = CategoryPalette.color(category)
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(
                    colors: [color, color.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
            Image(systemName: CategoryPalette.symbol(category))
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.35), radius: size * 0.2, x: 0, y: size * 0.08)
    }
}

// MARK: - Formatting helpers

enum JournalFormat {
    /// "4h 12m" / "42m" / "—".
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// "3:42 PM".
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// "Tuesday, Apr 22".
    static func longDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }

    /// "Apr 20 – 26, 2026".
    static func weekRange(start: Date, end: Date) -> String {
        let cal = Calendar.current
        let fYear = DateFormatter()
        fYear.dateFormat = "yyyy"

        let sameMonth = cal.component(.month, from: start) == cal.component(.month, from: end)
        let f1 = DateFormatter()
        f1.dateFormat = sameMonth ? "MMM d" : "MMM d"
        let f2 = DateFormatter()
        f2.dateFormat = sameMonth ? "d" : "MMM d"
        return "\(f1.string(from: start)) – \(f2.string(from: end)), \(fYear.string(from: end))"
    }
}

// MARK: - Custom video player

/// AVPlayerLayer-based video well, no chrome, no controls. Wrapped in
/// NSViewRepresentable so it composes naturally with SwiftUI's layout +
/// clipShape + shadow modifiers. We pair it with a separate
/// `VideoControlBar` rendered in SwiftUI directly below — moving the
/// controls out of the video itself was specifically requested, and it
/// also lets us style them to match the rest of the app.
private struct VideoLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = PlayerHostingNSView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.wantsLayer = true   // AppKit will call makeBackingLayer()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PlayerHostingNSView else { return }
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

private final class PlayerHostingNSView: NSView {
    let playerLayer = AVPlayerLayer()

    /// Hand AppKit our AVPlayerLayer as the view's backing layer instead
    /// of letting the framework create a default CALayer that we'd then
    /// have to swap. This is the canonical pattern for layer-hosting
    /// views and avoids races between auto-layer creation and our
    /// override.
    override func makeBackingLayer() -> CALayer {
        return playerLayer
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

/// Controls strip for the custom video player. Play/pause + times + a
/// gradient-filled scrubber. Observes the AVPlayer with its own periodic
/// time observer (separate from the cursor observer in SessionDetailView)
/// so play state and current time stay in sync without coupling the two.
private struct VideoControlBar: View {
    let player: AVPlayer

    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var scrubFraction: Double = 0
    @State private var observer: Any?

    var body: some View {
        HStack(spacing: 14) {
            playButton

            Text(timeString(displayedSeconds))
                .font(.system(.callout, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            ScrubBar(
                fraction: isScrubbing ? scrubFraction : currentFraction,
                onScrubStart: { isScrubbing = true },
                onScrub:      { f in scrubFraction = f },
                onScrubEnd:   { f in
                    isScrubbing = false
                    seek(toFraction: f)
                }
            )
            .frame(height: 8)

            Text(timeString(duration))
                .font(.system(.callout, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .onAppear { startObserver() }
        .onDisappear { stopObserver() }
    }

    private var displayedSeconds: Double {
        isScrubbing ? scrubFraction * duration : currentTime
    }

    private var currentFraction: Double {
        guard duration > 0, currentTime.isFinite else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    @State private var playButtonHovered = false

    private var playButton: some View {
        Button(action: togglePlay) {
            ZStack {
                Circle()
                    .fill(.thinMaterial)
                    .overlay {
                        // Subtle top-light gradient for a "lit glass" sheen.
                        Circle().fill(LinearGradient(
                            colors: [Color.white.opacity(0.55), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        ))
                    }
                    .overlay {
                        Circle().stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }
                    .shadow(color: Color.black.opacity(playButtonHovered ? 0.14 : 0.10),
                            radius: playButtonHovered ? 8 : 6,
                            x: 0,
                            y: playButtonHovered ? 3 : 2)

                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    // The play triangle is left-heavy; a 1pt nudge makes
                    // it look optically centered inside the circle.
                    .offset(x: isPlaying ? 0 : 1)
            }
            .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Pause" : "Play")
        .onHover { playButtonHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: playButtonHovered)
    }

    private func togglePlay() {
        if player.rate > 0 {
            player.pause()
        } else {
            player.play()
        }
    }

    private func seek(toFraction f: Double) {
        guard duration > 0 else { return }
        let target = CMTime(seconds: f * duration, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func startObserver() {
        // Pull duration immediately if available.
        if let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
            duration = dur
        }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor in
                if seconds.isFinite { currentTime = seconds }
                isPlaying = player.rate > 0
                if duration <= 0,
                   let dur = player.currentItem?.duration.seconds,
                   dur.isFinite, dur > 0 {
                    duration = dur
                }
            }
        }
    }

    private func stopObserver() {
        if let obs = observer { player.removeTimeObserver(obs) }
        observer = nil
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Custom scrubber: a gradient-filled progress capsule that the user can
/// drag or click anywhere along to seek. Replaces the default Slider so
/// the visual language matches the rest of the page (gradient fills,
/// rounded shapes, no platform chrome).
private struct ScrubBar: View {
    let fraction: Double
    let onScrubStart: () -> Void
    let onScrub: (Double) -> Void
    let onScrubEnd: (Double) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.7), Color.accentColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(0, min(geo.size.width, geo.size.width * fraction)))

                // Knob — small filled circle that grows when active.
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: dragging ? 14 : 10, height: dragging ? 14 : 10)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .offset(x: max(0, min(geo.size.width, geo.size.width * fraction)) - (dragging ? 7 : 5))
                    .animation(.easeOut(duration: 0.12), value: dragging)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            onScrubStart()
                        }
                        let f = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                        onScrub(f)
                    }
                    .onEnded { value in
                        let f = max(0, min(1, value.location.x / max(geo.size.width, 1)))
                        dragging = false
                        onScrubEnd(f)
                    }
            )
        }
    }
}

// MARK: - Background canvas

/// Layered window backdrop — a soft diagonal gradient with three blurred
/// color "blobs" that the thin-material cards on top can refract through.
/// This is what unlocks the actual *glass* feel of the cards: without
/// something colorful behind them, `.thinMaterial` just looks like a
/// flat off-white panel.
///
/// Tuned for the light appearance the Journal pins itself to. Colors are
/// pale and saturated only enough to show through the cards as faint
/// tints — not to dominate the view.
struct BackgroundCanvas: View {
    var body: some View {
        ZStack {
            // Base gradient — slightly stronger pastel diagonal than the
            // first pass so the cards on top, even with ultraThinMaterial,
            // pick up real color rather than reading as gray.
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.93, green: 0.91, blue: 0.99), location: 0.0),
                    .init(color: Color(red: 0.92, green: 0.96, blue: 0.99), location: 0.5),
                    .init(color: Color(red: 0.99, green: 0.93, blue: 0.91), location: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Three blurred color circles offstage of the typical card
            // positions. The blur radius is large so they read as glow,
            // not as shapes. Bumped opacities so they actually show
            // through ultraThinMaterial.
            Circle()
                .fill(Color(red: 0.55, green: 0.68, blue: 0.99))
                .frame(width: 760, height: 760)
                .blur(radius: 140)
                .opacity(0.55)
                .offset(x: -260, y: -260)

            Circle()
                .fill(Color(red: 0.99, green: 0.66, blue: 0.82))
                .frame(width: 800, height: 800)
                .blur(radius: 150)
                .opacity(0.50)
                .offset(x: 380, y: 220)

            Circle()
                .fill(Color(red: 0.66, green: 0.96, blue: 0.80))
                .frame(width: 580, height: 580)
                .blur(radius: 130)
                .opacity(0.40)
                .offset(x: 90, y: -380)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Donut chart

/// One slice of the donut, parametrized by start/end fraction (0…1) of the
/// total. Conforms to `Shape` so SwiftUI can interpolate the path between
/// states — `animatableData` exposes both fractions to the animation
/// system, which is how the slice angles tween smoothly as cumulative
/// counts change with the cursor.
private struct DonutSlice: Shape {
    var startFrac: Double
    var endFrac: Double
    let innerRatio: Double
    let insetRadians: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(startFrac, endFrac) }
        set { startFrac = newValue.first; endFrac = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerR = min(rect.width, rect.height) / 2
        let innerR = outerR * innerRatio

        // Convert fractions of a turn into angles, with 0 at the top
        // (12 o'clock) and clockwise progression.
        let startAngleRad = startFrac * 2 * .pi - .pi / 2 + insetRadians
        let endAngleRad   = endFrac   * 2 * .pi - .pi / 2 - insetRadians

        // Skip if inset eats the whole slice (very small wedge).
        guard endAngleRad > startAngleRad else { return path }

        let start = Angle.radians(startAngleRad)
        let end   = Angle.radians(endAngleRad)

        path.addArc(center: center, radius: outerR,
                    startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: innerR,
                    startAngle: end,   endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Self-contained donut chart with full per-slice fill control. Replaces
/// the Swift Charts version because Charts' multi-mark series coloring
/// kept dropping our explicit colors in favor of its default palette.
///
/// Each slice can carry an arbitrary `ShapeStyle` (passed via
/// `AnyShapeStyle`), so callers can hand in radial gradients to give the
/// donut its lit/glowing look — light at the inner edge, full color at
/// the outer.
private struct DonutChart: View {
    /// Pre-ordered list of slices. Caller is responsible for stable
    /// ordering — we don't sort here so the angles don't shuffle frame to
    /// frame as cumulative counts change.
    let slices: [(style: AnyShapeStyle, value: Double)]

    var innerRatio: Double = 0.6
    var insetDegrees: Double = 1.5

    var body: some View {
        let total = slices.reduce(0.0) { $0 + max($1.value, 0) }

        return GeometryReader { geo in
            ZStack {
                if total > 0 {
                    ForEach(0..<slices.count, id: \.self) { i in
                        let preceding = slices.prefix(i).reduce(0.0) { $0 + max($1.value, 0) }
                        let startFrac = preceding / total
                        let endFrac   = (preceding + max(slices[i].value, 0)) / total

                        DonutSlice(
                            startFrac: startFrac,
                            endFrac: endFrac,
                            innerRatio: innerRatio,
                            insetRadians: insetDegrees * .pi / 180
                        )
                        .fill(slices[i].style)
                    }
                } else {
                    // Empty state — neutral ring so the placeholder still
                    // reads as "a donut, just nothing in it yet."
                    let outerR = min(geo.size.width, geo.size.height) / 2
                    let ringWidth = outerR * (1 - innerRatio)
                    Circle()
                        .strokeBorder(Color.gray.opacity(0.18), lineWidth: ringWidth)
                        .padding(ringWidth / 2)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - Glass card

/// Wraps a view in a translucent "glass" panel — rounded rectangle with
/// `thinMaterial` fill, a faint edge stroke, and a soft drop shadow that
/// lifts the card off the BackgroundCanvas. The combination of refractive
/// material, edge highlight, and shadow is what gives the panel its
/// "physical glass on a colored surface" feel.
///
/// The stroke uses `.primary` (which resolves to black in light mode and
/// white in dark mode) so the card edge is readable in either appearance.
/// On the Journal window we pin to light, but Settings still uses the
/// system appearance, so the card has to work both ways.
///
/// Swap to `.glassEffect()` on macOS 26 to get true refractive Liquid
/// Glass instead of the material-based approximation.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                ZStack {
                    // Translucent glass — `ultraThinMaterial` lets the
                    // BackgroundCanvas's color blobs through, which is
                    // the whole reason the card reads as glass and not
                    // as a flat gray panel.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)

                    // Top-light "sheen" — a faint white-to-clear gradient
                    // overlay that mimics how light catches the curve of
                    // a piece of physical glass. Subtle but does most of
                    // the heavy lifting on "this looks like glass."
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                Color.white.opacity(0.04)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottom
                        ))
                        .blendMode(.plusLighter)
                }
                .shadow(color: Color.black.opacity(0.08), radius: 14, x: 0, y: 7)
                .shadow(color: Color.black.opacity(0.04), radius: 3,  x: 0, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(LinearGradient(
                        colors: [
                            Color.white.opacity(0.6),
                            Color.primary.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ), lineWidth: 0.5)
            }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - Back bar

/// Small in-content back button. We draw it ourselves (rather than relying
/// on NavigationStack's auto-chevron) because our NSWindow is created with
/// `contentViewController:` and has no toolbar — so the built-in back button
/// has nowhere to render. The button still pops the navigation stack via
/// `@Environment(\.dismiss)`, so it behaves identically to the system one.
///
/// Styled as a glass-pilled capsule to match the rest of the app's
/// liquid-glass language. Hover state lifts the shadow slightly so the
/// button feels interactive.
private struct BackBar: View {
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(label)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    Capsule(style: .continuous)
                        .fill(.thinMaterial)
                        .shadow(color: Color.black.opacity(hovered ? 0.10 : 0.06),
                                radius: hovered ? 6 : 4,
                                x: 0,
                                y: hovered ? 2 : 1)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .foregroundStyle(.primary)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: [.command])
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
            Spacer()
        }
    }
}

// MARK: - Glass segmented toggle

/// Custom segmented control with a glass-pilled track and a gradient
/// highlight on the selected segment. Replaces the system `Picker` so the
/// Live/All toggle matches the rest of the page.
private struct GlassSegmentedToggle<Option: Hashable>: View {
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        selection = option
                    }
                } label: {
                    Text(label(option))
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .frame(minWidth: 36)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background {
                            if selection == option {
                                Capsule(style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [
                                            Color.white,
                                            Color.white.opacity(0.85)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ))
                                    .shadow(color: .black.opacity(0.10),
                                            radius: 4, x: 0, y: 1)
                            }
                        }
                        .overlay {
                            if selection == option {
                                Capsule(style: .continuous)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                            }
                        }
                        .foregroundStyle(selection == option ? .primary : .secondary)
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            Capsule(style: .continuous)
                .fill(.thinMaterial)
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }
}

// MARK: - Root view

struct JournalRootView: View {
    @ObservedObject var store: JournalStore
    @State private var weekAnchor: Date = Date()

    var body: some View {
        ZStack {
            BackgroundCanvas()

            NavigationStack {
                WeekGridView(store: store, weekAnchor: $weekAnchor)
                    .scrollContentBackground(.hidden)
                    .navigationDestination(for: String.self) { dayKey in
                        DayDetailView(store: store, dayKey: dayKey)
                            .scrollContentBackground(.hidden)
                    }
            }
        }
        .frame(minWidth: 1280, minHeight: 740)
    }
}

// MARK: - Week grid

struct WeekGridView: View {
    @ObservedObject var store: JournalStore
    @Binding var weekAnchor: Date

    private var cells: [JournalStore.DayCell] {
        store.weekCells(containing: weekAnchor)
    }

    private var weekRange: (start: Date, end: Date)? {
        guard let first = cells.first, let last = cells.last else { return nil }
        return (first.date, last.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            HStack(spacing: 12) {
                ForEach(cells) { cell in
                    NavigationLink(value: cell.dateKey) {
                        DayCellView(cell: cell)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Journal")
                    .font(.largeTitle).bold()
                if let range = weekRange {
                    Text(JournalFormat.weekRange(start: range.start, end: range.end))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    shiftWeek(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                Button("This week") {
                    weekAnchor = Date()
                }
                Button {
                    shiftWeek(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(isCurrentWeek)
            }
            .controlSize(.large)
        }
    }

    private var isCurrentWeek: Bool {
        Calendar.current.isDate(weekAnchor, equalTo: Date(), toGranularity: .weekOfYear)
    }

    private func shiftWeek(by delta: Int) {
        guard let next = Calendar.current.date(byAdding: .weekOfYear, value: delta, to: weekAnchor) else { return }
        weekAnchor = next
    }
}

// MARK: - Day cell

struct DayCellView: View {
    let cell: JournalStore.DayCell

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(shortDayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(cell.isToday ? Color.accentColor : .secondary)
                Spacer()
                if cell.live != nil {
                    LiveDot()
                }
            }

            Text(shortDateLabel)
                .font(.title3).bold()
                .foregroundStyle(cell.hasAnyContent ? .primary : .tertiary)

            Spacer(minLength: 0)

            Text(JournalFormat.duration(cell.totalDuration))
                .font(.title2).monospacedDigit()
                .foregroundStyle(cell.hasAnyContent ? .primary : .tertiary)

            if let cat = cell.topCategory, cell.hasAnyContent {
                HStack(spacing: 6) {
                    Circle().fill(CategoryPalette.color(cat)).frame(width: 8, height: 8)
                    Text(cat.display)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(" ")
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(cell.isToday ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.15),
                              lineWidth: cell.isToday ? 1.5 : 1)
        )
    }

    private var shortDayName: String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: cell.date).uppercased()
    }

    private var shortDateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: cell.date)
    }
}

private struct LiveDot: View {
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(pulse ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

// MARK: - Day detail

struct DayDetailView: View {
    @ObservedObject var store: JournalStore
    let dayKey: String
    @Environment(\.dismiss) private var dismiss

    private var cell: JournalStore.DayCell {
        // Rebuild every time the store changes so the live session updates.
        if let parsed = parseDateKey(dayKey) {
            return store.cell(for: parsed)
        }
        return store.cell(for: Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BackBar(label: "Week") { dismiss() }

                header

                if cell.hasAnyContent {
                    DayTimelineChart(cell: cell)
                        .frame(height: 80)
                }

                sessionList

                if !cell.hasAnyContent {
                    Text("No recordings on this day.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 40)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(JournalFormat.longDay(cell.date))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            stat("Recorded", JournalFormat.duration(cell.totalDuration))
            stat("Sessions", "\(cell.sessions.count + (cell.live != nil ? 1 : 0))")
            stat("Frames", "\(cell.totalFrames)")
            if cell.redactedFrames > 0 {
                stat("Redacted", "\(cell.redactedFrames)")
            }
            if cell.totalFrames > 0 {
                stat("Avg engagement", "\(cell.averageEngagement)")
            }
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2).bold().monospacedDigit()
        }
    }

    @ViewBuilder
    private var sessionList: some View {
        if cell.hasAnyContent {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sessions")
                    .font(.headline)

                ForEach(cell.sessions) { digest in
                    NavigationLink {
                        SessionDetailView(store: store, dayKey: dayKey, digest: digest)
                    } label: {
                        SessionRowView(digest: digest)
                    }
                    .buttonStyle(.plain)
                }

                if let live = cell.live {
                    LiveSessionRowView(live: live)
                }
            }
        }
    }

    private func parseDateKey(_ key: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.date(from: key)
    }
}

// MARK: - Day timeline chart

private struct DayTimelineChart: View {
    let cell: JournalStore.DayCell

    private var dayBounds: (start: Date, end: Date) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: cell.date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return (start, end)
    }

    var body: some View {
        let bounds = dayBounds
        Chart {
            ForEach(cell.sessions) { s in
                RectangleMark(
                    xStart: .value("Start", s.startedAt),
                    xEnd: .value("End", s.endedAt),
                    yStart: .value("row", 0),
                    yEnd: .value("row", 1)
                )
                .foregroundStyle(CategoryPalette.color(s.topCategory))
            }
            if let live = cell.live {
                RectangleMark(
                    xStart: .value("Start", live.startedAt),
                    xEnd: .value("End", Date()),
                    yStart: .value("row", 0),
                    yEnd: .value("row", 1)
                )
                .foregroundStyle(Color.red.opacity(0.75))
            }
        }
        .chartXScale(domain: bounds.start...bounds.end)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
    }
}

// MARK: - Session row

struct SessionRowView: View {
    let digest: DayLog.SessionDigest

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
                .frame(width: 80, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(CategoryPalette.color(digest.topCategory)).frame(width: 8, height: 8)
                    Text(digest.topCategory.display)
                        .font(.body).bold()
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("\(JournalFormat.time(digest.startedAt)) – \(JournalFormat.time(digest.endedAt))")
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(JournalFormat.duration(digest.duration))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Label("\(digest.totalFrames)", systemImage: "photo.stack")
                    if digest.redactedFrames > 0 {
                        Label("\(digest.redactedFrames) redacted", systemImage: "eye.slash")
                            .foregroundStyle(.orange)
                    }
                    Label("engagement \(digest.averageEngagement)", systemImage: "gauge.medium")
                    if let note = digest.notes, !note.isEmpty {
                        Label("note", systemImage: "note.text")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        let url = Journal.thumbURL(for: digest)
        if let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(Color.gray.opacity(0.2))
                .overlay(
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                )
        }
    }
}

// MARK: - Activity stream reveal queue

/// Owns the paced "reveal one block at a time" drainer for the Live feed.
///
/// Lives as an `ObservableObject` (reference type) rather than as
/// `@State` inside the panel because the prior approach used
/// `.task(id: visible.count)` which was cancelled-and-restarted on every
/// cursor tick. When the cursor advances faster than the throttle
/// interval (which is normal during fast playback or scrubbing), each
/// in-flight `Task.sleep` got killed before it could fire its
/// increment — so `revealedCount` stayed pinned at 1 even with dozens
/// queued. A reference-typed model lets the drain task run continuously
/// across view recreations, polling `targetCount` (which the panel
/// updates from `onChange`) and incrementing `revealedCount` at its own
/// pace.
@MainActor
private final class ActivityRevealQueue: ObservableObject {
    @Published private(set) var revealedCount: Int = 0
    private var targetCount: Int = 0
    private var drainTask: Task<Void, Never>?

    deinit {
        drainTask?.cancel()
    }

    /// Set how many blocks should eventually be revealed. Triggered from
    /// the panel's `onChange(of: visible.count)`. Snaps `revealedCount`
    /// down on rewind so we never display blocks past the cursor.
    func setTarget(_ newCount: Int) {
        if newCount < revealedCount {
            revealedCount = newCount
        }
        targetCount = newCount
        ensureRunning()
    }

    /// Reset state on view appearance. Called when the panel first
    /// loads so a freshly-opened SessionDetail starts with an empty
    /// feed regardless of any previous panel's drain state.
    func reset() {
        drainTask?.cancel()
        drainTask = nil
        revealedCount = 0
        targetCount = 0
    }

    private func ensureRunning() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self = self {
                let pending = self.targetCount - self.revealedCount
                if pending <= 0 { break }
                let interval = Self.intervalFor(pending: pending)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    self.revealedCount = min(self.revealedCount + 1, self.targetCount)
                }
            }
            self?.drainTask = nil
        }
    }

    /// Adaptive throttle. Faster when the queue is deep so we catch up
    /// quickly after pressing play (or scrubbing forward), slower as we
    /// approach steady-state so each new block actually registers as a
    /// distinct event.
    private static func intervalFor(pending: Int) -> Double {
        switch pending {
        case 20...:    return 0.15
        case 10..<20:  return 0.30
        case 5..<10:   return 0.60
        case 2..<5:    return 1.0
        default:       return 1.5
        }
    }
}

// MARK: - Activity stream panel

/// Right-rail of Session Detail. Two modes — **Live**, which always shows
/// the most-recent N blocks at the top (older ones fade out at the bottom
/// as new entries arrive), and **All**, which is the full scrollable
/// chronological list. The mode picker lives in the panel header.
///
/// Default is Live during interactive playback; non-interactive sessions
/// (no MP4, no cursor) just collapse to All-equivalent.
private struct ActivityStreamPanel: View {

    let blocks: [SessionDetailView.ActivityBlock]
    let cursorTime: Date?
    let hasInteractivePlayback: Bool

    enum Mode: String, CaseIterable, Identifiable {
        case live, all
        var id: String { rawValue }
        var label: String { self == .live ? "Live" : "All" }
    }

    @State private var mode: Mode = .live

    /// Reveal queue — owns `revealedCount` and a long-running drain task
    /// that paces reveals at the adaptive interval. See class comment
    /// for why this is a reference type rather than @State.
    @StateObject private var queue = ActivityRevealQueue()

    private var revealedCount: Int { queue.revealedCount }

    /// Blocks that have already started by the cursor. When playback is
    /// non-interactive (file pruned, no sidecar) we just show all blocks.
    private var visible: [SessionDetailView.ActivityBlock] {
        guard hasInteractivePlayback else { return blocks }
        guard let t = cursorTime else { return [] }
        return blocks.filter { $0.start <= t }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Clip the *content* first so transitions (move-from-top,
        // scale-out) don't paint outside the panel — that was the
        // "ghost row above the header" effect. Doing this before
        // glassCard means the GlassCard's shadow renders OUTSIDE the
        // clip rather than getting clipped along with the content.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassCard()
        // Push every change in eligibility into the reveal queue. The
        // queue's drain task lives on the @StateObject (reference type)
        // so it survives view re-renders and isn't restarted by every
        // cursor tick — the previous .task(id:) approach was getting
        // cancelled mid-sleep before each increment could fire, which
        // is what stuck the feed at "1 visible, 11 waiting forever."
        .onChange(of: visible.count) { _, newCount in
            queue.setTarget(newCount)
        }
        .onAppear {
            // Set target right after the panel appears so the drainer
            // picks up any blocks that already crossed the cursor before
            // the first onChange fired.
            queue.setTarget(visible.count)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Activity stream")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Spacer()
            if !blocks.isEmpty {
                // Live mode shows revealed/total; All mode shows the full
                // eligible count (everything the cursor has reached).
                let shown = mode == .live ? revealedCount : visible.count
                Text("\(shown) of \(blocks.count)")
                    .font(.system(.caption2, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GlassSegmentedToggle(
                options: Mode.allCases,
                label: { $0.label },
                selection: $mode
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        // Live mode hides itself when nothing has been revealed yet.
        // All mode shows everything `visible` regardless of revealedCount.
        let liveEmpty = mode == .live && revealedCount == 0
        let allEmpty  = mode == .all  && visible.isEmpty

        if liveEmpty || allEmpty {
            Text(hasInteractivePlayback
                 ? "Press play to watch the day fill in here."
                 : "No activity data on this session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        } else {
            switch mode {
            case .live: liveFeed
            case .all:  allFeed
            }
        }
    }

    /// Revealed blocks, newest at top, scrollable. Same compactness as
    /// the All feed — Live just gates how *fast* blocks become visible
    /// (via the throttle in `body`) rather than how many can be on
    /// screen at once. Earlier feedback was that capping the live window
    /// at 5 made the panel look mostly-empty above the small group of
    /// cards; a scroll matches the All-mode density the user prefers.
    private var liveFeed: some View {
        let revealed = Array(visible.prefix(revealedCount).reversed())
        let pendingFromCursor = visible.count - revealedCount

        return ScrollView {
            VStack(spacing: 8) {
                if pendingFromCursor > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                        Text("\(pendingFromCursor) waiting").monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                }
                ForEach(revealed) { block in
                    ActivityBlockRow(block: block)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity.combined(with: .scale(scale: 0.92))
                        ))
                }
            }
            .padding(.bottom, 4)
        }
    }

    /// Full list, newest at top, scrollable. Used for scrubbing back
    /// through a long session without losing all-the-rest context.
    private var allFeed: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(visible.reversed())) { block in
                    ActivityBlockRow(block: block)
                }
            }
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Activity block row

/// Row in the activity stream. Anchored by a `CategoryChip` (gradient
/// SF-Symbol square) on the left so the category reads instantly; the
/// activity name + representative summary + metadata strip live to its
/// right. Background is a faint category-tinted glass surface — enough
/// to identify the category at a glance without overwhelming the row.
private struct ActivityBlockRow: View {
    let block: SessionDetailView.ActivityBlock

    var body: some View {
        let tint = CategoryPalette.color(block.topCategory)

        return HStack(alignment: .top, spacing: 12) {
            CategoryChip(category: block.topCategory, size: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(block.activity)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !block.representativeSummary.isEmpty {
                    Text(block.representativeSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                metadataStrip
            }
            .padding(.vertical, 2)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var metadataStrip: some View {
        HStack(spacing: 10) {
            Text("\(JournalFormat.time(block.start)) – \(JournalFormat.time(block.end))")
            Text("·")
            Text(JournalFormat.duration(block.duration))
            Text("·")
            HStack(spacing: 3) {
                Image(systemName: "gauge.medium")
                Text("\(block.meanEngagement)").monospacedDigit()
            }
            if block.redactedCount > 0 {
                Text("·")
                HStack(spacing: 3) {
                    Image(systemName: "eye.slash")
                    Text("\(block.redactedCount)").monospacedDigit()
                }
                .foregroundStyle(.orange)
            }
        }
        .font(.system(.caption, design: .rounded))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Live session row

private struct LiveSessionRowView: View {
    let live: LiveSessionSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.red.opacity(0.15))
                .frame(width: 80, height: 50)
                .overlay(
                    HStack(spacing: 6) {
                        LiveDot()
                        Text("LIVE")
                            .font(.caption2).bold()
                            .foregroundStyle(.red)
                    }
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let cat = live.topCategory {
                        Circle().fill(CategoryPalette.color(cat)).frame(width: 8, height: 8)
                        Text(cat.display).bold()
                    } else {
                        Text("Recording…").bold()
                    }
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text("started \(JournalFormat.time(live.startedAt))")
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(JournalFormat.duration(Date().timeIntervalSince(live.startedAt)))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Label("\(live.totalFrames)", systemImage: "photo.stack")
                    if live.redactedFrames > 0 {
                        Label("\(live.redactedFrames) redacted", systemImage: "eye.slash")
                            .foregroundStyle(.orange)
                    }
                    if let e = live.engagement {
                        Label("engagement \(e)", systemImage: "gauge.medium")
                    }
                }
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Session detail

struct SessionDetailView: View {
    @ObservedObject var store: JournalStore
    let dayKey: String
    let digest: DayLog.SessionDigest
    @Environment(\.dismiss) private var dismiss

    @State private var full: RecordingSession?
    @State private var noteDraft: String = ""
    @State private var notePersisted: String = ""
    @State private var player: AVPlayer?

    /// Number of frames "shown" so far at the current playback time.
    /// 0 = nothing played yet → bars empty + chart cursor at start.
    /// frames.count = video done → bars at final percentages.
    @State private var cursorCount: Int = 0

    /// AVPlayer periodic-time-observer token. Held in @State so we can
    /// remove it on disappear without leaking.
    @State private var timeObserver: Any?

    private var note: String { digest.notes ?? "" }

    /// True when we have frame-level data and a working player to drive
    /// the cursor. Drives whether the bars animate or just show static
    /// totals (e.g. when the MP4 has been pruned by the storage cap).
    private var hasInteractivePlayback: Bool {
        full?.frames.isEmpty == false && player != nil
    }

    private var backLabel: String {
        if let parsed = parseDayKey(dayKey) {
            return JournalFormat.longDay(parsed)
        }
        return "Day"
    }

    /// Width reserved for the activity-stream column on the right. Tuned to
    /// fit a ~3-line summary plus the metadata strip without truncation.
    private static let streamColumnWidth: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BackBar(label: backLabel) { dismiss() }
                .padding(.horizontal, 4)

            HStack(alignment: .top, spacing: 20) {
                leftColumn
                rightColumn
                    .frame(width: Self.streamColumnWidth)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("\(JournalFormat.time(digest.startedAt)) – \(JournalFormat.time(digest.endedAt))")
        .onAppear {
            load()
        }
        .onDisappear {
            stopObservingPlayer()
        }
    }

    /// The main column — video, charts, breakdown, notes. Scrolls
    /// independently of the activity stream so a long note or a tall
    /// engagement chart doesn't push the stream off screen.
    ///
    /// Engagement and category-breakdown sit side-by-side so the donut
    /// is visible above the fold without scrolling. On narrow windows
    /// SwiftUI's HStack keeps both at half-width and lets each render
    /// reasonably; the donut's bar legend wraps gracefully.
    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataHeader
                    .glassCard()

                playerView

                HStack(alignment: .top, spacing: 16) {
                    engagementChart  // glass card applied internally
                    categoryBreakdownChart
                        .glassCard()
                }

                noteEditor
                    .glassCard()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Tiny inset on the inner edge so the cards' drop shadows
            // have somewhere to land before the column boundary.
            .padding(.trailing, 4)
        }
        // Disable the ScrollView's implicit clip so card shadows can
        // bleed out to the right (toward the activity stream column)
        // instead of getting hard-cut at the column edge.
        .scrollClipDisabled()
    }

    /// The activity-stream column. Has its own internal layout — header
    /// row with the Live / All mode picker, then either the recent-N feed
    /// (Live) or the full scrollable list (All).
    private var rightColumn: some View {
        ActivityStreamPanel(
            blocks: clusteredBlocks,
            cursorTime: cursorTime,
            hasInteractivePlayback: hasInteractivePlayback
        )
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Cached cluster of frames into ActivityBlocks. Recomputed per render
    /// (cheap — frame counts here are <few thousand) and shared between the
    /// stream column and any future readers (engagement chart could light
    /// up the active block, etc.).
    private var clusteredBlocks: [ActivityBlock] {
        guard let frames = full?.frames, !frames.isEmpty else { return [] }
        let interval = full?.captureIntervalSec ?? 10
        return clusterActivityBlocks(frames, captureInterval: interval)
    }

    /// Cursor's wall-clock time, derived from cursorCount. Nil when no
    /// frames have played yet (cursorCount == 0).
    private var cursorTime: Date? {
        guard let frames = full?.frames,
              cursorCount > 0,
              cursorCount <= frames.count else { return nil }
        return frames[cursorCount - 1].t
    }

    private func parseDayKey(_ key: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.date(from: key)
    }

    // MARK: Header

    private var metadataHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            CategoryChip(category: digest.topCategory, size: 44, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(digest.topCategory.display)
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Text("·").foregroundStyle(.secondary)
                    Text(JournalFormat.duration(digest.duration))
                        .font(.system(.title3, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Label("\(digest.totalFrames) frames", systemImage: "photo.stack")
                    if digest.redactedFrames > 0 {
                        Label("\(digest.redactedFrames) redacted", systemImage: "eye.slash")
                            .foregroundStyle(.orange)
                    }
                    Label("engagement \(digest.averageEngagement)", systemImage: "gauge.medium")
                }
                .font(.system(.caption, design: .rounded))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: Player

    @ViewBuilder
    private var playerView: some View {
        let url = Journal.videoURL(for: digest)
        if let player = player {
            // Custom video well — AVPlayerLayer with no chrome — paired
            // with our own controls strip directly below. Heavier shadow
            // than the other cards so the video reads as the page's
            // hero element.
            VStack(spacing: 14) {
                VideoLayerView(player: player)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                    .shadow(color: Color.black.opacity(0.18), radius: 22, x: 0, y: 10)
                    .shadow(color: Color.black.opacity(0.05), radius: 4,  x: 0, y: 2)

                VideoControlBar(player: player)
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            // Transient — load() hasn't run yet. Placeholder avoids
            // creating a throwaway AVPlayer on the first render.
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .frame(height: 420)
                .overlay(ProgressView())
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .frame(height: 320)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Video file not found — it may have been pruned by the storage cap.")
                            .foregroundStyle(.secondary)
                    }
                )
        }
    }

    // MARK: Activity stream

    /// One run of consecutive frames sharing the same activity label.
    /// Computed lazily from the loaded sidecar; fed into the chat-bubble
    /// stream that fills up as playback advances.
    struct ActivityBlock: Identifiable {
        let id: Int64
        let activity: String
        let representativeSummary: String
        let start: Date
        let end: Date
        let frameCount: Int
        let redactedCount: Int
        let meanEngagement: Int
        let topCategory: FrameCategory
        var duration: TimeInterval { max(end.timeIntervalSince(start), 0) }
    }

    /// Clusters consecutive frames with the same `activity` (case-insensitive,
    /// nil-safe) into blocks. A nil/empty activity falls back to the
    /// category's display name so older sidecars (pre-Phase 9) still render
    /// usefully — they just produce one block per category run instead of
    /// the more granular tool-level grouping.
    private func clusterActivityBlocks(_ frames: [FrameEntry], captureInterval: TimeInterval) -> [ActivityBlock] {
        guard !frames.isEmpty else { return [] }

        func name(_ f: FrameEntry) -> String {
            let raw = (f.activity ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? f.category.display : raw
        }
        func key(_ f: FrameEntry) -> String { name(f).lowercased() }

        var blocks: [ActivityBlock] = []
        var startIdx = 0
        for i in 1...frames.count {
            let endHere = (i == frames.count) || key(frames[i]) != key(frames[startIdx])
            guard endHere else { continue }

            let slice = Array(frames[startIdx..<i])
            let first = slice.first!
            let last = slice.last!

            // Most-common summary across the slice; falls back to the
            // first frame's summary if every frame's text is unique.
            var summaryCounts: [String: Int] = [:]
            for f in slice where !f.summary.isEmpty {
                summaryCounts[f.summary, default: 0] += 1
            }
            let representative = summaryCounts.max(by: { $0.value < $1.value })?.key
                ?? first.summary

            // Top category in the slice.
            var catCounts: [FrameCategory: Int] = [:]
            for f in slice { catCounts[f.category, default: 0] += 1 }
            let top = catCounts.max(by: { $0.value < $1.value })?.key ?? .other

            let totalEng = slice.reduce(0) { $0 + $1.engagementSmoothed }
            let mean = slice.isEmpty ? 0 : totalEng / slice.count
            let redacted = slice.filter { $0.redacted }.count

            // End of block = last frame's timestamp + one capture interval,
            // so a single-frame block still has a non-zero visible duration.
            let end = last.t.addingTimeInterval(captureInterval)

            blocks.append(ActivityBlock(
                id: first.i,
                activity: name(first),
                representativeSummary: representative,
                start: first.t,
                end: end,
                frameCount: slice.count,
                redactedCount: redacted,
                meanEngagement: mean,
                topCategory: top
            ))
            startIdx = i
        }
        return blocks
    }

    // MARK: Engagement chart

    @ViewBuilder
    private var engagementChart: some View {
        if let frames = full?.frames, !frames.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Engagement over time")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Chart {
                    ForEach(frames, id: \.i) { frame in
                        LineMark(
                            x: .value("Time", frame.t),
                            y: .value("Engagement", frame.engagementSmoothed)
                        )
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.monotone)
                    }
                    if hasInteractivePlayback,
                       cursorCount > 0,
                       cursorCount <= frames.count {
                        RuleMark(x: .value("Now", frames[cursorCount - 1].t))
                            .foregroundStyle(Color.red.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartYScale(domain: 0...100)
                .frame(maxHeight: .infinity)
                .animation(.linear(duration: 0.1), value: cursorCount)
            }
            // Match the height of the category breakdown (donut + 11-row
            // legend ≈ 200pt of inner content). Using a fixed height
            // guarantees the two side-by-side cards match visually.
            .frame(height: 220)
            .glassCard()
        }
        // No `else` — when there's no sidecar yet we just don't render
        // the card at all, otherwise we'd get an empty floating glass
        // rectangle with no content.
    }

    // MARK: Category breakdown

    /// Final totals across the whole session, sorted desc. Drives the row
    /// order — kept stable so bars don't shuffle around as the video plays;
    /// only their widths animate.
    private var totalsSorted: [(FrameCategory, Int)] {
        digest.categoryCounts
            .compactMap { (key, val) -> (FrameCategory, Int)? in
                guard let cat = FrameCategory(rawValue: key) else { return nil }
                return (cat, val)
            }
            .sorted(by: { $0.1 > $1.1 })
    }

    /// Cumulative count of each category in the frames played up to the
    /// cursor. When `hasInteractivePlayback` is false (sidecar missing or
    /// MP4 pruned) we just return the digest totals so the static view
    /// still works.
    private var cumulativeCounts: [FrameCategory: Int] {
        if hasInteractivePlayback, let frames = full?.frames {
            let upTo = max(0, min(cursorCount, frames.count))
            var counts: [FrameCategory: Int] = [:]
            for f in frames.prefix(upTo) {
                counts[f.category, default: 0] += 1
            }
            return counts
        }
        // Fallback: full totals from the digest.
        var counts: [FrameCategory: Int] = [:]
        for (key, val) in digest.categoryCounts {
            if let cat = FrameCategory(rawValue: key) { counts[cat] = val }
        }
        return counts
    }

    /// Top N + "Other" lump used to drive the donut. Keeping the slice
    /// count low (5 + Other) keeps each wedge readable even when the long
    /// tail of categories has lots of tiny frames.
    private static let donutTopCount = 5

    /// Donut data, with all "below top N" categories merged into a single
    /// `.other` slice. Values are cumulative-up-to-cursor counts, so the
    /// slices grow as playback advances.
    private var donutData: [(cat: FrameCategory, count: Int)] {
        let totals = totalsSorted.map { ($0.0, cumulativeCounts[$0.0] ?? 0) }
        let top = Array(totals.prefix(Self.donutTopCount))
        let restSum = totals.dropFirst(Self.donutTopCount).reduce(0) { $0 + $1.1 }
        var result = top
        if restSum > 0 {
            // Avoid clobbering an existing top-N "other" wedge (rare).
            if let existingIdx = result.firstIndex(where: { $0.0 == .other }) {
                result[existingIdx] = (.other, result[existingIdx].1 + restSum)
            } else {
                result.append((.other, restSum))
            }
        }
        return result.filter { $0.1 > 0 }
    }

    /// Largest cumulative slice right now, plus its share of total played
    /// frames. Drives the donut's center text. Nil before any frame plays.
    private var dominantCumulative: (cat: FrameCategory, frac: Double)? {
        let played = cumulativeCounts.values.reduce(0, +)
        guard played > 0 else { return nil }
        guard let best = cumulativeCounts.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, Double(best.value) / Double(played))
    }

    /// Donut + bar legend. Donut animates dynamically as cumulative angles
    /// rebalance; bars sit underneath as the precise readout.
    private var categoryBreakdownChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Category breakdown")
                .font(.system(.title3, design: .rounded).weight(.semibold))

            let totals = totalsSorted

            if totals.isEmpty {
                Text("No category data.").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    donut
                        .frame(width: 150, height: 150)
                    barLegend(totals: totals)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: cursorCount)
            }
        }
        // Same fixed inner height as engagementChart so the two cards
        // align in the side-by-side HStack above. 220pt accommodates
        // the donut (150) plus comfortable padding around it, and the
        // bar legend wraps naturally to fit.
        .frame(height: 220)
    }

    /// The donut itself. A custom `DonutChart` (SwiftUI Path / Shape)
    /// rather than Swift Charts — see comment on `DonutChart` for why.
    /// Each slice fills with a radial gradient from a lighter inner ring
    /// to the full category color at the outer edge, which is what gives
    /// the donut its "lit" Mac-app look instead of looking like flat
    /// pie-chart wedges.
    private var donut: some View {
        ZStack {
            DonutChart(
                slices: donutData.map { item in
                    let base = CategoryPalette.color(item.cat)
                    let gradient = RadialGradient(
                        colors: [base.opacity(0.55), base],
                        center: .center,
                        startRadius: 30,
                        endRadius: 100
                    )
                    return (style: AnyShapeStyle(gradient), value: Double(item.count))
                },
                innerRatio: 0.62,
                insetDegrees: 1.8
            )

            if let dom = dominantCumulative {
                VStack(spacing: 4) {
                    Text(dom.cat.display)
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("\(Int((dom.frac * 100).rounded()))%")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                        .contentTransition(.numericText(value: dom.frac))
                }
            } else {
                Text("—")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Vertical stack of slim bars — one per category in the full sorted
    /// order, with cumulative percentages animating from 0 → final as the
    /// cursor advances. Same data the donut summarizes. Each bar fills
    /// with a horizontal gradient (paler at the start, full color at the
    /// end) so the bars look lit rather than flat-painted.
    private func barLegend(totals: [(FrameCategory, Int)]) -> some View {
        let denom = max(digest.totalFrames, 1)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(totals, id: \.0) { (cat, _) in
                let cumCount = cumulativeCounts[cat] ?? 0
                let frac = Double(cumCount) / Double(denom)
                let base = CategoryPalette.color(cat)

                HStack(spacing: 10) {
                    Circle().fill(base).frame(width: 8, height: 8)
                    Text(cat.display)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .frame(width: 80, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [base.opacity(0.65), base],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .frame(width: max(0, geo.size.width * frac))
                        }
                    }
                    .frame(height: 7)
                    Text("\(Int((frac * 100).rounded()))%")
                        .font(.system(.caption2, design: .rounded).monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(cumCount)))
                }
            }
        }
    }

    // MARK: Notes

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Note")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Spacer()
                if noteDraft != notePersisted {
                    Button("Save") {
                        save()
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                    Button("Revert") {
                        noteDraft = notePersisted
                    }
                }
            }

            TextEditor(text: $noteDraft)
                .font(.body)
                .frame(minHeight: 100, maxHeight: 200)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
                )
        }
    }

    // MARK: Actions

    private func load() {
        if player == nil {
            let url = Journal.videoURL(for: digest)
            if FileManager.default.fileExists(atPath: url.path) {
                player = AVPlayer(url: url)
            }
        }
        if full == nil {
            full = store.loadFullSession(for: digest)
        }

        // Decide cursor starting state: if we have both a sidecar and a
        // working player, leave cursor at 0 so bars start empty and grow
        // as the user hits play. Otherwise jump straight to "everything
        // shown" so the static view still renders meaningful totals.
        if hasInteractivePlayback {
            cursorCount = 0
            startObservingPlayer()
        } else {
            cursorCount = full?.frames.count ?? digest.totalFrames
        }

        noteDraft = note
        notePersisted = note
    }

    /// Wires a periodic time observer onto the AVPlayer so cursorCount
    /// tracks the user's current playback position. 50 ms cadence is fast
    /// enough that the bars feel "alive" without flooding the main thread.
    private func startObservingPlayer() {
        guard let player = player, let frames = full?.frames, !frames.isEmpty else { return }
        if timeObserver != nil { return }

        let fps = max(1, full?.playbackFPS ?? 10)
        let frameCount = frames.count
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite, seconds >= 0 else { return }
            // count = "frames worth of time elapsed so far"
            let count = max(0, min(frameCount, Int((seconds * Double(fps)).rounded(.down))))
            // Updating from MainActor-isolated view state is fine here —
            // the observer queue is .main, so this hop is a no-op.
            Task { @MainActor in
                if count != cursorCount {
                    cursorCount = count
                }
            }
        }
    }

    private func stopObservingPlayer() {
        if let obs = timeObserver, let player = player {
            player.removeTimeObserver(obs)
        }
        timeObserver = nil
    }

    private func save() {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setNote(for: digest, dayKey: dayKey, note: trimmed.isEmpty ? nil : trimmed)
        notePersisted = trimmed
        noteDraft = trimmed
    }
}

// MARK: - Window controller

/// Lazy singleton wrapper so "Open Journal…" reopens the same window rather
/// than spawning a new one each time it's clicked.
@MainActor
final class JournalWindowController {

    static let shared = JournalWindowController()

    private var window: NSWindow?

    private init() {}

    /// Hand in the currently-active recorder so the store can render the
    /// live session. Safe to call multiple times; the store holds it weakly.
    func show(recorder: TimeLapseRecorder?) {
        JournalStore.shared.recorder = recorder
        JournalStore.shared.reload()

        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: JournalRootView(store: JournalStore.shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "WorkTimeLaps Journal"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1320, height: 820))
        window.center()
        window.isReleasedWhenClosed = false
        // Pin Journal to the light appearance — the dashboard is meant to
        // feel airy and bright regardless of the system's dark/light
        // setting. The thin-material cards and donut palette were tuned
        // for this; dark mode made the whole thing feel heavy.
        window.appearance = NSAppearance(named: .aqua)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
