import SwiftUI

struct MCPServerTargetToggle: View {
    let provider: UsageProviderKind
    @Binding var isOn: Bool
    var disabled: Bool

    var body: some View {
        Button {
            if !disabled {
                isOn.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                providerIcon
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    @ViewBuilder
    private var providerIcon: some View {
        let active = isOn && !disabled
        ProviderIconView(
            provider: provider,
            size: 14,
            cornerRadius: 3,
            saturation: active ? 1.0 : 0.0,
            opacity: active ? 1.0 : 0.2
        )
    }

    private var helpText: String {
        let name = provider.displayName
        if disabled {
            return "\(name) integration (server disabled)"
        }
        return isOn ? "Disable for \(name)" : "Enable for \(name)"
    }
}
