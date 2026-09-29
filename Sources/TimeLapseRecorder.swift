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

    /// Posted (on main) after a session ends and its journal entry has been
    /// written — on Stop, at the work-day rollover, and on quit.
    static let worktimelapsSessionCompleted = Notification.Name("WorkTimeLaps.sessionCompleted")

    /// Posted (on main) when recording starts, stops, pauses or resumes.
    static let worktimelapsRecorderStateChanged = Notification.Name("WorkTimeLaps.recorderStateChanged")
}

/// Read-only view of the in-progress session, safe to hand to UI code.
struct LiveSessionSnapshot: Sendable {
    let id: String
    let video: String
    let startedAt: Date
    let lastUpdated: Date
    let safeFrames: Int
    let redactedFrames: Int
    let engagement: Int?
    let topCategory: FrameCategory?
    let activeSeconds: TimeInterval
    var totalFrames: Int { safeFrames + redactedFrames }
}

/// Captures a screenshot of the main display every `captureInterval`
/// seconds using ScreenCaptureKit, asks Claude Haiku what's on screen, and
/// streams each frame (or a REDACTED placeholder) into an MP4 via
/// AVAssetWriter. A sidecar JSON next to the video holds the frame log.
///
/// Recording is meant to stay on all day:
/// - Capture pauses while the screen is locked, the display or Mac is
///   asleep, or the user paused it — no screenshots, no API calls.
/// - A session is opened lazily on its first frame and closed at the
///   work-day cutoff (02:00 by default), so each session belongs to exactly
///   one work day and the next one starts on its own.
/// - Frames from blocked apps/windows and from WorkTimeLaps itself are never
///   sent to the API.
///
/// The class is @MainActor, so there is no explicit locking. Captures hop
/// off main during their `await`s and only touch writer/session state back
/// on main.
@MainActor
final class TimeLapseRecorder {

