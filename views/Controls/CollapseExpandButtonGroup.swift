import SwiftUI

/// Reusable pair of collapse/expand buttons used across Tasks and Review surfaces.
struct CollapseExpandButtonGroup: View {
  var collapseHelp: String = "Collapse All"
  var expandHelp: String = "Expand All"
  let onCollapse: () -> Void
  let onExpand: () -> Void

  var body: some View {
    HStack(spacing: 0) {
      button(
        systemImage: "arrow.up.right.and.arrow.down.left",
        help: collapseHelp,
        action: onCollapse
      )
      button(
        systemImage: "arrow.down.left.and.arrow.up.right",
        help: expandHelp,
        action: onExpand
      )
    }
  }

  private func button(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .frame(width: 28, height: 28)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(Color.clear)
    )
    .contentShape(Rectangle())
    .help(help)
  }
}
