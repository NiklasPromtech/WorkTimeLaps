# WorkTimeLaps

A macOS menu-bar app that quietly captures evidence of your value at work, locally, on your machine, on your terms. Install it a month before your review and the **Highlights** window will be full of receipts — quotable compliments from clients, peers, managers — alongside quantified signals that prove what you've shipped. Each frame is run past Claude Haiku locally to detect recognition (with a strict rubric so routine "thanks!" doesn't pollute the brag sheet), redact anything sensitive, and tag what you were doing.

> Heads up: recording your work screen may be regulated by your employer. Everything stays on your device — nothing is sent anywhere except your own Anthropic API for analysis — but check your company's policy before you install.

## What it does

- Lives in the top-right menu bar as a ○ icon (fills in to ● while recording).
- Clicking the icon shows a small menu: **Start / Stop Time Lapse · Set Anthropic API Key… · Auto-start on launch · Open Highlights… · Open Journal… · Settings… · Quit**. The brag-sheet UI lives in the Highlights window; history / playback / activity stream live in the Journal window; privacy filters / storage cap / recordings folder live in Settings.
- One screenshot every 10 s while recording.
- Playback plays back at 10 fps, so each recorded hour becomes ≈ 36 seconds of video (100× speed).
- Saves MP4s to `~/Movies/WorkTimeLaps/TimeLapse_YYYY-MM-DD_HH-MM-SS.mp4`, plus a matching `.json` sidecar and a `.thumb.jpg` preview.
- **Optional AI multi-check.** If you paste an Anthropic API key, every captured frame is sent to Claude Haiku in a single call that returns seven things at once:
  - `safe` — frames that look like they contain visible secrets (API keys, passwords, tokens, private keys, credentials in config files, credit-card numbers, etc.) are replaced with a black **REDACTED** placeholder in the final MP4.
  - `category` — coding / writing / email / chat / meeting / browsing / design / terminal / reading / media / other.
  - `activity` — a granular, free-text label for the *specific tool or sub-task* on screen ("Stripe pricing config", "Lovable canvas", "Domain research"). Anchored to a 2-hour rolling vocabulary so the same activity gets the same label frame after frame.
  - `summary` — one short human-readable line of what you're doing on that frame. Automatically kept generic whenever the privacy tag is anything other than `none`, so the log says "Reviewing bank statement" rather than dollar amounts or counterparty names.
  - `engagement` — a raw 0-100 score of how active the work looks in that frame. Exponentially smoothed and shown as a colored number next to the menu-bar icon.
  - `privacy` — one of `none` / `financial` / `personal_messages` / `medical` / `hr_legal`. When you've enabled the matching filter in Settings, the image is redacted but the (generic) summary and category still get logged.
  - `sameAsBefore` — a self-reported "this frame is showing the same activity as the last one." When true, the recorder copies the previous frame's `activity` and `summary` verbatim so the cluster-stream stays stable across rephrase noise.
- **Rev meter in the menu bar.** Next to the ● while recording you'll see a number `0-100` in grey / blue / orange / red. It's a tachometer for effort expended, not a productivity score — it measures how intensely the screen is changing and working, nothing about whether the work is actually good or valuable.
- **Sidecar JSON, live.** Alongside each `.mp4` we rewrite a `.json` file after every frame containing start/end timestamps, the full frame log (category, summary, engagement, redaction flags, detected sleep gaps), and a rolled-up summary on stop. Crash-safe: a power loss mid-session leaves a valid sidecar up to the last written frame.
- **Daily journal.** `~/Movies/WorkTimeLaps/_journal/YYYY-MM-DD.json` gets one small digest per finished session — total frames, average engagement, top category, category counts. This directory is never pruned, so the long-term "you've been working your butt off for X weeks" view stays intact even when the raw MP4s roll off the storage quota.
- **Auto-start.** Flip on *Auto-start on launch* once and the app starts recording immediately the next time it boots (or after a restart).
- **Storage quota.** Choose 5 / 10 / 25 / 50 GB or Unlimited. When MP4s exceed the cap, the oldest files are pruned first along with their sidecars; the `_journal/` directory is always kept.

## Requirements

- **macOS 14 (Sonoma) or newer.** Capture uses ScreenCaptureKit's `SCScreenshotManager.captureImage`, which ships in macOS 14.

## Build and install

Requires the Xcode Command Line Tools (most Macs already have them):

```bash
xcode-select --install   # skip if already installed
cd ~/Documents/Claude/Projects/WorkTimeLaps
./build.sh
open WorkTimeLaps.app
```

