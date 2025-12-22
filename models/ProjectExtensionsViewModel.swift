import Foundation

struct ProjectMCPSelection: Identifiable, Hashable {
    var id: String { server.name }
    var server: MCPServer
    var isSelected: Bool
    var targets: MCPServerTargets
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: ProjectMCPSelection, rhs: ProjectMCPSelection) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class ProjectExtensionsViewModel: ObservableObject {
    @Published var skills: [SkillSummary] = []
    @Published var mcpSelections: [ProjectMCPSelection] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    func load(projectDirectory: String) async {
        isLoading = true
        defer { isLoading = false }

        // Skills will be wired to the global Skills store later.
        skills = []

        let store = MCPServersStore()
        let servers = await store.list()
        mcpSelections = servers.map { server in
            let targets = server.targets ?? MCPServerTargets(codex: true, claude: true, gemini: false)
            return ProjectMCPSelection(server: server, isSelected: false, targets: targets)
        }
    }

    func updateMCPSelection(id: String, isSelected: Bool) {
        guard let idx = mcpSelections.firstIndex(where: { $0.id == id }) else { return }
        mcpSelections[idx].isSelected = isSelected
    }

    func updateMCPTarget(id: String, target: MCPServerTarget, value: Bool) {
        guard let idx = mcpSelections.firstIndex(where: { $0.id == id }) else { return }
        mcpSelections[idx].targets.setEnabled(value, for: target)
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
}
