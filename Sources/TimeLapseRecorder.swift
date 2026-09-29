import Cocoa
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit

extension Notification.Name {
    /// Posted (on main) after each successfully appended frame. The Journal
    /// UI uses this to refresh the live "today" cell and live session row.
    static let worktimelapsFrameAppended = Notification.Name("WorkTimeLaps.frameAppended")

    /// Posted (on main) after a recording is stopped and the journal entry
    /// has been written. Paired with `worktimelapsJournalDidUpdate` — this
    /// one is strictly about sessions ending, useful when the UI wants to
    /// react specifically to "a recording just finished" rather than any
    /// note-edit journal write.
    static let worktimelapsSessionCompleted = Notification.Name("WorkTimeLaps.sessionCompleted")
}

/// Read-only view of the in-progress recording, safe to hand to UI code that
/// doesn't want to poke at the recorder internals. Rebuilt on demand; the
/// Journal store calls `liveSnapshot` whenever a frame-appended notification
/// fires.
struct LiveSessionSnapshot: Sendable {
    let id: String
    let video: String
    let startedAt: Date
    let lastUpdated: Date
    let safeFrames: Int
    let redactedFrames: Int
    let engagement: Int?
    let topCategory: FrameCategory?
    var totalFrames: Int { safeFrames + redactedFrames }
}

/// Captures a screenshot of the main display every `captureInterval` seconds
/// using ScreenCaptureKit, asks Claude Haiku what's on screen, and streams
/// each frame (or a redacted placeholder if secrets are visible) straight
/// into an MP4 on disk via AVAssetWriter. A companion sidecar JSON is
/// rewritten after every frame so a crash still leaves a readable session.
///
/// Streaming (rather than buffering CGImages in memory) means a multi-hour
/// session uses roughly constant memory regardless of recording length.
///
/// The whole class is @MainActor, so there is no explicit locking —
/// serialization comes from the main actor itself. Captures hop off main
/// during their `await` (SCK and the analyzer do the heavy work off-main)
/// and only touch writer/session state back on main.
@MainActor
final class TimeLapseRecorder {

