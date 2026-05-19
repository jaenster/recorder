# Recorder

macOS menu-bar app that records your microphone alongside a specific running app's audio (Slack, Zoom, Chrome tabs, …), transcribes the result on-device, and exposes everything to Claude via MCP.

## What it does

- **Stereo channel trick.** Mic on L, target app on R. Per-channel transcription gives free speaker labeling — no diarization model needed.
- **On-device transcription.** Uses macOS 26's `SpeechAnalyzer`. Optional Whisper fallback for accuracy-critical cases.
- **On-device summarization.** Apple Intelligence (`FoundationModels.framework`) auto-produces a markdown summary with action items.
- **Calendar auto-record.** Watches your calendars; when a meeting starts, picks the app currently using the mic and records until the event ends.
- **Claude-ready.** Stdio MCP server exposes `list_recordings`, `get_latest_transcript`, `get_latest_summary`, `search_recordings`, etc. — any Claude Code session can pull a transcript into context.

## Why it exists

Off-the-shelf tools (Audio Hijack, MacWhisper, Granola) cover most of this, but none let you wire the labeled transcript directly into your own Claude prompts. The whole point is: record → transcribe → ask Claude to extract to-dos, in whatever workflow you want.

## Requirements

- macOS 26 (Tahoe) — for `SpeechAnalyzer` and `FoundationModels`. Falls back gracefully on older macOS for things it can.
- Xcode toolchain installed (`swiftc`, command-line tools).
- Node ≥ 20 for the MCP server.
- **Headphones during recording.** Without them your speakers leak the other party's voice into the mic channel and they end up on both sides of the transcript.

## Setup

```bash
git clone https://github.com/jaenster/recorder
cd recorder

# One-time: create a self-signed code-signing identity so TCC permission
# grants survive rebuilds instead of re-prompting on every build.
./setup-dev-cert.sh

# Build .app bundle + sign
./build.sh

# Install MCP server deps
( cd mcp-server && npm install )

open Recorder.app
```

First launch prompts for **Microphone**, **Screen Recording**, **Speech Recognition** (one-time), **Calendar** (only if you enable auto-record meetings), and **Notifications**. Grant them all.

### MCP server (for Claude Code)

```bash
claude mcp add recorder -s user -- node $(pwd)/mcp-server/index.js
```

After this, any Claude Code session has `mcp__recorder__*` tools available.

## Using it

**Menu bar.** Click the `🎙 Rec` icon. Pick an app under "Record from app" (the top of the submenu only lists apps currently using your mic — i.e. apps you're likely in a call with). Click *Stop* when done.

**Global hotkey.** `⌃⌥R` toggles recording on the **frontmost app**'s audio without touching the menu.

**Shortcuts.** Recorder exposes four App Intents to Shortcuts.app: `Get Latest Transcript`, `Get Latest Summary`, `List Recordings`, `Open Recordings Folder`. Compose them into Siri commands, hotkey automations, calendar triggers, etc.

**Spotlight.** Every transcript is indexed via CoreSpotlight. `⌘Space` → type any phrase from any past meeting → it shows up.

## File outputs

Every recording produces (in `~/Recordings/`):

```
voice-2026-05-19-141203-q4-planning.m4a       stereo audio, mic L / app R
voice-2026-05-19-141203-q4-planning.txt       [mm:ss] ME / THEM lines
voice-2026-05-19-141203-q4-planning.summary.md  Apple Intelligence summary (if available)
voice-2026-05-19-141203-q4-planning.event.json  Calendar sidecar (only for auto-recorded meetings)
```

If calendar metadata identifies a 1:1, `THEM` is replaced with the counterparty's first name throughout the transcript.

## Architecture

```
Sources/Recorder/
├── main.swift                       NSApplication bootstrap
├── AppDelegate.swift                Menu, state, transcription orchestration
├── AppPicker.swift                  SCShareableContent → submenu
├── AudioProcessInspector.swift      CoreAudio: who's using the mic
├── CalendarWatcher.swift            EventKit polling + auto-record
├── Recorder.swift                   SCStream owner
├── StereoWriter.swift               AVAssetWriter mic→L / app→R, VU peaks
├── ChannelSplitter.swift            stereo .m4a → two mono PCM
├── SpeechAnalyzerTranscriber.swift  macOS 26 on-device ASR
├── WhisperTranscriber.swift         OpenAI Whisper fallback
├── Summarizer.swift                 FoundationModels meeting summarizer
├── TranscriptBuilder.swift          merge + speaker-label + format
├── RecordingMetadata.swift          .event.json sidecar
├── SpotlightIndexer.swift           CoreSpotlight indexing
├── GlobalHotkey.swift               Carbon ⌃⌥R registration
├── AppIntents.swift                 Shortcuts integration
├── MicDevices.swift                 input device enumeration
├── Notifier.swift                   UNUserNotifications
├── Keychain.swift                   API key storage
└── Settings.swift                   UserDefaults/Keychain facade

mcp-server/
└── index.js                         Stdio MCP server (Node)
```

## Known limitations

- **Headphones required** — speaker leak makes the stereo trick collapse on speakers.
- **Channel-as-speaker breaks down beyond 1:1.** Group calls still record cleanly but everyone-else collapses into `THEM`.
- **Whisper word timestamps drift by ~hundreds of ms.** Lines are grouped per speaker turn, so within-line ordering can occasionally be off when both channels overlap. Not enough to matter for action-item extraction.
- **Chrome / Electron tab audio** lives in helper processes. The picker aggregates helpers by bundle prefix; if you find an app whose audio doesn't capture, file an issue with its bundle layout.
- **Ad-hoc / self-signed signing only.** No notarization. Rebuilds with the dev cert preserve TCC grants, but TCC will prompt anew on the first run after `setup-dev-cert.sh`.

## Contributing

PRs welcome. File issues for bugs or apps whose audio doesn't capture (include the bundle id and what helpers it spawns). For new features, open an issue first to discuss scope — this is a small focused tool, not a meeting-platform suite.

Quick checklist before sending a PR:
- `swift build -c release --arch arm64` must succeed
- `./build.sh && open Recorder.app` must launch and record cleanly
- No new third-party Swift dependencies unless there's a real reason

## License

[MIT](LICENSE). Do whatever you want; no warranty.
