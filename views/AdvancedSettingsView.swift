import SwiftUI

@available(macOS 15.0, *)
struct AdvancedSettingsView: View {
    @ObservedObject var preferences: SessionPreferencesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Advanced Settings")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Paths, command resolution, and deeper diagnostics.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
            }

            TabView {
                Tab("Path", systemImage: "folder") {
                    SettingsTabContent {
                        AdvancedPathPane(preferences: preferences)
                    }
                }
                Tab("Dialectics", systemImage: "doc.text.magnifyingglass") {
                    SettingsTabContent {
                        DialecticsPane(preferences: preferences)
                    }
                }
            }
            .controlSize(.regular)
            .padding(.bottom, 16)
        }
    }
}
