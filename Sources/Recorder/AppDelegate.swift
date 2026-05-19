import AppKit
import ScreenCaptureKit
import EventKit
@preconcurrency import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?

    private let recorder = Recorder()
    private let calendarWatcher = CalendarWatcher()
    private var autoStopTask: Task<Void, Never>?
    private var isRecording: Bool = false {
        didSet { refreshUI() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recorder")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeft
            button.title = "Rec"
        }

        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        recorder.delegate = self
        refreshUI()

        if !Settings.shared.headphonesAlertShown {
            showHeadphonesAlert()
            Settings.shared.headphonesAlertShown = true
        }

        Notifier.requestPermissionIfNeeded()

        calendarWatcher.delegate = self
        if Settings.shared.autoRecordMeetings {
            Task { _ = await calendarWatcher.enable() }
        }

        SpotlightIndexer.indexExisting()

        let registered = GlobalHotkey.shared.registerCtrlOptR { [weak self] in
            Task { @MainActor in await self?.hotkeyToggleRecording() }
        }
        if !registered {
            NSLog("Could not register ⌃⌥R hotkey (likely taken by another app).")
        }
    }

    /// Toggle recording via global hotkey. If not recording, start on the
    /// currently-frontmost app's audio. If recording, stop.
    private func hotkeyToggleRecording() async {
        if isRecording {
            await recorder.stop()
            return
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier else {
            presentError(NSError(domain: "Recorder", code: 100,
                                 userInfo: [NSLocalizedDescriptionKey: "No frontmost app to record from."]))
            return
        }
        let all = (try? await AppPicker.currentEntries(mode: .all)) ?? []
        guard let entry = all.first(where: { $0.bundleIdentifier == bundle }) else {
            presentError(NSError(domain: "Recorder", code: 101,
                                 userInfo: [NSLocalizedDescriptionKey: "Frontmost app \(front.localizedName ?? bundle) isn't capturable by ScreenCaptureKit."]))
            return
        }
        do {
            try await recorder.start(apps: entry.apps)
            recordingStartedAt = Date()
            isRecording = true
            startElapsedTimer()
        } catch {
            presentError(error)
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshUI()
        if !isRecording {
            Task { await self.refreshAppPickerSubmenu() }
        }
    }

    private func refreshUI() {
        menu.removeAllItems()

        if let button = statusItem.button {
            let name = isRecording ? "record.circle" : "mic.fill"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Recorder")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeft
            if isRecording, let started = recordingStartedAt {
                button.title = " " + formatElapsed(Date().timeIntervalSince(started))
            } else {
                button.title = " Rec"
            }
        }

        if isRecording {
            let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            let item = NSMenuItem(title: "Stop recording (\(formatElapsed(elapsed)))",
                                  action: #selector(stopTapped),
                                  keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        } else {
            let frontmost = NSMenuItem(title: "Record frontmost app  ⌃⌥R",
                                       action: #selector(recordFrontmost),
                                       keyEquivalent: "")
            frontmost.target = self
            menu.addItem(frontmost)

            let pickItem = NSMenuItem(title: "Record from app", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let placeholder = NSMenuItem(title: "Loading apps…", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
            pickItem.submenu = submenu
            menu.addItem(pickItem)
        }

        menu.addItem(.separator())

        let openFolder = NSMenuItem(title: "Open recordings folder",
                                    action: #selector(openRecordingsFolder),
                                    keyEquivalent: "")
        openFolder.target = self
        menu.addItem(openFolder)

        let retx = NSMenuItem(title: "Re-transcribe latest",
                              action: #selector(retranscribeLatest),
                              keyEquivalent: "")
        retx.target = self
        retx.isEnabled = !isRecording
        menu.addItem(retx)

        let backendMenu = NSMenu()
        let onDeviceItem = NSMenuItem(title: "On-device (SpeechAnalyzer)",
                                      action: #selector(setBackendOnDevice),
                                      keyEquivalent: "")
        onDeviceItem.target = self
        onDeviceItem.state = Settings.shared.backend == .onDevice ? .on : .off
        backendMenu.addItem(onDeviceItem)

        let whisperItem = NSMenuItem(title: "OpenAI Whisper",
                                     action: #selector(setBackendWhisper),
                                     keyEquivalent: "")
        whisperItem.target = self
        whisperItem.state = Settings.shared.backend == .whisper ? .on : .off
        backendMenu.addItem(whisperItem)

        let backendItem = NSMenuItem(title: "Transcription backend", action: nil, keyEquivalent: "")
        backendItem.submenu = backendMenu
        menu.addItem(backendItem)

        let apiKeyItem = NSMenuItem(title: "Set OpenAI API key…",
                                    action: #selector(setAPIKey),
                                    keyEquivalent: "")
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

        let micMenu = NSMenu()
        let micDevices = MicDevices.available()
        let currentMicID = Settings.shared.preferredMicID
        let defaultItem = NSMenuItem(title: "System Default",
                                     action: #selector(setMic(_:)),
                                     keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = NSNull()
        defaultItem.state = currentMicID == nil ? .on : .off
        micMenu.addItem(defaultItem)
        if !micDevices.isEmpty { micMenu.addItem(.separator()) }
        for device in micDevices {
            let item = NSMenuItem(title: device.name,
                                  action: #selector(setMic(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID as NSString
            item.state = currentMicID == device.uniqueID ? .on : .off
            micMenu.addItem(item)
        }
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = micMenu
        menu.addItem(micItem)

        let autoMeet = NSMenuItem(title: "Auto-record meetings",
                                  action: #selector(toggleAutoRecordMeetings),
                                  keyEquivalent: "")
        autoMeet.target = self
        autoMeet.state = Settings.shared.autoRecordMeetings ? .on : .off
        menu.addItem(autoMeet)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func refreshAppPickerSubmenu() async {
        guard !isRecording else { return }
        guard let pickItem = menu.items.first(where: { $0.title == "Record from app" }) else { return }

        let inCall = (try? await AppPicker.currentEntries(mode: .inCall)) ?? []
        let primary: [AppPickEntry]
        let header: String
        if !inCall.isEmpty {
            primary = inCall
            header = "In a call (using mic)"
        } else {
            let audible = (try? await AppPicker.currentEntries(mode: .audible)) ?? []
            primary = audible
            header = audible.isEmpty ? "No apps producing audio" : "Currently producing audio"
        }

        let submenu = NSMenu()
        let headerItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        submenu.addItem(headerItem)

        for entry in primary {
            submenu.addItem(menuItem(for: entry))
        }

        submenu.addItem(.separator())
        let allMenu = NSMenu()
        let loading = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        allMenu.addItem(loading)
        let allItem = NSMenuItem(title: "All running apps", action: nil, keyEquivalent: "")
        allItem.submenu = allMenu
        submenu.addItem(allItem)

        pickItem.submenu = submenu

        // Populate "all" lazily.
        Task {
            let all = (try? await AppPicker.currentEntries(mode: .all)) ?? []
            await MainActor.run {
                allMenu.removeAllItems()
                if all.isEmpty {
                    let none = NSMenuItem(title: "(none)", action: nil, keyEquivalent: "")
                    none.isEnabled = false
                    allMenu.addItem(none)
                } else {
                    for entry in all {
                        allMenu.addItem(self.menuItem(for: entry))
                    }
                }
            }
        }
    }

    private func menuItem(for entry: AppPickEntry) -> NSMenuItem {
        let item = NSMenuItem(title: entry.displayName,
                              action: #selector(startRecordingFromApp(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = entry
        if let icon = entry.icon {
            let resized = NSImage(size: NSSize(width: 16, height: 16))
            resized.lockFocus()
            icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            resized.unlockFocus()
            item.image = resized
        }
        return item
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - Actions

    @objc private func startRecordingFromApp(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? AppPickEntry else { return }
        Task {
            do {
                try await recorder.start(apps: entry.apps)
                self.recordingStartedAt = Date()
                self.isRecording = true
                self.startElapsedTimer()
            } catch {
                self.presentError(error)
            }
        }
    }

    @objc private func recordFrontmost() {
        Task { await self.hotkeyToggleRecording() }
    }

    @objc private func stopTapped() {
        Task {
            await recorder.stop()
        }
    }

    @objc private func retranscribeLatest() {
        let folder = recordingsFolderURL()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let latest = files
            .filter { $0.pathExtension == "m4a" && $0.lastPathComponent.hasPrefix("voice-") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .first
        guard let latest else {
            let alert = NSAlert()
            alert.messageText = "Nothing to re-transcribe"
            alert.informativeText = "No recordings in \(folder.path)."
            alert.runModal()
            return
        }
        Task { await self.transcribe(url: latest) }
    }

    @objc private func openRecordingsFolder() {
        let url = recordingsFolderURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func setMic(_ sender: NSMenuItem) {
        if sender.representedObject is NSNull {
            Settings.shared.preferredMicID = nil
        } else if let id = sender.representedObject as? NSString {
            Settings.shared.preferredMicID = id as String
        }
        refreshUI()
    }

    @objc private func toggleAutoRecordMeetings() {
        let now = !Settings.shared.autoRecordMeetings
        Settings.shared.autoRecordMeetings = now
        if now {
            Task {
                let granted = await self.calendarWatcher.enable()
                if !granted {
                    Settings.shared.autoRecordMeetings = false
                    let alert = NSAlert()
                    alert.messageText = "Calendar access denied"
                    alert.informativeText = "Grant access in System Settings → Privacy & Security → Calendars, then toggle again."
                    alert.runModal()
                }
                self.refreshUI()
            }
        } else {
            calendarWatcher.disable()
        }
        refreshUI()
    }

    @objc private func setBackendOnDevice() {
        Settings.shared.backend = .onDevice
        refreshUI()
    }

    @objc private func setBackendWhisper() {
        Settings.shared.backend = .whisper
        refreshUI()
    }

    @objc private func setAPIKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API key"
        alert.informativeText = "Used only when Whisper backend is selected."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = Settings.shared.openAIAPIKey ?? ""
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            Settings.shared.openAIAPIKey = field.stringValue.isEmpty ? nil : field.stringValue
        }
    }

    private func showHeadphonesAlert() {
        let alert = NSAlert()
        alert.messageText = "Use headphones"
        alert.informativeText = """
        This app records your mic on the LEFT channel and the selected app's audio on the RIGHT channel.

        Without headphones, the other party's voice plays through your speakers and is picked up by your mic — their words then appear on both channels in the transcript.

        Wear headphones during recording for clean speaker separation.
        """
        alert.addButton(withTitle: "Got it")
        alert.runModal()
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMeter() }
        }
    }

    private func tickMeter() {
        guard isRecording, let button = statusItem.button else { return }
        let (mic, app) = recorder.consumePeaks()
        let micGlyph = vuBlock(forLinear: mic)
        let appGlyph = vuBlock(forLinear: app)
        if let started = recordingStartedAt {
            button.title = " \(formatElapsed(Date().timeIntervalSince(started)))  L\(micGlyph) R\(appGlyph)"
        }
    }

    private func vuBlock(forLinear v: Float) -> String {
        if v <= 0 { return "▁" }
        let db = 20 * log10(v)
        switch db {
        case ..<(-50):       return "▁"
        case (-50)..<(-40):  return "▂"
        case (-40)..<(-30):  return "▃"
        case (-30)..<(-20):  return "▄"
        case (-20)..<(-12):  return "▅"
        case (-12)..<(-6):   return "▆"
        case (-6)..<(-3):    return "▇"
        default:             return "█"
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Recorder error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

extension AppDelegate: CalendarWatcherDelegate {
    func calendarWatcher(_ watcher: CalendarWatcher,
                         shouldStartRecordingFor event: EKEvent,
                         autoStopAt endDate: Date) {
        guard !isRecording else {
            NSLog("Skipping calendar auto-record for '\(event.title ?? "?")' — already recording.")
            return
        }
        let title = event.title ?? "Meeting"
        Task {
            // Pick: app currently using the mic (typical for conferencing
            // apps the moment a meeting starts), else frontmost app.
            let pids = AudioProcessInspector.pidsUsingMicrophone()
            let all = (try? await AppPicker.currentEntries(mode: .all)) ?? []
            let entry: AppPickEntry?
            if let candidate = all.first(where: { entry in
                entry.apps.contains(where: { pids.contains(pid_t($0.processID)) })
            }) {
                entry = candidate
            } else if let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                      let candidate = all.first(where: { $0.bundleIdentifier == frontBundle }) {
                entry = candidate
            } else {
                entry = nil
            }
            guard let entry else {
                Notifier.notify(title: "Meeting starting: \(title)",
                                body: "Couldn't auto-detect a conferencing app. Use ⌃⌥R to record manually.")
                return
            }
            // Build sidecar metadata from the calendar event so the transcript
            // can label the counterparty by name on a 1:1.
            let attendees = (event.attendees ?? []).compactMap { p -> RecordingMetadata.Attendee? in
                // Skip the organizer — usually that's the user's own account
                // on internal meetings. (For external meetings the organizer
                // is the counterparty, so we keep them.)
                if p.isCurrentUser { return nil }
                let email = (p.url.absoluteString.hasPrefix("mailto:"))
                    ? String(p.url.absoluteString.dropFirst("mailto:".count))
                    : nil
                return RecordingMetadata.Attendee(name: p.name, email: email)
            }
            let metadata = RecordingMetadata(
                eventTitle: title,
                attendees: attendees,
                startedAt: Date(),
                sourceAppBundleID: entry.bundleIdentifier
            )
            do {
                try await recorder.start(apps: entry.apps, titleSuffix: title, metadata: metadata)
                recordingStartedAt = Date()
                isRecording = true
                startElapsedTimer()
                Notifier.notify(title: "Recording: \(title)",
                                body: "Source: \(entry.displayName). Will auto-stop at meeting end.")
                scheduleAutoStop(at: endDate.addingTimeInterval(120))
            } catch {
                Notifier.notify(title: "Auto-record failed: \(title)",
                                body: error.localizedDescription)
            }
        }
    }

    private func scheduleAutoStop(at date: Date) {
        autoStopTask?.cancel()
        let delay = max(0, date.timeIntervalSinceNow)
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.recorder.stop()
        }
    }
}

extension AppDelegate: RecorderDelegate {
    func recorder(_ recorder: Recorder, didFailWith error: Error) {
        isRecording = false
        recordingStartedAt = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        presentError(error)
    }

    func recorder(_ recorder: Recorder, didFinishTo url: URL) {
        isRecording = false
        recordingStartedAt = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        NSLog("Saved recording: \(url.path)")
        Task { await self.transcribe(url: url) }
    }

    private func transcribe(url: URL) async {
        do {
            let backend: TranscriberBackend
            switch Settings.shared.backend {
            case .onDevice:
                if #available(macOS 26.0, *) {
                    backend = SpeechAnalyzerTranscriber()
                } else {
                    throw TranscriberError.modelUnavailable(
                        "On-device transcription requires macOS 26. Switch to Whisper in the menu."
                    )
                }
            case .whisper:
                guard let key = Settings.shared.openAIAPIKey, !key.isEmpty else {
                    throw TranscriberError.noAPIKey
                }
                backend = WhisperTranscriber(apiKey: key)
            }

            let (left, right, _) = try await ChannelSplitter.split(url: url)
            let me: [Word]
            let them: [Word]
            if channelHasSignal(left) {
                me = try await backend.transcribe(pcm: left, label: .me)
            } else {
                NSLog("Skipping ME channel: no signal above -20 dBFS")
                me = []
            }
            if channelHasSignal(right) {
                them = try await backend.transcribe(pcm: right, label: .them)
            } else {
                NSLog("Skipping THEM channel: no signal above -20 dBFS")
                them = []
            }
            let meta = RecordingMetadata.load(forRecording: url)
            let themLabel = meta?.counterpartyDisplayName(userEmail: nil)
            let text = TranscriptBuilder.format(me: me, them: them, themLabel: themLabel)
            let txtURL = url.deletingPathExtension().appendingPathExtension("txt")
            try text.write(to: txtURL, atomically: true, encoding: .utf8)
            NSLog("Transcript saved: \(txtURL.path)")
            notifyTranscriptReady(at: txtURL)
            SpotlightIndexer.index(url: txtURL)

            if #available(macOS 26.0, *), Settings.shared.autoSummarize, !text.isEmpty {
                Task.detached {
                    do {
                        guard let md = try await Summarizer.summarize(transcript: text) else {
                            NSLog("Summarizer unavailable on this machine.")
                            return
                        }
                        let mdURL = url
                            .deletingPathExtension()
                            .appendingPathExtension("summary.md")
                        try md.write(to: mdURL, atomically: true, encoding: .utf8)
                        NSLog("Summary saved: \(mdURL.path)")
                        await MainActor.run { SpotlightIndexer.index(url: mdURL) }
                    } catch {
                        NSLog("Summarization failed: \(error)")
                    }
                }
            }
        } catch {
            NSLog("Transcription failed: \(error)")
            presentError(error)
        }
    }

    private func notifyTranscriptReady(at url: URL) {
        Notifier.notify(title: "Transcript ready", body: url.lastPathComponent)
    }
}

func recordingsFolderURL() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Recordings", isDirectory: true)
}
