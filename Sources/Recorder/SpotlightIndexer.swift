import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

enum SpotlightIndexer {
    private static let domain = "info.stoots.recorder"

    /// Index every transcript and summary found in ~/Recordings/. Run at
    /// launch so files made while the app wasn't running still become
    /// searchable.
    static func indexExisting() {
        let folder = recordingsFolderURL()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return }
        let candidates = entries.filter {
            ($0.pathExtension == "txt" || $0.lastPathComponent.hasSuffix(".summary.md")) &&
            $0.lastPathComponent.hasPrefix("voice-")
        }
        let items = candidates.compactMap { makeItem(for: $0) }
        if items.isEmpty { return }
        CSSearchableIndex.default().indexSearchableItems(items) { error in
            if let error { NSLog("Spotlight bulk index error: \(error)") }
        }
    }

    /// Index a single new transcript or summary file.
    static func index(url: URL) {
        guard let item = makeItem(for: url) else { return }
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error { NSLog("Spotlight index error for \(url.lastPathComponent): \(error)") }
        }
    }

    private static func makeItem(for url: URL) -> CSSearchableItem? {
        guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let contentType: UTType = url.lastPathComponent.hasSuffix(".summary.md")
            ? (UTType("net.daringfireball.markdown") ?? .plainText)
            : .plainText
        let attrs = CSSearchableItemAttributeSet(contentType: contentType)
        attrs.title = friendlyTitle(for: url)
        attrs.displayName = url.lastPathComponent
        attrs.contentDescription = String(body.prefix(200))
        attrs.textContent = body
        attrs.contentURL = url
        attrs.kind = "Meeting transcript"
        attrs.keywords = ["recorder", "meeting", "transcript"]
        return CSSearchableItem(uniqueIdentifier: url.path,
                                domainIdentifier: domain,
                                attributeSet: attrs)
    }

    /// Strip the voice-YYYY-MM-DD-HHmmss prefix when there's a meeting-title
    /// suffix; otherwise fall back to the filename.
    private static func friendlyTitle(for url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".summary") {
            name = String(name.dropLast(".summary".count))
        }
        // voice-2026-05-18-150412-team-standup → team-standup
        let parts = name.components(separatedBy: "-")
        if parts.count > 5, parts[0] == "voice" {
            return parts.dropFirst(5).joined(separator: " ").replacingOccurrences(of: "_", with: " ")
        }
        return url.lastPathComponent
    }
}