    enum RecorderError: LocalizedError {
        case alreadyRecording
        case screenUnavailable(underlying: String?)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A recording is already in progress."
            case .screenUnavailable(let underlying):
                let base = "Couldn't capture the screen. Grant Screen Recording permission in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch WorkTimeLaps."
                if let u = underlying { return "\(base)\n\n(\(u))" }
                return base
            case .writerFailed(let msg):
                return "Couldn't write the video file: \(msg)"
            }
        }

        /// True when the fix is granting Screen Recording permission.
        var isPermissionProblem: Bool {
            if case .screenUnavailable = self { return true }
            return false
        }
    }

    /// Why nothing is being captured while recording is on.
    enum PauseReason: Equatable {
        case user(until: Date)
        case away(String)

        var label: String {
            switch self {
            case .user(let until):
                let f = DateFormatter()
                f.timeStyle = .short
                return "Paused until \(f.string(from: until))"
            case .away(let why):
                return "Paused — \(why)"
            }
        }
    }

    // MARK: - Config

    /// Time between screenshots, in real seconds.
    let captureInterval: TimeInterval = 10.0

    /// Playback frame rate. With a 10-second capture interval and 10 fps
    /// playback the time lapse plays back at 100× speed.
    let playbackFPS: Int32 = 10

    /// H.264 target bitrate. Screen content compresses very well, so 3 Mbps
    /// is plenty at 10 fps.
    let videoBitrate: Int = 3_000_000

    /// EMA smoothing factor for the engagement "rev meter". α=0.1 gives a
    /// ~20-sample effective window.
    private let engagementAlpha: Double = 0.1

    /// The sidecar is rewritten every this many frames (about once a
    /// minute) and whenever a session pauses or ends. Rewriting on every
    /// frame meant several GB of disk writes over a full day.
    private let sidecarFlushInterval = 6

    /// Movie fragments keep a video that was cut short by a crash or power
    /// loss playable up to the last fragment. Measured in video time: 3 s
    /// of video is 30 frames, about five minutes of real time.
    private let movieFragmentInterval = CMTime(value: 3, timescale: 1)

    /// Optional Claude Haiku analyzer. When set, frames that may leave the
    /// Mac are sent to the API for a safety verdict, category, summary and
    /// engagement score in one call.
    private var analyzer: FrameAnalyzer?

    // MARK: - Public state

    private(set) var isRecording = false

    /// Frame counts for the current session.
    private(set) var safeFrameCount: Int = 0
    private(set) var redactedFrameCount: Int = 0

    /// Latest smoothed engagement value, 0-100. Nil before the first frame.
    private(set) var currentEngagement: Int?
    private(set) var currentCategory: FrameCategory?
    private(set) var currentSummary: String = ""

    /// Set while the user has paused recording from the menu.
    private(set) var userPauseUntil: Date?

    /// Called on the main actor after each frame is appended.
    var onFrameAppended: (@MainActor () -> Void)?

    /// Why capture is paused right now, or nil if it's running (or off).
    var pauseReason: PauseReason? {
        guard isRecording else { return nil }
        if let until = userPauseUntil, until > Date() { return .user(until: until) }
        if let why = SystemStateMonitor.shared.awayReason { return .away(why) }
        return nil
    }

    var isAnalyzerEnabled: Bool { analyzer != nil }
    var currentSessionStartedAt: Date? { session?.startedAt }
    var currentSessionID: String? { session?.id }
    var currentVideoFilename: String? { session?.video }

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
            topCategory: currentCategory,
            activeSeconds: ActivityTimeline.activeSeconds(s.frames, captureInterval: captureInterval)
        )
    }

    // MARK: - Paths

    /// Root data folder: `~/Movies/WorkTimeLaps`, or `$WORKTIMELAPS_DATA_DIR`
    /// when set (handy for development and tests). nonisolated because it
    /// only touches FileManager.
    nonisolated static var recordingsFolder: URL {
        let folder: URL
        if let override = ProcessInfo.processInfo.environment["WORKTIMELAPS_DATA_DIR"], !override.isEmpty {
            folder = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
            folder = movies.appendingPathComponent("WorkTimeLaps", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - Internals

    private var captureTask: Task<Void, Never>?

    // ScreenCaptureKit — resolved once on start, reused per frame.
    private var captureFilter: SCContentFilter?
    private var captureConfig: SCStreamConfiguration?

    // AVAssetWriter pipeline for the current session.
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var sidecarURL: URL?
    private var thumbURL: URL?
    private var frameIndex: Int64 = 0
    private var writerInitialized = false
    private var thumbnailSaved = false
    private var framesSinceFlush = 0

    /// The session being recorded. Nil until the first frame after start,
    /// a pause-free rollover, or a stop.
    private var session: RecordingSession?

    /// Wall-clock time of the previous frame, for absence detection.
    private var lastFrameAt: Date?

    /// Running engagement EMA in Double-land to avoid rounding drift.
    private var engagementEMA: Double?

    /// Labels from the last analyzed frame, fed back into the next prompt
    /// so the model can reuse the activity name and answer "same as before?".
    private var lastActivity: String?
    private var lastSummaryForPrompt: String?
    private var lastCategoryForPrompt: FrameCategory?

    // MARK: - Analyzer wiring

    /// Install (or remove) the frame analyzer. Takes effect on the next frame.
    func configureAnalyzer(_ analyzer: FrameAnalyzer?) {
        self.analyzer = analyzer
    }

    // MARK: - Start / stop / pause

    func start() async throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        try await prepareCapture()
        resetSessionState()
        userPauseUntil = nil
        isRecording = true
        SystemStateMonitor.shared.start()
        captureTask = Task { [weak self] in
            await self?.runCaptureLoop()
        }
        postStateChange()
    }

    /// Stops recording and finalizes the current session. Returns the video
    /// URL, or nil if nothing was recorded since the last rollover.
    @discardableResult
    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        userPauseUntil = nil

        // Cancel and wait for the loop, including any in-flight capture or
        // analyzer call, before touching the writer.
        if let task = captureTask {
            task.cancel()
            await task.value
        }
        captureTask = nil

        let url = await finishSession()
        postStateChange()
        return url
    }

    /// Pause capturing until `date`; nil resumes. Recording stays on and the
    /// session stays open, so the day's video simply skips the paused time.
    func pause(until date: Date?) {
        guard isRecording else { return }
        userPauseUntil = date
        if date != nil { flushSidecar() }
        postStateChange()
    }

    // MARK: - Setup

    private func prepareCapture() async throws {
        // Resolve displays via SCK. Throws if Screen Recording permission
        // has been denied.
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

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: playbackFPS)

        // Test shot so permission errors surface here, not silently later.
        do {
            _ = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw RecorderError.screenUnavailable(underlying: error.localizedDescription)
        }

        captureFilter = filter
        captureConfig = config
    }

    // MARK: - Capture loop

    private func runCaptureLoop() async {
        while !Task.isCancelled && isRecording {
            let tickStart = Date()

            await rolloverIfWorkDayEnded(now: tickStart)

            if let until = userPauseUntil, until <= tickStart {
                userPauseUntil = nil
                postStateChange()
            }

            if pauseReason == nil {
                await captureOneFrame()
            } else {
                flushSidecar()
            }

            // Fixed rhythm: the next frame is due one interval after this one
            // started, however long the analyzer call took.
            let elapsed = Date().timeIntervalSince(tickStart)
            let delay = max(0.5, captureInterval - elapsed)
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                break  // CancellationError — stop() was called.
            }
        }
    }

    /// Closes the session when the work day it started in has ended. The
    /// next frame opens a fresh session for the new day.
    private func rolloverIfWorkDayEnded(now: Date) async {
        guard let s = session, WorkDay.key(for: s.startedAt) != WorkDay.key(for: now) else { return }
        await finishSession()
        resetSessionState()
        postStateChange()
    }

    private func captureOneFrame() async {
        guard isRecording, let filter = captureFilter, let config = captureConfig else { return }

        // Sample the foreground context *before* the screenshot so the rule
        // check lines up with the captured pixels.
        let workContext = WorkContextProbe.current()

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            NSLog("WorkTimeLaps: capture failed: \(error.localizedDescription)")
            return
        }

        // We may have been stopped or paused during the await.
        guard isRecording, pauseReason == nil else { return }

        let now = Date()
        if session == nil {
            openSession(at: now, width: image.width, height: image.height)
        }
        if !writerInitialized {
            do {
                try initializeWriter(width: image.width, height: image.height)
                writerInitialized = true
            } catch {
                NSLog("WorkTimeLaps: writer init failed: \(error.localizedDescription)")
                return
            }
        }

        // A long gap since the previous frame means the user was away (Mac
        // asleep, screen locked, paused). Engagement restarts from 0.
        var sleepGapSec: Double? = nil
        if let prev = lastFrameAt {
            let elapsed = now.timeIntervalSince(prev)
            if elapsed > ActivityTimeline.gapThreshold(for: captureInterval) {
                sleepGapSec = elapsed
            }
        }

        // Decide whether this frame may leave the Mac at all. Our own windows
        // (Journal, Highlights, Diary) and blocked apps/windows are never
        // sent to the analyzer — only logged with a generic label.
        let isSelfReading = workContext.bundleID == Bundle.main.bundleIdentifier
        let blockedRule = isSelfReading
            ? nil
            : PrivacyRulesStore.match(bundleID: workContext.bundleID, windowTitle: workContext.windowTitle)

        var analysis: FrameAnalysis?
        var analyzerFailure: String?
        if let analyzer = analyzer, !isSelfReading, blockedRule == nil {
            let previous: FrameAnalyzer.PreviousFrameContext? = {
                guard let act = lastActivity,
                      let summary = lastSummaryForPrompt,
                      let cat = lastCategoryForPrompt else { return nil }
                return FrameAnalyzer.PreviousFrameContext(activity: act, summary: summary, category: cat)
            }()
            // The account holder's full name anchors the "addressed to me"
            // check for recognition.
            let outcome = await analyzer.analyze(
                image: image,
                previous: previous,
                vocabulary: ActivityVocabulary.recent(),
                userName: NSFullUserName()
            )
            guard isRecording else { return }
            switch outcome {
            case .analyzed(let a):
                analysis = a
            case .failed(let reason):
                NSLog("WorkTimeLaps: analyzer failed (\(reason)) — redacting frame")
                analyzerFailure = reason
            }
        }

        // What to write to the MP4 and the sidecar.
        var redactionReason: String?
        let category: FrameCategory
        let summaryText: String
        let activityText: String
        let rawEngagement: Int
        // Frames we don't analyze keep the meter where it was.
        let carriedEngagement = Int((engagementEMA ?? 0).rounded())

        if isSelfReading {
            redactionReason = "blocked:self"
            category = .other
            summaryText = "Reviewing WorkTimeLaps"
            activityText = "WorkTimeLaps"
            rawEngagement = carriedEngagement
        } else if let rule = blockedRule {
            // Category guessed from the rule; summary kept generic so a DM
            // thread can't leak through the log.
            redactionReason = "blocked:\(rule.kind.rawValue):\(rule.pattern)"
            category = PrivacyRulesStore.category(for: rule)
            summaryText = category.display
            activityText = category.display
            rawEngagement = carriedEngagement
        } else if let a = analysis {
            // Redaction triggers, highest priority first: a visible secret
            // (never overridable), then an enabled privacy filter.
            if !a.safe {
                redactionReason = "secret visible"
            } else if PrivacyFilterStore.shouldRedact(a.privacy) {
                redactionReason = "privacy:\(a.privacy.rawValue)"
            }
            category = a.category

            // Activity resolution: reuse the previous label when the model
            // says nothing changed; otherwise validate the new one and fall
            // back to the category name if it's too generic.
            if a.sameAsBefore, let prev = lastActivity, !prev.isEmpty {
                activityText = prev
                summaryText = lastSummaryForPrompt ?? a.summary
            } else if let validated = ActivityVocabulary.validate(a.activity) {
                activityText = validated
                summaryText = a.summary
                ActivityVocabulary.record(name: validated, summary: a.summary)
            } else {
                activityText = a.category.display
                summaryText = a.summary
            }

            // Category-weighted ceiling keeps the meter honest: "deep work"
            // on a media player shouldn't read 90.
            rawEngagement = Int((Double(a.engagement) * a.category.activityWeight).rounded())
        } else if analyzer != nil {
            // Fail-closed: a flaky network must never disable redaction.
            redactionReason = "analyzer failed: \(analyzerFailure ?? "unknown")"
            category = .other
            summaryText = ""
            activityText = ""
            rawEngagement = 0
        } else {
            // No API key: frames pass through, the meter stays idle.
            category = .other
            summaryText = ""
            activityText = ""
            rawEngagement = 0
        }

        let isRedacted = redactionReason != nil
        let frameToWrite: CGImage
        if isRedacted {
            // Never fall back to the real image for a redacted frame.
            guard let placeholder = RedactedFrame.image(width: image.width, height: image.height) else {
                NSLog("WorkTimeLaps: couldn't render redaction placeholder — dropping frame")
                return
            }
            frameToWrite = placeholder
        } else {
            frameToWrite = image
        }

        let engagementForThisFrame = sleepGapSec != nil ? 0 : rawEngagement
        let smoothed: Int
        if sleepGapSec != nil || engagementEMA == nil {
            engagementEMA = Double(engagementForThisFrame)
            smoothed = engagementForThisFrame
        } else {
            let prev = engagementEMA ?? 0
            let next = prev + engagementAlpha * (Double(engagementForThisFrame) - prev)
            engagementEMA = next
            smoothed = Int(next.rounded())
        }

        guard let appendedIndex = appendFrame(frameToWrite) else {
            // Writer couldn't take the frame — skip the log entry too.
            return
        }

        // Thumbnail from the first frame that isn't redacted, so the preview
        // never shows something the video hides.
        if !thumbnailSaved && !isRedacted {
            saveThumbnail(frameToWrite)
            thumbnailSaved = true
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
        lastActivity = activityText.isEmpty ? nil : activityText
        lastSummaryForPrompt = summaryText.isEmpty ? nil : summaryText
        lastCategoryForPrompt = category

        // Mutate in place — copying the session out and back would copy the
        // whole frame array on every frame.
        session?.frames.append(FrameEntry(
            i: appendedIndex,
            t: now,
            category: category,
            summary: summaryText,
            engagement: engagementForThisFrame,
            engagementSmoothed: smoothed,
            redacted: isRedacted,
            redactionReason: redactionReason,
            sleepGapSec: sleepGapSec,
            activity: activityText.isEmpty ? nil : activityText
        ))
        session?.lastUpdated = now
        framesSinceFlush += 1
        if session?.frames.count == 1 || framesSinceFlush >= sidecarFlushInterval {
            flushSidecar()
        }

        // Recognition — only from analyzed, unredacted frames, so every
        // entry on the brag sheet has a viewable source frame.
        if let a = analysis,
           a.recognitionLevel != .none,
           !isRedacted,
           !a.recognitionQuote.isEmpty {
            RecognitionStore.append(Recognition(
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
            ))
        }

        onFrameAppended?()
        NotificationCenter.default.post(name: .worktimelapsFrameAppended, object: nil)
    }

    // MARK: - Sessions

    private func openSession(at now: Date, width: Int, height: Int) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = "TimeLapse_\(formatter.string(from: now))"
        let folder = Self.recordingsFolder
        outputURL = folder.appendingPathComponent("\(stem).mp4")
        sidecarURL = folder.appendingPathComponent("\(stem).json")
        thumbURL = folder.appendingPathComponent("\(stem).thumb.jpg")

        session = RecordingSession(
            id: stem,
            video: "\(stem).mp4",
            startedAt: now,
            endedAt: nil,
            lastUpdated: now,
            captureIntervalSec: captureInterval,
            playbackFPS: Int(playbackFPS),
            display: RecordingSession.DisplaySize(width: width, height: height),
            frames: [],
            summary: nil
        )
        frameIndex = 0
        writerInitialized = false
        thumbnailSaved = false
        framesSinceFlush = 0
        safeFrameCount = 0
        redactedFrameCount = 0
    }

    /// Finalizes the video, writes the session summary and journal entry.
    /// Returns the video URL when a playable file was written.
    @discardableResult
    private func finishSession() async -> URL? {
        guard var s = session else {
            resetWriter()
            return nil
        }

        var videoURL: URL?
        if writerInitialized, frameIndex > 0, let writer = writer, let input = writerInput {
            input.markAsFinished()
            await writer.finishWriting()
            if writer.status == .completed {
                videoURL = outputURL
            } else {
                NSLog("WorkTimeLaps: video finalize failed: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
            }
        } else {
            writer?.cancelWriting()
            if let url = outputURL { try? FileManager.default.removeItem(at: url) }
        }

        if let last = s.frames.last {
            let endedAt = min(Date(), last.t.addingTimeInterval(captureInterval))
            s.endedAt = endedAt
            s.lastUpdated = endedAt
            s.summary = SessionSummary.make(frames: s.frames, captureInterval: captureInterval)
            session = s
            flushSidecar()
            Journal.append(session: s)
            NotificationCenter.default.post(name: .worktimelapsSessionCompleted, object: nil)
        } else if let url = sidecarURL {
            // Nothing was recorded; don't leave an empty session behind.
            try? FileManager.default.removeItem(at: url)
        }

        session = nil
        resetWriter()
        return videoURL
    }

    private func resetSessionState() {
        session = nil
        resetWriter()
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
    }

    private func resetWriter() {
        writer = nil
        writerInput = nil
        adaptor = nil
        outputURL = nil
        sidecarURL = nil
        thumbURL = nil
        frameIndex = 0
        writerInitialized = false
        thumbnailSaved = false
        framesSinceFlush = 0
    }

    private func postStateChange() {
        NotificationCenter.default.post(name: .worktimelapsRecorderStateChanged, object: nil)
    }

    // MARK: - Writer

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
        writer.movieFragmentInterval = movieFragmentInterval

        // H.264 — broadly compatible. Keyframe every 4 seconds of video so
        // scrubbing stays responsive.
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

    /// Returns the index of the appended frame, or nil if the writer wasn't
    /// ready or the pixel buffer couldn't be created.
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
        guard adaptor.append(buffer, withPresentationTime: time) else {
            NSLog("WorkTimeLaps: append failed: \(writer?.error?.localizedDescription ?? "unknown")")
            return nil
        }
        frameIndex += 1
        return appendedIndex
    }

    // MARK: - Thumbnail

    /// Writes `<stem>.thumb.jpg` (400 px on the long side) for the Journal.
    private func saveThumbnail(_ image: CGImage) {
        guard let url = thumbURL else { return }
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

    // MARK: - Sidecar

    private func flushSidecar() {
        guard let s = session, let url = sidecarURL, !s.frames.isEmpty else { return }
        do {
            try SessionWriter.write(s, to: url)
            framesSinceFlush = 0
        } catch {
            NSLog("WorkTimeLaps: sidecar write failed: \(error.localizedDescription)")
        }
    }
}
