import Foundation
import AppKit
import AppIntents

// MARK: - Shared helpers

private func recordingsRoot() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Recordings", isDirectory: true)
}

private func mostRecentFile(withExtension ext: String) -> URL? {
    let folder = recordingsRoot()
    let files = (try? FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return files
        .filter { $0.pathExtension == ext && $0.lastPathComponent.hasPrefix("voice-") }
        .sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        .first
}

// MARK: - Intents

@available(macOS 13.0, *)
struct GetLatestTranscriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Transcript"
    static let description = IntentDescription(
        "Returns the text of the most recently transcribed recording."
    )

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let txt = mostRecentFile(withExtension: "txt") else {
            return .result(value: "")
        }
        let content = (try? String(contentsOf: txt, encoding: .utf8)) ?? ""
        return .result(value: content)
    }
}

@available(macOS 13.0, *)
struct GetLatestSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Summary"
    static let description = IntentDescription(
        "Returns the markdown summary of the most recently recorded conversation."
    )

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let folder = recordingsRoot()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let summary = files
            .filter { $0.lastPathComponent.hasSuffix(".summary.md") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .first
        guard let url = summary else { return .result(value: "") }
        return .result(value: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }
}

@available(macOS 13.0, *)
struct ListRecordingsIntent: AppIntent {
    static let title: LocalizedStringResource = "List Recordings"
    static let description = IntentDescription("Returns the filenames of all recordings, newest first.")

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let folder = recordingsRoot()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let names = files
            .filter { $0.pathExtension == "m4a" && $0.lastPathComponent.hasPrefix("voice-") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .map(\.lastPathComponent)
        return .result(value: names)
    }
}

@available(macOS 13.0, *)
struct OpenRecordingsFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Recordings Folder"
    static let description = IntentDescription("Opens ~/Recordings in Finder.")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let folder = recordingsRoot()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
        return .result()
    }
}

// MARK: - Shortcuts registration

@available(macOS 13.0, *)
struct RecorderShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetLatestTranscriptIntent(),
            phrases: [
                "Get my latest \(.applicationName) transcript",
                "What did \(.applicationName) capture",
            ],
            shortTitle: "Latest Transcript",
            systemImageName: "doc.text"
        )
        AppShortcut(
            intent: GetLatestSummaryIntent(),
            phrases: [
                "Summarize my last \(.applicationName) recording",
                "Get my latest \(.applicationName) summary",
            ],
            shortTitle: "Latest Summary",
            systemImageName: "text.badge.checkmark"
        )
        AppShortcut(
            intent: ListRecordingsIntent(),
            phrases: [
                "List my \(.applicationName) recordings",
            ],
            shortTitle: "List Recordings",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: OpenRecordingsFolderIntent(),
            phrases: [
                "Open my \(.applicationName) folder",
            ],
            shortTitle: "Open Folder",
            systemImageName: "folder"
        )
    }
}
