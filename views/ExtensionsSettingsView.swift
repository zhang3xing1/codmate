import SwiftUI

struct ExtensionsSettingsView: View {
    @Binding var selectedTab: ExtensionsSettingsTab
    var openMCPMateDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Group {
                if #available(macOS 15.0, *) {
                    TabView(selection: $selectedTab) {
                        Tab("MCP Servers", systemImage: "server.rack", value: ExtensionsSettingsTab.mcp) {
                            SettingsTabContent {
                                MCPServersSettingsPane(openMCPMateDownload: openMCPMateDownload, showHeader: false)
                            }
                        }
                        Tab("Skills", systemImage: "sparkles", value: ExtensionsSettingsTab.skills) {
                            SettingsTabContent { SkillsSettingsView() }
                        }
                    }
                } else {
                    TabView(selection: $selectedTab) {
                        SettingsTabContent {
                            MCPServersSettingsPane(openMCPMateDownload: openMCPMateDownload, showHeader: false)
                        }
                        .tabItem { Label("MCP Servers", systemImage: "server.rack") }
                        .tag(ExtensionsSettingsTab.mcp)

                        SettingsTabContent { SkillsSettingsView() }
                            .tabItem { Label("Skills", systemImage: "sparkles") }
                            .tag(ExtensionsSettingsTab.skills)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Extensions")
                .font(.title2)
                .fontWeight(.bold)
            Text("Manage MCP servers and Skills across Codex and Claude.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
