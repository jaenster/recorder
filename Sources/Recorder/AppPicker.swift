import Foundation
import AppKit
import ScreenCaptureKit

/// One row the user can pick. Represents a "logical" app (Slack, Chrome, …)
/// and the list of `SCRunningApplication`s whose audio should be captured
/// for it — typically the main app plus its helper renderers.
struct AppPickEntry {
    let displayName: String
    let bundleIdentifier: String
    let icon: NSImage?
    let apps: [SCRunningApplication]
}

enum AppPickerMode {
    case inCall      // only apps currently using mic
    case audible     // apps currently producing audio
    case all         // everything
}

enum AppPicker {
    static func currentEntries(mode: AppPickerMode = .inCall) async throws -> [AppPickEntry] {
        let content = try await SCShareableContent.current
        let apps = content.applications

        var groups: [String: [SCRunningApplication]] = [:]
        for app in apps {
            let key = canonicalBundle(app.bundleIdentifier)
            groups[key, default: []].append(app)
        }

        let pidFilter: Set<pid_t>?
        switch mode {
        case .inCall:
            pidFilter = AudioProcessInspector.pidsUsingMicrophone()
        case .audible:
            pidFilter = AudioProcessInspector.pidsProducingAudio()
        case .all:
            pidFilter = nil
        }

        var entries: [AppPickEntry] = []
        for (canon, group) in groups {
            if let pidFilter,
               !group.contains(where: { pidFilter.contains(pid_t($0.processID)) }) {
                continue
            }
            let main = group.first(where: { $0.bundleIdentifier == canon }) ?? group.first!
            let name = displayName(for: canon, fallback: main.applicationName)
            let icon = NSRunningApplication.runningApplications(withBundleIdentifier: canon).first?.icon
            entries.append(AppPickEntry(
                displayName: name,
                bundleIdentifier: canon,
                icon: icon,
                apps: group
            ))
        }
        // Filter out self + things that obviously won't produce audio (Finder, Dock helpers).
        let blocked: Set<String> = [
            "info.stoots.recorder",
            "com.apple.dock",
            "com.apple.WindowManager",
            "com.apple.controlcenter",
            "com.apple.systemuiserver",
        ]
        entries.removeAll { blocked.contains($0.bundleIdentifier) }
        entries.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        return entries
    }

    /// Map a helper bundle id like `com.google.Chrome.helper.Renderer` back
    /// to the canonical app id `com.google.Chrome`.
    private static func canonicalBundle(_ id: String) -> String {
        let lower = id.lowercased()
        let suffixes = [
            ".helper.renderer", ".helper.gpu", ".helper.plugin", ".helper",
            ".renderer", ".gpu",
        ]
        for sfx in suffixes {
            if lower.hasSuffix(sfx) {
                return String(id.dropLast(sfx.count))
            }
        }
        return id
    }

    private static func displayName(for bundle: String, fallback: String) -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle),
           let bundleObj = Bundle(url: appURL),
           let name = bundleObj.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                   ?? bundleObj.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return fallback
    }
}