That produces `WorkTimeLaps.app` in this folder. You can drag it to `/Applications` if you want it there.

## First launch

1. **Gatekeeper warning.** Because the binary isn't notarized, macOS may refuse to open it on first launch. Right-click the app in Finder → **Open** → **Open**. After that it launches normally.
2. **Screen Recording permission.** The very first time you press *Start Time Lapse*, macOS will either prompt you to grant Screen Recording permission or silently capture a black frame. Open **System Settings → Privacy & Security → Screen Recording**, toggle *WorkTimeLaps* on, then relaunch the app.
3. You should now see a ○ icon in the menu bar.

**Heads up about ad-hoc signing and TCC.** The app is ad-hoc codesigned, which means each rebuild changes its signature and macOS may forget your Screen Recording permission. If *Start Time Lapse* suddenly errors out after a rebuild with a TCC message, either re-toggle the permission or run:

```bash
tccutil reset ScreenCapture com.niklas.worktimelaps
```

## Using it

- Click the ○ icon → **Start Time Lapse**. Icon changes to ● followed by the current engagement number.
- Go about your day. Frames are written to disk continuously, so memory use stays flat even over long sessions.
- Click the ● icon → **Stop Time Lapse**. You'll see "Finalizing video…" briefly while the MP4 is closed out, then a notification with the filename.
- **Open Journal…** (or ⌘J with the menu open) opens the dashboard — a week grid with total recorded time per day, clickable to drill into that day's sessions with embedded playback, category breakdown, engagement curve, and per-session notes.
- **Settings… → Reveal in Finder** opens `~/Movies/WorkTimeLaps`. You'll see a `TimeLapse_*.mp4`, a matching `TimeLapse_*.json`, a `TimeLapse_*.thumb.jpg`, and a `_journal/` directory.

## Enabling the AI multi-check (optional)

