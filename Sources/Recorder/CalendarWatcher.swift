import Foundation
import EventKit
import AppKit
import ScreenCaptureKit

@MainActor
protocol CalendarWatcherDelegate: AnyObject {
    /// Called when a watched meeting is starting. Implementer should start
    /// a recording with the given title and arrange to stop it at endDate.
    func calendarWatcher(_ watcher: CalendarWatcher,
                         shouldStartRecordingFor event: EKEvent,
                         autoStopAt endDate: Date)
}

/// Watches the user's calendars for events that look like meetings and
/// notifies the delegate ~at event start so it can auto-record.
@MainActor
final class CalendarWatcher {
    weak var delegate: CalendarWatcherDelegate?

    private let store = EKEventStore()
    private var pollTimer: Timer?
    private var scheduledForEvent: [String: Date] = [:]
    private var fireTasks: [String: Task<Void, Never>] = [:]

    var isEnabled: Bool { pollTimer != nil }

    /// Request access + start polling. Returns true if access granted.
    @discardableResult
    func enable() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { return false }
        } catch {
            NSLog("Calendar access request failed: \(error)")
            return false
        }

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
        return true
    }

    func disable() {
        pollTimer?.invalidate()
        pollTimer = nil
        for task in fireTasks.values { task.cancel() }
        fireTasks.removeAll()
        scheduledForEvent.removeAll()
    }

    // MARK: - Polling

    private func poll() {
        let now = Date()
        let horizon = now.addingTimeInterval(15 * 60) // next 15 minutes
        let predicate = store.predicateForEvents(withStart: now, end: horizon, calendars: nil)
        let events = store.events(matching: predicate)

        for event in events {
            guard let id = event.eventIdentifier else { continue }
            guard scheduledForEvent[id] == nil else { continue }
            guard isLikelyMeeting(event) else { continue }
            schedule(event)
        }
    }

    private func schedule(_ event: EKEvent) {
        guard let id = event.eventIdentifier else { return }
        let start = event.startDate ?? Date()
        let delay = max(0, start.timeIntervalSinceNow)
        scheduledForEvent[id] = start

        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.fire(event: event)
            }
        }
        fireTasks[id] = task
    }

    private func fire(event: EKEvent) {
        let endDate = event.endDate ?? Date().addingTimeInterval(30 * 60)
        delegate?.calendarWatcher(self, shouldStartRecordingFor: event, autoStopAt: endDate)
    }

    // MARK: - Heuristics

    /// Treat an event as a meeting if it has multiple attendees, OR a
    /// known conferencing URL/keyword in location or notes.
    private func isLikelyMeeting(_ event: EKEvent) -> Bool {
        if let attendees = event.attendees, attendees.count >= 2 { return true }
        let blob = ((event.location ?? "") + " " + (event.notes ?? "")).lowercased()
        let conferenceMarkers = [
            "zoom.us", "meet.google.com", "teams.microsoft.com",
            "webex.com", "hangouts.google.com", "discord.gg",
        ]
        for marker in conferenceMarkers where blob.contains(marker) { return true }
        // Heuristic on keyword "call", "standup", "1:1" in title
        let title = (event.title ?? "").lowercased()
        let titleHints = ["call", "standup", "stand-up", "1:1", "sync", "retro", "review", "meeting"]
        return titleHints.contains(where: { title.contains($0) })
    }
}