    enum RecorderError: LocalizedError {
        case alreadyRecording
        case notRecording
        case screenUnavailable(underlying: String?)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A recording is already in progress."
            case .notRecording:
                return "No recording is in progress."
            case .screenUnavailable(let underlying):
                let base = "Couldn't capture the screen. Grant Screen Recording permission in System Settings → Privacy & Security → Screen Recording, then relaunch WorkTimeLaps."
                if let u = underlying { return "\(base)\n\n(\(u))" }
                return base
            case .writerFailed(let msg):
                return "Couldn't write the video file: \(msg)"
            }
        }
    }

    // MARK: - Public config

    /// Time between screenshots, in real seconds.
    let captureInterval: TimeInterval = 10.0

    /// Playback frame rate. With a 10-second capture interval and 10 fps
    /// playback the time lapse plays back at 100× speed.
    let playbackFPS: Int32 = 10

    /// H.264 target bitrate. Screen content compresses very well, so 3 Mbps
    /// is plenty at 10 fps for a 1440p desktop shot — produces ~20 MB per
    /// recorded hour. Raising it mostly just wastes disk.
    let videoBitrate: Int = 3_000_000

    /// Gap multiplier that counts as a sleep/lid-close. If >3× captureInterval
    /// passed since the previous frame we treat this one as "waking up":
    /// engagement forced to 0 and the gap is flagged in the sidecar.
    private let sleepGapMultiplier: Double = 3.0

    /// EMA smoothing factor for the engagement "rev meter". α=0.1 gives a
    /// ~20-sample effective window: responsive enough to feel live, slow
    /// enough not to bounce on every Slack glance.
    private let engagementAlpha: Double = 0.1

    /// Optional Claude Haiku analyzer. When set, every captured frame is
    /// sent to the API, producing a safety verdict + librarian category +
    /// short summary + raw engagement score in one call. Configured via
    /// `configureAnalyzer(_:)` before (or during) a recording.
    private var analyzer: FrameAnalyzer?

    // MARK: - Public state

    private(set) var isRecording = false

    /// Counts of (safe, redacted) frames in the active recording. Reset at
    /// each start(). Read by the UI to show "Recording… (5 safe, 1 redacted)".
    private(set) var safeFrameCount: Int = 0
    private(set) var redactedFrameCount: Int = 0

    /// Latest smoothed engagement value, 0-100. Drives the menu-bar
    /// "rev meter" number. Nil when we have no samples yet.
    private(set) var currentEngagement: Int?

    /// Latest category the analyzer returned. Nil when we have no samples
    /// yet. Used by the menu label and (later) Slack status push.
    private(set) var currentCategory: FrameCategory?

    /// Latest one-line summary from the analyzer. Useful for tooltips and
    /// status pushes.
    private(set) var currentSummary: String = ""

    /// Called on the main actor after each frame is appended, so the UI can
    /// refresh counters + rev meter. Set by MenuBarController.
    var onFrameAppended: (@MainActor () -> Void)?

    /// Lightweight snapshot of the currently-recording session, or nil if
    /// we're idle. The Journal UI pulls this to render the in-progress
    /// session row without reaching into private state.
    var liveSnapshot: LiveSessionSnapshot? {
        guard isRecording, let s = session else { return nil }
        return LiveSessionSnapshot(
            id: s.id,
            video: s.video,
            startedAt: s.startedAt,
            lastUpdated: s.lastUpdated,
            safeFrames: safeFrameCount,
            redactedFrames: redactedFrameCount,
            engagement: currentEngagement,
            topCategory: currentCategory
        )
    }

    // MARK: - Paths

    /// nonisolated so Journal / RetentionSweeper (plain enums, no actor
    /// isolation) can ask for the folder. It only touches FileManager —
    /// no MainActor state — so there's nothing to protect.
    nonisolated static var recordingsFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let folder = movies.appendingPathComponent("WorkTimeLaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Internals

    private var captureTask: Task<Void, Never>?

    // ScreenCaptureKit — resolved once on start, reused per frame.
    private var captureFilter: SCContentFilter?
    private var captureConfig: SCStreamConfiguration?

    // AVAssetWriter pipeline.
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var sidecarURL: URL?
    private var thumbURL: URL?
    private var frameIndex: Int64 = 0
    private var writerInitialized = false

    /// Full session state — mutated frame-by-frame, persisted after each
    /// append and again (with summary) on stop.
    private var session: RecordingSession?

    /// Wall-clock time of the previous frame, for sleep-gap detection.
    private var lastFrameAt: Date?

    /// Running engagement EMA in Double-land to avoid rounding drift.
    private var engagementEMA: Double?

    /// Activity / summary / category from the last analyzed frame. Fed
    /// back into the next frame's analyzer prompt so the model can reuse
    /// the same activity name verbatim and answer "is it the same?"
    /// honestly. Reset to nil at the start of each recording.
    private var lastActivity: String?
    private var lastSummaryForPrompt: String?
    private var lastCategoryForPrompt: FrameCategory?

    // MARK: - Analyzer wiring

    /// Install (or remove) the frame analyzer. Passing nil disables
    /// analysis — all frames are written unchanged and the sidecar marks
    /// them as `.other` with zero engagement. Can be called while
    /// recording; takes effect on the next frame.
    func configureAnalyzer(_ analyzer: FrameAnalyzer?) {
        self.analyzer = analyzer
    }

    var isAnalyzerEnabled: Bool { analyzer != nil }

    // Backwards-compatible name kept for the UI — "safety check" is how
    // the user sees it in the menu.
    var isSafetyCheckEnabled: Bool { analyzer != nil }

    // MARK: - Start

    func start() async throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        // 1. Resolve available displays via SCK. This throws if Screen
        //    Recording permission has been denied.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw RecorderError.screenUnavailable(underlying: error.localizedDescription)
        }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw RecorderError.screenUnavailable(underlying: "no displays reported")
        }

        // 2. Build capture configuration at the display's native pixel size.
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: playbackFPS)

        // 3. Take a test shot so permission errors surface *here* (not silently
        //    mid-recording). captureImage throws if we lack permission.
        do {
            _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw RecorderError.screenUnavailable(underlying: error.localizedDescription)
        }

        self.captureFilter = filter
        self.captureConfig = config

        // 4. Reset writer + session state and pick output paths.
        frameIndex = 0
        writerInitialized = false
        writer = nil
        writerInput = nil
        adaptor = nil
        safeFrameCount = 0
        redactedFrameCount = 0
        currentEngagement = nil
        currentCategory = nil
        currentSummary = ""
        engagementEMA = nil
        lastFrameAt = nil
        lastActivity = nil
        lastSummaryForPrompt = nil
        lastCategoryForPrompt = nil
        RedactedFrame.invalidate()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = "TimeLapse_\(formatter.string(from: Date()))"
        let folder = Self.recordingsFolder
        outputURL = folder.appendingPathComponent("\(stem).mp4")
        sidecarURL = folder.appendingPathComponent("\(stem).json")
        thumbURL = folder.appendingPathComponent("\(stem).thumb.jpg")

        session = RecordingSession(
            id: stem,
            video: "\(stem).mp4",
            startedAt: Date(),
            endedAt: nil,
            lastUpdated: Date(),
            captureIntervalSec: captureInterval,
            playbackFPS: Int(playbackFPS),
            display: RecordingSession.DisplaySize(width: display.width, height: display.height),
            frames: [],
            summary: nil
        )

        isRecording = true

        // 5. Kick off the capture loop. Cancellation (via captureTask?.cancel())
        //    is how stop() shuts this down.
        captureTask = Task { [weak self] in
            await self?.runCaptureLoop()
        }
    }

    // MARK: - Capture loop

    private func runCaptureLoop() async {
        // Immediate first frame so short recordings still yield content.
        await captureOneFrame()

        while !Task.isCancelled && isRecording {
            do {
                try await Task.sleep(nanoseconds: UInt64(captureInterval * 1_000_000_000))
            } catch {
                // CancellationError — stop was called.
                break
            }
            if Task.isCancelled || !isRecording { break }
            await captureOneFrame()
        }
    }

    private func captureOneFrame() async {
        guard isRecording, let filter = captureFilter, let config = captureConfig else { return }

        // Sample the foreground context *before* the screenshot so the
        // captured pixels and the rule-engine context line up — if the
        // user switches apps in the millisecond between probe and capture
        // we'd rather under-redact than over-redact (the per-frame analyzer
        // still has the privacy-tag fallback).
        let workContext = WorkContextProbe.current()

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            NSLog("WorkTimeLaps: capture failed: \(error.localizedDescription)")
            return
        }

        // After the await we may have been asked to stop; don't append to a
        // writer that's about to be finalized.
        guard isRecording else { return }

        if !writerInitialized {
            do {
                try initializeWriter(width: image.width, height: image.height)
                writerInitialized = true
                // First-frame thumbnail. Best-effort — failure just means no
                // preview in the future calendar UI.
                saveThumbnail(image)
            } catch {
                NSLog("WorkTimeLaps: writer init failed: \(error.localizedDescription)")
                return
            }
        }

        // Sleep / lid-close detection. If this frame lands suspiciously late
        // compared to the previous one, we record the gap and force
        // engagement to 0 — the computer wasn't actually doing anything
        // during that stretch.
        let now = Date()
        var sleepGapSec: Double? = nil
        if let prev = lastFrameAt {
            let elapsed = now.timeIntervalSince(prev)
            if elapsed > captureInterval * sleepGapMultiplier {
                sleepGapSec = elapsed
            }
        }

        // Run the analyzer (if configured). Fail-closed: redact on any
        // error so a flaky network can't silently disable the filter.
        let analysis: FrameAnalysis?
        var redactionReason: String? = nil
        var sleepOverride = false

        if let analyzer = analyzer {
            // Previous-frame context lets the model reuse the same activity
            // verbatim and answer sameAsBefore honestly. Vocabulary is the
            // 2-hour rolling list that pushes labels toward consistency.
            let previous: FrameAnalyzer.PreviousFrameContext? = {
                guard let act = lastActivity,
                      let summary = lastSummaryForPrompt,
                      let cat = lastCategoryForPrompt else { return nil }
                return FrameAnalyzer.PreviousFrameContext(activity: act, summary: summary, category: cat)
            }()
            let vocabulary = ActivityVocabulary.recent()

            // Pass the macOS account holder's full name into the prompt
            // so the model has an explicit identity to anchor the
            // "addressed to me" check on. Without this it tends to
            // assume any praise visible on screen is for the user.
            let outcome = await analyzer.analyze(
                image: image,
                previous: previous,
                vocabulary: vocabulary,
                userName: NSFullUserName()
            )
            guard isRecording else { return }
            switch outcome {
            case .analyzed(let a):
                analysis = a
            case .failed(let reason):
                NSLog("WorkTimeLaps: analyzer failed (\(reason)) — redacting frame")
                redactionReason = "analyzer failed: \(reason)"
                analysis = nil
            }
        } else {
            analysis = nil
        }

        // Decide what to write to the MP4 and what to record in the sidecar.
        let frameToWrite: CGImage
        let isRedacted: Bool
        let rawEngagement: Int
        let category: FrameCategory
        let summaryText: String
        let activityText: String

        // Context-blocklist match: app bundle id or window title hits a
        // user-configured rule. This is independent of analyzer output —
        // it's a hard "this kind of context never gets recorded" signal.
        // Evaluated here so we can know it before writing the sidecar even
        // if the analyzer call fails-closed below.
        let blockedRule = PrivacyRulesStore.match(bundleID: workContext.bundleID,
                                                  windowTitle: workContext.windowTitle)

        // Built-in self-block: if our own app is the frontmost window
        // (the user reviewing Highlights / Journal / Settings), redact
        // and skip recognition. Otherwise we'd loop on ourselves —
        // logging quotes from the brag sheet as new "recognitions"
        // every time the user opens it. Hardcoded rather than
        // user-toggleable because there is no good reason to record
        // ourselves recording.
        let isSelfReading = workContext.bundleID == Bundle.main.bundleIdentifier

        if let a = analysis {
            // Four redaction triggers, in priority order:
            //  1. Credential leak (`!a.safe`) — fail-hard, never overridable.
            //  2. Self-reading — built-in, can't be turned off.
            //  3. Context blocklist — user-declared "never record this app
            //     or window," sanitized summary so even the metadata stays
            //     generic.
            //  4. Privacy tag — Haiku-judged content category.
            if !a.safe {
                redactionReason = "secret visible"
                frameToWrite = RedactedFrame.image(width: image.width, height: image.height) ?? image
                isRedacted = true
            } else if isSelfReading {
                redactionReason = "blocked:self"
                frameToWrite = RedactedFrame.image(width: image.width, height: image.height) ?? image
                isRedacted = true
            } else if let rule = blockedRule {
                redactionReason = "blocked:\(rule.kind.rawValue):\(rule.pattern)"
                frameToWrite = RedactedFrame.image(width: image.width, height: image.height) ?? image
                isRedacted = true
            } else if PrivacyFilterStore.shouldRedact(a.privacy) {
                redactionReason = "privacy:\(a.privacy.rawValue)"
                frameToWrite = RedactedFrame.image(width: image.width, height: image.height) ?? image
                isRedacted = true
            } else {
                frameToWrite = image
                isRedacted = false
            }
            category = a.category
            // Summary is already generic for non-none privacy per the
            // analyzer's prompt. For context-blocklist or self-reading
            // hits the analyzer *doesn't* know to be generic, so we
            // sanitize client-side — the category display is enough to
            // keep "X% of the day in category Y" honest without leaking
            // specifics from a DM thread.
            let modelSummary: String
            if (blockedRule != nil || isSelfReading) && a.safe && !PrivacyFilterStore.shouldRedact(a.privacy) {
                modelSummary = isSelfReading ? "Reviewing WorkTimeLaps" : a.category.display
            } else {
                modelSummary = a.summary
            }

            // Activity resolution. Cases in priority order:
            //   1. Self-reading — fixed activity name, no vocabulary churn.
            //   2. Blocked context — image is redacted, so the activity
            //      label should be the category display rather than a
            //      specific tool name. Same reason we sanitize the summary.
            //   3. sameAsBefore — model says nothing meaningful changed;
            //      reuse the previous frame's activity + summary verbatim
            //      so clusters stay stable across rephrase noise.
            //   4. Otherwise — validate the model's activity (deny-list +
            //      shape). On failure fall back to the category display.
            //      On success record into the rolling vocabulary.
            let resolvedActivity: String
            let resolvedSummary: String
            if isSelfReading {
                resolvedActivity = "WorkTimeLaps"
                resolvedSummary = modelSummary
            } else if blockedRule != nil {
                resolvedActivity = a.category.display
                resolvedSummary = modelSummary
            } else if a.sameAsBefore, let prev = lastActivity, !prev.isEmpty {
                resolvedActivity = prev
                resolvedSummary = lastSummaryForPrompt ?? modelSummary
            } else if let validated = ActivityVocabulary.validate(a.activity) {
                resolvedActivity = validated
                resolvedSummary = modelSummary
                ActivityVocabulary.record(name: validated, summary: modelSummary)
            } else {
                resolvedActivity = a.category.display
                resolvedSummary = modelSummary
            }
            summaryText = resolvedSummary
            activityText = resolvedActivity

            // Category-weighted ceiling keeps the meter honest: "deep work"
            // on a media player shouldn't read 90.
            let capped = Double(a.engagement) * a.category.activityWeight
            rawEngagement = Int(capped.rounded())
        } else if analyzer != nil {
            // Fail-closed: redact + zero out the meter, but keep writing so
            // the user still gets a continuous video.
            frameToWrite = RedactedFrame.image(width: image.width, height: image.height) ?? image
            isRedacted = true
            category = .other
            summaryText = ""
            activityText = ""
            rawEngagement = 0
        } else {
            // No analyzer configured — pass the frame through, meter stays
            // idle.
            frameToWrite = image
            isRedacted = false
            category = .other
            summaryText = ""
            activityText = ""
            rawEngagement = 0
        }

        // Force engagement to 0 across a detected sleep gap even if the
        // model scored the wake-up frame high.
        let engagementForThisFrame: Int
        if sleepGapSec != nil {
            engagementForThisFrame = 0
            sleepOverride = true
        } else {
            engagementForThisFrame = rawEngagement
        }

        // EMA smoothing. A sleep gap also resets the EMA so we don't carry
        // yesterday's tachometer reading into today.
        let smoothed: Int
        if sleepOverride || engagementEMA == nil {
            engagementEMA = Double(engagementForThisFrame)
            smoothed = engagementForThisFrame
        } else {
            let prev = engagementEMA ?? 0
            let next = prev + engagementAlpha * (Double(engagementForThisFrame) - prev)
            engagementEMA = next
            smoothed = Int(next.rounded())
        }

        guard let appendedIndex = appendFrame(frameToWrite) else {
            // Writer couldn't accept this frame — don't update counters, don't
            // write a sidecar entry, don't advance lastFrameAt (so we'll
            // re-detect the sleep gap if one was in progress).
            return
        }

        if isRedacted {
            redactedFrameCount += 1
        } else {
            safeFrameCount += 1
        }
        currentEngagement = smoothed
        currentCategory = category
        currentSummary = summaryText
        lastFrameAt = now
        // Remember this frame's labels so the next frame's analyzer prompt
        // can ask "is it the same?" against meaningful values.
        lastActivity = activityText.isEmpty ? nil : activityText
        lastSummaryForPrompt = summaryText.isEmpty ? nil : summaryText
        lastCategoryForPrompt = category

        // Update the session sidecar. We rewrite the whole blob each time —
        // cheap at these sizes and means a crash leaves a valid file.
        if var s = session {
            let entry = FrameEntry(
                i: appendedIndex,
                t: now,
                category: category,
                summary: summaryText,
                engagement: engagementForThisFrame,
                engagementSmoothed: smoothed,
                redacted: isRedacted,
                redactionReason: isRedacted ? (redactionReason ?? "unknown") : nil,
                sleepGapSec: sleepGapSec,
                activity: activityText.isEmpty ? nil : activityText
            )
            s.frames.append(entry)
            s.lastUpdated = now
            session = s
            persistSidecar()
        }

        // Recognition logging — only on un-redacted frames where the
        // model fired the strict rubric. Skipping redacted frames means
        // every entry in the brag sheet has a viewable source frame for
        // later verification, and we don't risk preserving a quote we
        // can't substantiate.
        if let a = analysis,
           a.recognitionLevel != .none,
           !isRedacted,
           !a.recognitionQuote.isEmpty {
            let recognition = Recognition(
                id: UUID().uuidString,
                capturedAt: now,
                level: a.recognitionLevel,
                quote: a.recognitionQuote,
                speaker: a.recognitionSpeaker.isEmpty ? nil : a.recognitionSpeaker,
                sourceAppBundleID: workContext.bundleID,
                sourceAppName: workContext.appName,
                activity: activityText.isEmpty ? nil : activityText,
                category: category,
                sessionID: session?.id,
                frameIndex: appendedIndex
            )
            RecognitionStore.append(recognition)
        }

        onFrameAppended?()
        NotificationCenter.default.post(name: .worktimelapsFrameAppended, object: nil)
    }

    // MARK: - Writer setup

    private func initializeWriter(width: Int, height: Int) throws {
        guard let url = outputURL else {
            throw RecorderError.writerFailed("missing output URL")
        }
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw RecorderError.writerFailed(error.localizedDescription)
        }

        // H.264 — broadly compatible. 3 Mbps is plenty for screen content at
        // 10 fps; keyframe every 4 seconds so scrubbing stays responsive.
        let compressionSettings: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitrate,
            AVVideoExpectedSourceFrameRateKey: Int(playbackFPS),
            AVVideoMaxKeyFrameIntervalKey: Int(playbackFPS) * 4
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionSettings
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: attrs)

        guard writer.canAdd(input) else {
            throw RecorderError.writerFailed("can't add input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.writerInput = input
        self.adaptor = adaptor
    }

    /// Returns the index of the appended frame on success, or nil if the
    /// writer wasn't ready / pixel buffer creation failed. Callers use the
    /// nil return to skip counter + sidecar updates for the dropped frame.
    private func appendFrame(_ image: CGImage) -> Int64? {
        guard let adaptor = adaptor, let input = writerInput else { return nil }

        guard input.isReadyForMoreMediaData else {
            NSLog("WorkTimeLaps: writer not ready, dropping frame")
            return nil
        }

        guard let buffer = PixelBufferHelper.make(from: image,
                                                  width: image.width,
                                                  height: image.height,
                                                  pool: adaptor.pixelBufferPool) else { return nil }

        let appendedIndex = frameIndex
        let time = CMTime(value: frameIndex, timescale: playbackFPS)
        adaptor.append(buffer, withPresentationTime: time)
        frameIndex += 1
        return appendedIndex
    }

    // MARK: - Thumbnail

    /// Writes the first captured frame to `<stem>.thumb.jpg` so the future
    /// calendar UI has something to show in a recording block without
    /// having to decode the MP4.
    private func saveThumbnail(_ image: CGImage) {
        guard let url = thumbURL else { return }
        // Scale down the long side to 400 px — plenty for a calendar tile.
        let maxDim = 400
        let longest = max(image.width, image.height)
        let scale = longest > maxDim ? Double(maxDim) / Double(longest) : 1.0
        let targetW = max(1, Int(Double(image.width) * scale))
        let targetH = max(1, Int(Double(image.height) * scale))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let ctx = CGContext(data: nil,
                                  width: targetW,
                                  height: targetH,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo) else { return }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let scaled = ctx.makeImage() else { return }

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.jpeg.identifier as CFString,
                                                         1,
                                                         nil) else { return }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.75
        ]
        CGImageDestinationAddImage(dest, scaled, options as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
    }

    // MARK: - Sidecar persistence

    private func persistSidecar() {
        guard let s = session, let url = sidecarURL else { return }
        do {
            try SessionWriter.write(s, to: url)
        } catch {
            NSLog("WorkTimeLaps: sidecar write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Stop

    func stop() async throws -> URL {
        guard isRecording else { throw RecorderError.notRecording }

        isRecording = false

        // Cancel and wait for the capture loop to exit. `await .value` on a
        // Task<Void, Never> resolves once the task is actually done, including
        // any in-flight SCK / analyzer call that has to complete naturally.
        if let task = captureTask {
            task.cancel()
            await task.value
        }
        captureTask = nil

        guard let writer = writer, let input = writerInput, let url = outputURL else {
            throw RecorderError.writerFailed("no writer was created")
        }
        guard writerInitialized, frameIndex > 0 else {
            throw RecorderError.writerFailed("no frames captured — did Screen Recording permission get revoked mid-recording?")
        }

        input.markAsFinished()
        await writer.finishWriting()

        // Finalize session sidecar: compute summary, stamp endedAt, persist,
        // then append to the day-journal.
        if var s = session {
            let endedAt = Date()
            s.endedAt = endedAt
            s.lastUpdated = endedAt
            s.summary = Self.makeSummary(frames: s.frames)
            session = s
            persistSidecar()
            Journal.append(session: s)
            NotificationCenter.default.post(name: .worktimelapsSessionCompleted, object: nil)
        }

        switch writer.status {
        case .completed:
            return url
        default:
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown writer failure (status \(writer.status.rawValue))")
        }
    }

    // MARK: - Summary

    private static func makeSummary(frames: [FrameEntry]) -> SessionSummary {
        let total = frames.count
        let redacted = frames.filter { $0.redacted }.count
        let safe = total - redacted

        var counts: [String: Int] = [:]
        var engagementSum = 0
        for f in frames {
            counts[f.category.rawValue, default: 0] += 1
            engagementSum += f.engagementSmoothed
        }
        let avg = total == 0 ? 0 : Int((Double(engagementSum) / Double(total)).rounded())
        let top = counts.max(by: { $0.value < $1.value })?.key ?? FrameCategory.other.rawValue
        let topCategory = FrameCategory(rawValue: top) ?? .other

        return SessionSummary(
            totalFrames: total,
            safeFrames: safe,
            redactedFrames: redacted,
            averageEngagement: avg,
            topCategory: topCategory,
            categoryCounts: counts
        )
    }
}