1. Generate an API key at [console.anthropic.com](https://console.anthropic.com/) (Haiku is cheap — each frame check is one short vision call).
2. Click the menu-bar icon → **Set Anthropic API Key…** and paste it in. The field is a secure text input; the stored key is shown only as a fingerprint (`sk-a…Xyz9`).
3. The menu will now show "Safety check: On  (key sk-a…Xyz9)" and the recording header will include live counts: "Recording… (12 safe, 1 redacted)" plus an activity line like "Coding — editing a Swift screen-capture class".
4. To disable, open the same dialog and click **Remove Key**.

Behavior notes:

- The key lives in `UserDefaults` (`~/Library/Preferences/com.niklas.worktimelaps.plist`) in plaintext. Fine for a local utility; swap `APIKeyStore` to a Keychain-backed implementation if you want stronger protection.
- The safety half of the check is **fail-closed**: if the API call errors out or times out, the frame is redacted anyway. The sidecar records the reason (`"secret visible"` vs. `"privacy:financial"` vs. `"analyzer failed: network"`), so you can tell a genuine leak flag, a user-requested privacy redaction, and a fail-closed outage apart.
- Captures happen every 10 s, so a full 8-hour day is ~2,880 Haiku calls — in the single-digit cents range at current pricing.

## Privacy filters

Separate from the credential-leak safety check, Claude Haiku also tags each frame with a privacy category. You pick which ones get redacted in **Settings… → Privacy filters**:

- **Financial** — your banking, crypto wallets, brokerage, invoices, accounting, bill pay, payment processors. (A team budget spreadsheet at work or a GitHub PR that mentions "$0.003 per call" is *not* financial — the prompt explicitly distinguishes the user's own money from incidental currency.)
- **Personal messages** — DMs with friends or family in iMessage, WhatsApp, personal email. Work Slack / Teams is *not* this tag.
- **Medical** — patient records, therapy notes, lab results, prescriptions.
- **HR & legal** — compensation sheets, performance reviews, hiring pipelines, contracts, legal correspondence.

All four are on by default. When a frame matches an enabled tag, the image gets the same REDACTED placeholder the safety check uses, but the sidecar and daily journal still record the category and a sanitized summary. So an afternoon of paying rent and doing accounting still shows up in the log as "1h 20m of accounting, 6 frames redacted for privacy" — just without any of the specifics ending up in a video you might later share.

When the analyzer is uncertain between a privacy tag and `none`, the prompt tells it to err toward the tag. Over-redacting is a minor cost; leaking is not.

## Activity vocabulary

The `category` field is a fixed list of 11 buckets. That's good for stable charts but bad for actually understanding a day — almost everything web-based collapses into "browsing." So next to the category, every frame gets an open-vocabulary `activity` label like *"Stripe pricing config"* or *"Domain research"* or *"Lovable canvas"*. The vocabulary is built up automatically from your work, not predefined:

- A small JSON file lives at `~/Movies/WorkTimeLaps/_journal/activities.json` listing every distinct activity name the analyzer has emitted in the last two hours, plus a few example summaries per name.
- Every frame's prompt to Haiku includes that recent list with the instruction *"REUSE the exact name when it matches; only invent a new one when nothing fits."* So once "Stripe" gets created, every subsequent Stripe frame reuses the exact same string, and the activity stream can cluster cleanly.
- The prompt also bans broad words (`browsing`, `web`, `general`, `work`, `stuff`, `misc`, `app`, `task`, `thing`) as activity names — and the client validates the response, falling back to the category display name on any rule violation. So the failure mode "broad bucket eats everything forever" can't happen.
- Entries age out after **two hours**. So if you context-switch from morning Stripe to afternoon Stripe across a long lunch, the afternoon may get a fresh entry — that's a deliberate trade for "no maintenance ever needed." Inside a single session of work the labels stay rock-solid.

The companion mechanic is `sameAsBefore`: the model is fed the previous frame's activity + summary and asked, on every new frame, "is this still the same?" When yes, the recorder doesn't trust the new strings — it copies the previous ones verbatim. Result: instead of three frames labeled *"Viewing scenic mountain landscape"* / *"Viewing landscape photography of mountain and lake scenery"* / *"Viewing landscape photograph of mountain lake scenery"* (three independent calls rephrasing), you get the same string three times in a row, which is what makes the activity stream tractable. Safety and privacy are still re-evaluated on every frame regardless of `sameAsBefore` — a transient credential flash needs to be caught even when the activity didn't change.

The activity field shows up in the Journal's session-detail view as the **activity stream**: a chat-bubble feed of clustered tool-and-task blocks, each one a run of consecutive frames sharing the same activity. As the video plays, blocks reveal from the bottom — you watch your day fill in in real time.

## Apps and windows to redact

The Haiku-based `personal_messages` filter has to judge from pixels alone whether a given chat is personal or work — Telegram, in particular, sits on the boundary. To sidestep that judgment call, **Settings… → Apps and windows to redact** lets you declare a hard list of contexts that always get redacted, no matter what Haiku thinks.

Two rule kinds:

- **App** — exact bundle id match. Pick the .app via the file picker; we read its `CFBundleIdentifier` and label.
- **Window title** — case-insensitive substring of the frontmost window's title. Lets you write rules like "anything titled `Margins by Client`" or "anything from a Google Sheets tab" without having to declare a whole app.

Defaults shipped: Messages, Signal, Telegram, WhatsApp, FaceTime, Discord, Numbers, Excel, plus window-title rules for "google sheets" and "excel online." All are on by default; you can disable individual ones with the toggle, delete them with the trash icon, or add your own.

When a frame matches a context rule, the image is replaced with the REDACTED placeholder, and the **summary text in the sidecar is sanitized down to just the category display name** ("Chat", "Coding") so the frame log doesn't accidentally leak content from a DM thread. The category and engagement still get logged — so "27% of the day was chatting" stays accurate even though the visual evidence and the specific summary text are scrubbed.

Redaction precedence on a single frame (highest first): credential leak (`safe == false`) → context blocklist → privacy tag.

## The rev meter

The number next to ● is the exponentially smoothed engagement value (α=0.1, ~20-sample effective window). Colors:

- **grey**  0–39  — idle, warming up, skimming.
- **blue**  40–69 — steady work.
- **orange** 70–89 — deep work.
- **red**   90–100 — peak hair-on-fire.

A detected sleep gap (more than 3× the capture interval between frames, usually a lid-close or system sleep) forces engagement to 0 and resets the smoother, so yesterday's tachometer doesn't leak into today.

Engagement is further capped by the category's activity weight — "deep work" on a media player gets pulled down toward the media ceiling, which keeps the meter honest.

**What this is not.** It's not a productivity score. You can't measure productivity from a still frame, and the meter makes no claim about whether the work is good or valuable. It's just an effort tachometer.

## Auto-start

Toggle **Auto-start on launch** in the menu. When on, launching WorkTimeLaps starts a recording immediately — assuming Screen Recording permission is already granted. If permission has been revoked the recorder will surface the normal permission error; it won't silently fail.

To have the app itself launch at login, add it to **System Settings → General → Login Items**. With both the Login Item and Auto-start toggled on, your Mac boots into an actively-recording WorkTimeLaps.

## Journal

**Open Journal…** (⌘J with the menu open) brings up a dashboard built on top of `_journal/` and the per-session sidecars.

- **Week grid.** Seven cells across, one per day. Each cell shows the weekday, date, total recorded time, and a colored chip for the day's dominant category. The **current day** is outlined in the accent color and — if you're recording right now — pulses a small red dot. Prev / next / "This week" buttons to navigate. Days with nothing recorded look dimmed but are still clickable.
- **Day detail.** Click a cell to see that day's header stats (total time, sessions, frames, redacted, average engagement), a 24-hour timeline bar with each session drawn as a colored block by category, and a list of every session as a row with thumbnail, time range, duration, and stats. A currently-recording session shows up as a "LIVE" row at the bottom of the list; it updates in real time as frames land.
- **Session detail.** A **two-column layout**. The left column carries the embedded **AVPlayer**, an engagement-over-time curve from the sidecar, a **donut + bar-legend** category breakdown that animates as the cursor advances, and a **note editor** that saves back into `_journal/YYYY-MM-DD.json` (⌘S). The right column is the **activity stream** — pinned full-height — with a Live/All toggle. *Live* keeps the most recent five blocks at the top with a spring slide-in as new entries arrive (older ones drop off the bottom); *All* is the full scrollable chronological list for scrubbing back. Every card uses a thin-material glass surface so the layout feels light rather than boxy.
- **Playback-synced visualization.** As the video plays, a vertical line slides across the engagement chart at the current playback time, and the category bars start at zero and grow toward their final percentages — at any moment, each bar shows what fraction of the *full* session was that category, counting only frames played up to here. So you feel the rhythm of the day as you watch: the bars tween smoothly, the playhead tracks the curve, and the percentages count up in numeric-text transitions.

The Journal view is also the plug-in point for Phase 9 (cheerleader): the same reader (`JournalStore`) that powers this UI will serve the reviewer, so both operate on a single consistent view of history.

## Storage quota

The app defaults to a 10 GB cap on MP4 files. At 3 Mbps that's ~6 weeks of 8-hour days before the oldest recordings start getting pruned.

- Change the cap in **Settings… → Storage cap** (5 / 10 / 25 / 50 GB / Unlimited).
- Pruning happens at launch, after each session stop, and immediately after changing the cap. Oldest MP4s go first; sidecar JSON and thumbnail follow the MP4 they describe.
- `_journal/` is never pruned. Even after old videos are gone, you keep the daily digest (counts, categories, average engagement) for the long-term reviewer.

## Project layout

```
WorkTimeLaps/
├── Sources/
│   ├── main.swift                 # NSApplication bootstrap
│   ├── AppDelegate.swift          # App lifecycle + auto-start + retention sweep
│   ├── MenuBarController.swift    # NSStatusItem + menu + rev meter + user actions
│   ├── TimeLapseRecorder.swift    # Capture timer + streaming AVAssetWriter + session state
│   ├── VideoEncoder.swift         # CGImage → CVPixelBuffer helpers
│   ├── FrameAnalyzer.swift        # Claude Haiku vision call (safety + category + summary + engagement + privacy)
│   ├── FrameAnalysis.swift        # FrameCategory + FrameAnalysis + PrivacyTag types
│   ├── RecordingSession.swift     # Session sidecar Codable + atomic writer
│   ├── Journal.swift              # Per-day digest under _journal/ + notes setter + update notification
│   ├── JournalStore.swift         # Shared reader: week-grid + day-detail + live-session merge
│   ├── JournalWindow.swift        # SwiftUI Journal window (week grid → day → session detail + activity stream)
│   ├── ActivityVocabulary.swift   # 2-hour rolling vocabulary of activity labels
│   ├── PrivacyFilterStore.swift   # UserDefaults-backed privacy toggle store
│   ├── PrivacyRulesStore.swift    # App + window-title blocklist (rule engine)
│   ├── WorkContextProbe.swift     # Frontmost app + window-title sampler
│   ├── SettingsWindow.swift       # SwiftUI Settings window (privacy + rules + quota + folder)
│   ├── RetentionSweeper.swift     # Size-quota pruner
│   ├── RedactedFrame.swift        # Black "REDACTED" placeholder generator
│   └── APIKeyStore.swift          # Persists the Anthropic key in UserDefaults
├── Resources/
│   └── Info.plist                 # LSUIElement=true, NSScreenCaptureUsageDescription
├── build.sh                       # Compiles to WorkTimeLaps.app
└── README.md
```

## Tweaking behavior

All the knobs live at the top of `TimeLapseRecorder.swift`:

- `captureInterval` — seconds between screenshots (default 10).
- `playbackFPS` — frames per second in the exported MP4 (default 10). Raising this makes playback faster; lowering makes it smoother-looking but slower.
- `videoBitrate` — H.264 bitrate in bits/sec (default 3 Mbps). Screen content compresses very well so this is usually plenty; bump if you see artifacts.
- `sleepGapMultiplier` — how many times the capture interval counts as a sleep/lid-close (default 3×).
- `engagementAlpha` — EMA smoothing factor (default 0.1). Lower = smoother but less responsive.

If you want to capture a different display, change `CGMainDisplayID()` in `TimeLapseRecorder.swift` — `CGGetActiveDisplayList` will give you the list.

## Sidecar JSON format

Each `TimeLapse_<stem>.mp4` has a companion `TimeLapse_<stem>.json`:

```jsonc
{
  "id": "TimeLapse_2026-04-23_09-14-02",
  "video": "TimeLapse_2026-04-23_09-14-02.mp4",
  "startedAt": "2026-04-23T09:14:02Z",
  "endedAt":   "2026-04-23T11:42:18Z",
  "lastUpdated": "2026-04-23T11:42:18Z",
  "captureIntervalSec": 10,
  "playbackFPS": 10,
  "display": { "width": 3456, "height": 2234 },
  "frames": [
    {
      "i": 0,
      "t": "2026-04-23T09:14:02Z",
      "category": "coding",
      "activity": "WorkTimeLaps",
      "summary": "editing Swift screen-capture class",
      "engagement": 78,
      "engagementSmoothed": 78,
      "redacted": false,
      "redactionReason": null,
      "sleepGapSec": null
    }
    // …
  ],
  "summary": {
    "totalFrames": 892,
    "safeFrames": 881,
    "redactedFrames": 11,
    "averageEngagement": 64,
    "topCategory": "coding",
    "categoryCounts": { "coding": 540, "chat": 180, "meeting": 60, "other": 112 }
  }
}
```

`lastUpdated` is rewritten after every frame, so even a crashed session tells you how far it got.

## Alternative: open as an Xcode project

If you'd rather work on it in Xcode:

1. Xcode → File → New → Project… → **macOS App** (not SwiftUI — pick Storyboard, it doesn't matter). Name it **WorkTimeLaps**. Uncheck "Use Core Data", "Include Tests".
2. Delete the generated `AppDelegate.swift`, `ViewController.swift`, `Main.storyboard`, and the `@main` property in the project settings — or more simply, replace the whole generated `AppDelegate.swift` with the one in this repo and delete the storyboard.
3. In the target's Info.plist, set **Application is agent (UIElement)** = YES, and add **Privacy - Screen Capture Usage Description** with the text from this repo's Info.plist.
4. Remove the auto-generated `NSApplicationMain` / storyboard entry point and add the files under `Sources/` to the target.

The `build.sh` path is simpler; use Xcode only if you want to iterate with the debugger.

## Known limitations

- Captures the main display only. Second-monitor support would be a ~10-line change inside `TimeLapseRecorder.start` — pick a different `SCDisplay` from `content.displays`.
- No click indicators or cursor highlights — it's a flat screenshot. The cursor itself is included (controlled by `config.showsCursor`).
- If you press Stop before the first capture completes, the recording finalizes with just that single starting frame.
- The app is ad-hoc signed (`codesign --sign -`), so macOS will show the "unidentified developer" warning on first launch, and each rebuild may re-prompt for Screen Recording permission — see the `tccutil` note above.
- Sidecar JSON rewrites after every frame. At ~hundreds to a few thousand frames this is sub-millisecond; for extreme multi-day recordings (tens of thousands of frames) the growing write size becomes noticeable. A future optimization would be to append-only log the frames and compact on stop.

## Roadmap

- **Slack status push (Phase 8).** Every 10 s, push the current category + summary as your Slack status ("Working on: editing Swift screen-capture class").
- **The cheerleader (Phase 9).** A weekly reviewer that reads the `_journal/` files via the same `JournalStore` the Journal window uses and occasionally, when you've actually been hammering away for days, just says *well done*. Later: a "Summarize this day for me" action in the Journal window that sends the day's sidecar JSON to an AI for a narrative recap.
