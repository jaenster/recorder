import Foundation

/// Sidecar JSON written next to voice-*.m4a when a recording has known
/// context (calendar meeting, attendees, etc.). Drives speaker labeling
/// and lets future UI surface meeting titles without re-parsing filenames.
struct RecordingMetadata: Codable {
    var eventTitle: String?
    var attendees: [Attendee]
    var startedAt: Date
    var sourceAppBundleID: String?

    struct Attendee: Codable {
        var name: String?
        var email: String?
    }

    /// First attendee that isn't obviously "me" — used as the THEM label.
    /// Returns nil if we can't pick a single counterparty (group meetings,
    /// no named attendees, etc.).
    func counterpartyDisplayName(userEmail: String?) -> String? {
        let others: [Attendee]
        if let userEmail, !userEmail.isEmpty {
            let me = userEmail.lowercased()
            others = attendees.filter { ($0.email?.lowercased() ?? "") != me }
        } else {
            others = attendees
        }
        guard others.count == 1, let only = others.first else { return nil }
        if let name = only.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            // Use first name only — keeps the transcript tight.
            return name.split(separator: " ").first.map(String.init)
        }
        if let email = only.email, let local = email.split(separator: "@").first {
            return String(local).capitalized
        }
        return nil
    }

    static func sidecarURL(forRecording url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("event.json")
    }

    static func load(forRecording url: URL) -> RecordingMetadata? {
        let sidecar = sidecarURL(forRecording: url)
        guard let data = try? Data(contentsOf: sidecar) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(RecordingMetadata.self, from: data)
    }

    func write(forRecording url: URL) {
        let sidecar = Self.sidecarURL(forRecording: url)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: sidecar)
        }
    }
}
