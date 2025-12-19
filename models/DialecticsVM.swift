import Foundation
import SwiftUI
import AppKit

@available(macOS 15.0, *)
@MainActor
final class DialecticsVM: ObservableObject {
    @Published var sessions: SessionsDiagnostics? = nil
    @Published var codexPresent: Bool = false
    @Published var codexVersion: String? = nil
    @Published var claudePresent: Bool = false
    @Published var claudeVersion: String? = nil
    @Published var geminiPresent: Bool = false
    @Published var geminiVersion: String? = nil
    @Published var pathEnv: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    @Published var sandboxOn: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    private let sessionsSvc = SessionsDiagnosticsService()

    func runAll(preferences: SessionPreferencesStore) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defRoot = SessionPreferencesStore.defaultSessionsRoot(for: home)
        let notesDefault = SessionPreferencesStore.defaultNotesRoot(for: defRoot)
        let projectsDefault = SessionPreferencesStore.defaultProjectsRoot(for: home)
        let claudeDefault = home.appendingPathComponent(".claude", isDirectory: true).appendingPathComponent("projects", isDirectory: true)
        let claudeCurrent: URL? = FileManager.default.fileExists(atPath: claudeDefault.path) ? claudeDefault : nil
        let geminiDefault = home.appendingPathComponent(".gemini", isDirectory: true).appendingPathComponent("tmp", isDirectory: true)
        let geminiCurrent: URL? = FileManager.default.fileExists(atPath: geminiDefault.path) ? geminiDefault : nil
        let s = await sessionsSvc.run(
            currentRoot: preferences.sessionsRoot,
            defaultRoot: defRoot,
            notesCurrentRoot: preferences.notesRoot,
            notesDefaultRoot: notesDefault,
            projectsCurrentRoot: preferences.projectsRoot,
            projectsDefaultRoot: projectsDefault,
            claudeCurrentRoot: claudeCurrent,
            claudeDefaultRoot: claudeDefault,
            geminiCurrentRoot: geminiCurrent,
            geminiDefaultRoot: geminiDefault
        )
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        // Prefer a robust PATH in sandboxed mode; shell-derived PATH can be restricted
        var mergedPATH: String
        if sandboxed {
            // Attempt to start access for common binary folders if already authorized dynamically
            let brew = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
            let usrLocal = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
            _ = SecurityScopedBookmarks.shared.startAccessDynamic(for: brew)
            _ = SecurityScopedBookmarks.shared.startAccessDynamic(for: usrLocal)
            mergedPATH = CLIEnvironment.resolvedPATHForCLI(sandboxed: true)
        } else {
            mergedPATH = CLIEnvironment.resolvedPATHForCLI(sandboxed: false)
        }
        let resolved = CLIEnvironment.resolveExecutablePath("codex", path: mergedPATH)
        let resolvedClaude = CLIEnvironment.resolveExecutablePath("claude", path: mergedPATH)
        let resolvedGemini = CLIEnvironment.resolveExecutablePath("gemini", path: mergedPATH)
        self.sessions = s
        self.codexPresent = (resolved != nil)
        self.claudePresent = (resolvedClaude != nil)
        self.geminiPresent = (resolvedGemini != nil)
        self.codexVersion = resolved.flatMap { CLIEnvironment.version(atExecutablePath: $0, path: mergedPATH) }
        self.claudeVersion = resolvedClaude.flatMap { CLIEnvironment.version(atExecutablePath: $0, path: mergedPATH) }
        self.geminiVersion = resolvedGemini.flatMap { CLIEnvironment.version(atExecutablePath: $0, path: mergedPATH) }
        self.pathEnv = mergedPATH
        self.sandboxOn = sandboxed
    }

    var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
    var buildTime: String {
        guard let exe = Bundle.main.executableURL,
            let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
            let date = attrs[.modificationDate] as? Date
        else { return "Unavailable" }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df.string(from: date)
    }
    var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: - Report
    struct CLICommandReport: Codable {
        let detectedPath: String?
        let detectedVersion: String?
        let userOverridePath: String?
        let userOverrideResolvedPath: String?
        let userOverrideVersion: String?
        let resolvedPath: String?
        let resolvedVersion: String?
    }

    struct CLIReport: Codable {
        let pathEnv: String
        let sandboxed: Bool
        let commands: [String: CLICommandReport]
    }

    struct RipgrepReport: Codable {
        let cachedCoverageEntries: Int
        let cachedToolEntries: Int
        let cachedTokenEntries: Int
        let lastCoverageScan: Date?
        let lastToolScan: Date?
        let lastTokenScan: Date?
    }

    struct SessionIndexMetaReport: Codable {
        let lastFullIndexAt: Date?
        let sessionCount: Int
    }

    struct SessionIndexCoverageReport: Codable {
        let sessionCount: Int
        let lastFullIndexAt: Date?
        let sources: [String]
    }

    struct SessionIndexReport: Codable {
        let meta: SessionIndexMetaReport?
        let coverage: SessionIndexCoverageReport?
    }

    struct CacheReport: Codable {
        let sessionIndex: SessionIndexReport?
        let ripgrep: RipgrepReport?
    }

    struct CombinedReport: Codable {
        let timestamp: Date
        let appVersion: String
        let buildTime: String
        let osVersion: String
        let sessions: SessionsDiagnostics?
        let cli: CLIReport
        let caches: CacheReport?
    }

    func saveReport(
        preferences: SessionPreferencesStore,
        ripgrepReport: SessionRipgrepStore.Diagnostics?,
        indexMeta: SessionIndexMeta?,
        cacheCoverage: SessionIndexCoverage?
    ) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        panel.nameFieldStringValue = "CodMate-Diagnostics-\(df.string(from: now)).json"
        panel.beginSheetModal(
            for: NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first!
        ) { resp in
            guard resp == .OK, let url = panel.url else { return }
            let report = self.buildReport(
                preferences: preferences,
                now: now,
                ripgrepReport: ripgrepReport,
                indexMeta: indexMeta,
                cacheCoverage: cacheCoverage
            )
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(report) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    @MainActor private func buildReport(
        preferences: SessionPreferencesStore,
        now: Date,
        ripgrepReport: SessionRipgrepStore.Diagnostics?,
        indexMeta: SessionIndexMeta?,
        cacheCoverage: SessionIndexCoverage?
    ) -> CombinedReport {
        let path = pathEnv

        func trimmedOverridePath(for kind: SessionSource.Kind) -> String? {
            let raw: String
            switch kind {
            case .codex: raw = preferences.codexCommandPath
            case .claude: raw = preferences.claudeCommandPath
            case .gemini: raw = preferences.geminiCommandPath
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        func commandReport(for kind: SessionSource.Kind) -> CLICommandReport {
            let name = kind.cliExecutableName
            let detectedPath = CLIEnvironment.resolveExecutablePath(name, path: path)
            let detectedVersion = detectedPath.flatMap {
                CLIEnvironment.version(atExecutablePath: $0, path: path)
            }
            let userOverridePath = trimmedOverridePath(for: kind)
            let userResolvedPath = preferences.resolvedCommandOverrideURL(for: kind)?.path
            let userVersion = userResolvedPath.flatMap {
                CLIEnvironment.version(atExecutablePath: $0, path: path)
            }
            let resolvedPath = userResolvedPath ?? detectedPath
            let resolvedVersion = userResolvedPath != nil ? userVersion : detectedVersion
            return CLICommandReport(
                detectedPath: detectedPath,
                detectedVersion: detectedVersion,
                userOverridePath: userOverridePath,
                userOverrideResolvedPath: userResolvedPath,
                userOverrideVersion: userVersion,
                resolvedPath: resolvedPath,
                resolvedVersion: resolvedVersion
            )
        }

        let cli = CLIReport(
            pathEnv: path,
            sandboxed: sandboxOn,
            commands: [
                "codex": commandReport(for: .codex),
                "claude": commandReport(for: .claude),
                "gemini": commandReport(for: .gemini),
            ]
        )

        let caches = CacheReport(
            sessionIndex: SessionIndexReport(
                meta: indexMeta.map { SessionIndexMetaReport(lastFullIndexAt: $0.lastFullIndexAt, sessionCount: $0.sessionCount) },
                coverage: cacheCoverage.map {
                    SessionIndexCoverageReport(
                        sessionCount: $0.sessionCount,
                        lastFullIndexAt: $0.lastFullIndexAt,
                        sources: $0.sources.map(\.rawValue)
                    )
                }
            ),
            ripgrep: ripgrepReport.map {
                RipgrepReport(
                    cachedCoverageEntries: $0.cachedCoverageEntries,
                    cachedToolEntries: $0.cachedToolEntries,
                    cachedTokenEntries: $0.cachedTokenEntries,
                    lastCoverageScan: $0.lastCoverageScan,
                    lastToolScan: $0.lastToolScan,
                    lastTokenScan: $0.lastTokenScan
                )
            }
        )

        return CombinedReport(
            timestamp: now,
            appVersion: appVersion,
            buildTime: buildTime,
            osVersion: osVersion,
            sessions: sessions,
            cli: cli,
            caches: caches
        )
    }
}
