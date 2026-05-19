import Foundation

enum TranscriptionBackend: String {
    case onDevice
    case whisper
}

@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let backend = "transcription_backend"
        static let apiKey = "openai_api_key"
        static let headphonesAlertShown = "headphones_alert_shown"
        static let autoTranscribe = "auto_transcribe"
        static let autoSummarize = "auto_summarize"
        static let autoRecordMeetings = "auto_record_meetings"
        static let preferredMicID = "preferred_mic_id"
    }

    var backend: TranscriptionBackend {
        get {
            defaults.string(forKey: Key.backend).flatMap(TranscriptionBackend.init(rawValue:)) ?? .onDevice
        }
        set { defaults.set(newValue.rawValue, forKey: Key.backend) }
    }

    /// Lives in Keychain. Migrated from UserDefaults on first read after
    /// upgrade if needed.
    var openAIAPIKey: String? {
        get {
            if let kc = Keychain.get(Key.apiKey) {
                return kc
            }
            // Migration: if an old plaintext key is in UserDefaults, move it
            // to Keychain and clear the UserDefaults copy.
            if let legacy = defaults.string(forKey: Key.apiKey), !legacy.isEmpty {
                Keychain.set(legacy, for: Key.apiKey)
                defaults.removeObject(forKey: Key.apiKey)
                return legacy
            }
            return nil
        }
        set {
            if let v = newValue, !v.isEmpty {
                Keychain.set(v, for: Key.apiKey)
            } else {
                Keychain.delete(Key.apiKey)
            }
            defaults.removeObject(forKey: Key.apiKey)
        }
    }

    var headphonesAlertShown: Bool {
        get { defaults.bool(forKey: Key.headphonesAlertShown) }
        set { defaults.set(newValue, forKey: Key.headphonesAlertShown) }
    }

    var autoTranscribe: Bool {
        get {
            if defaults.object(forKey: Key.autoTranscribe) == nil { return true }
            return defaults.bool(forKey: Key.autoTranscribe)
        }
        set { defaults.set(newValue, forKey: Key.autoTranscribe) }
    }

    var autoSummarize: Bool {
        get {
            if defaults.object(forKey: Key.autoSummarize) == nil { return true }
            return defaults.bool(forKey: Key.autoSummarize)
        }
        set { defaults.set(newValue, forKey: Key.autoSummarize) }
    }

    /// Preferred microphone uniqueID. `nil` means use system default.
    var preferredMicID: String? {
        get { defaults.string(forKey: Key.preferredMicID) }
        set {
            if let v = newValue {
                defaults.set(v, forKey: Key.preferredMicID)
            } else {
                defaults.removeObject(forKey: Key.preferredMicID)
            }
        }
    }

    /// Auto-record calendar meetings. Opt-in; default off because it's
    /// invasive and requires Calendar permission.
    var autoRecordMeetings: Bool {
        get { defaults.bool(forKey: Key.autoRecordMeetings) }
        set { defaults.set(newValue, forKey: Key.autoRecordMeetings) }
    }
}
