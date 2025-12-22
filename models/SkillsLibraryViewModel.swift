import Foundation
import UniformTypeIdentifiers

struct SkillSummary: Identifiable, Hashable {
    let id: String
    var name: String
    var summary: String
    var tags: [String]
    var source: String
    var path: String?
    var isSelected: Bool
    var targets: MCPServerTargets

    var displayName: String { name.isEmpty ? id : name }
}

enum SkillInstallMode: String, CaseIterable {
    case folder
    case zip
    case url

    var title: String {
        switch self {
        case .folder: return "Folder"
        case .zip: return "Zip"
        case .url: return "URL"
        }
    }
}

@MainActor
final class SkillsLibraryViewModel: ObservableObject {
    @Published var skills: [SkillSummary] = []
    @Published var selectedSkillId: String?
    @Published var searchText: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    @Published var showInstallSheet: Bool = false
    @Published var installMode: SkillInstallMode = .folder
    @Published var pendingInstallURL: URL?
    @Published var pendingInstallText: String = ""

    var filteredSkills: [SkillSummary] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return skills }
        return skills.filter { skill in
            let hay = [skill.displayName, skill.summary, skill.tags.joined(separator: " "), skill.source]
                .joined(separator: " ")
                .lowercased()
            return hay.contains(trimmed.lowercased())
        }
    }

    var selectedSkill: SkillSummary? {
        guard let id = selectedSkillId else { return nil }
        return skills.first(where: { $0.id == id })
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        // UI-first: real loading will be wired to SkillsStore in the data phase.
        skills = []
        if selectedSkillId == nil {
            selectedSkillId = skills.first?.id
        }
    }

    func prepareInstall(mode: SkillInstallMode, url: URL? = nil, text: String? = nil) {
        installMode = mode
        pendingInstallURL = url
        pendingInstallText = text ?? ""
        showInstallSheet = true
    }

    func cancelInstall() {
        showInstallSheet = false
    }

    func finishInstall() {
        // Placeholder: wiring to installation pipeline comes later.
        showInstallSheet = false
    }

    func updateSkillTarget(id: String, target: MCPServerTarget, value: Bool) {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { return }
        var updated = skills[idx]
        updated.targets.setEnabled(value, for: target)
        skills[idx] = updated
    }

    func updateSkillSelection(id: String, value: Bool) {
        guard let idx = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[idx].isSelected = value
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                Task { @MainActor in
                    let isZip = url.pathExtension.lowercased() == "zip"
                    self.prepareInstall(mode: isZip ? .zip : .folder, url: url)
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    Task { @MainActor in
                        self.prepareInstall(mode: .url, text: url.absoluteString)
                    }
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let text: String?
                if let data = item as? Data {
                    text = String(data: data, encoding: .utf8)
                } else {
                    text = item as? String
                }
                guard let text, !text.isEmpty else { return }
                Task { @MainActor in
                    self.prepareInstall(mode: .url, text: text)
                }
            }
            return true
        }
        return false
    }
}
