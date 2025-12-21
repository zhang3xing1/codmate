import AppKit
import SwiftUI

private let timelineTimeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm:ss"
  return formatter
}()

struct ConversationTimelineView: View {
  let turns: [ConversationTurn]
  @Binding var expandedTurnIDs: Set<String>
  var ascending: Bool = false
  var branding: SessionSourceBranding = SessionSource.codexLocal.branding
  var allowManualToggle: Bool = true
  var autoExpandVisible: Bool = false
  var nowModeEnabled: Bool = false
  var onNowModeChange: ((Bool) -> Void)? = nil
  @State private var scrollView: NSScrollView?
  @State private var scrollObserver: NSObjectProtocol?
  @State private var suppressNowModeCallback = false

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        // ScrollViewAccessor to get NSScrollView reference
        ScrollViewAccessor { sv in
          attachScrollView(sv)
        }
        .frame(width: 0, height: 0)

        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
          let pos = ascending ? (index + 1) : (turns.count - index)
          ConversationTurnRow(
            turn: turn,
            position: pos,
            isFirst: index == turns.startIndex,
            isLast: index == turns.count - 1,
            isExpanded: expandedTurnIDs.contains(turn.id),
            branding: branding,
            allowToggle: allowManualToggle,
            autoExpandVisible: autoExpandVisible,
            toggleExpanded: { toggle(turn) }
          )
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .onChange(of: turns.map(\.id)) { _, _ in
      // Auto-scroll to bottom when Now mode is enabled and content changes
      if nowModeEnabled {
        scrollToBottom()
      }
    }
    .onChange(of: nowModeEnabled) { _, isEnabled in
      // Scroll to bottom when user explicitly enables Now mode
      if isEnabled {
        scrollToBottom()
      }
    }
    .onDisappear {
      if let observer = scrollObserver {
        NotificationCenter.default.removeObserver(observer)
      }
    }
  }

  private func attachScrollView(_ sv: NSScrollView) {
    guard scrollView !== sv else { return }
    scrollView = sv

    if let existing = scrollObserver {
      NotificationCenter.default.removeObserver(existing)
    }

    scrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: sv.contentView,
      queue: .main
    ) { [weak sv] _ in
      guard sv != nil else { return }
      Task { @MainActor in
        self.didScroll()
      }
    }

    // Initialize Now mode state based on initial scroll position
    DispatchQueue.main.async {
      self.didScroll()
    }
  }

  @MainActor
  private func didScroll() {
    guard let scrollView else { return }
    if suppressNowModeCallback { return }

    let offsetY = scrollView.contentView.bounds.origin.y
    let viewportHeight = scrollView.contentView.bounds.height
    let contentHeight = scrollView.documentView?.bounds.height ?? 0
    let maxOffset = max(0, contentHeight - viewportHeight)
    let isAtBottom = abs(offsetY - maxOffset) < 10  // 10pt threshold

    if isAtBottom != nowModeEnabled {
      onNowModeChange?(isAtBottom)
    }
  }

  private func scrollToBottom() {
    guard let scrollView else { return }
    let viewport = scrollView.contentView.bounds.height
    let contentHeight = scrollView.documentView?.bounds.height ?? 0
    let maxOffset = max(0, contentHeight - viewport)

    suppressNowModeCallback = true
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxOffset))
    scrollView.reflectScrolledClipView(scrollView.contentView)

    DispatchQueue.main.async {
      self.suppressNowModeCallback = false
    }
  }

  private func toggle(_ turn: ConversationTurn) {
    guard allowManualToggle else { return }
    if expandedTurnIDs.contains(turn.id) {
      expandedTurnIDs.remove(turn.id)
    } else {
      expandedTurnIDs.insert(turn.id)
    }
  }
}

// ScrollViewAccessor to get the underlying NSScrollView
private struct ScrollViewAccessor: NSViewRepresentable {
  let onScrollViewAvailable: (NSScrollView) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      if let scrollView = view.enclosingScrollView {
        onScrollViewAvailable(scrollView)
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct ConversationTurnRow: View {
  let turn: ConversationTurn
  let position: Int
  let isFirst: Bool
  let isLast: Bool
  let isExpanded: Bool
  let branding: SessionSourceBranding
  let allowToggle: Bool
  let autoExpandVisible: Bool
  let toggleExpanded: () -> Void
  @State private var isVisible = false

  var body: some View {
    let expanded = autoExpandVisible ? isVisible : isExpanded
    HStack(alignment: .top, spacing: 8) {
      TimelineMarker(
        position: position,
        timeText: timelineTimeFormatter.string(from: turn.timestamp),
        isFirst: isFirst,
        isLast: isLast
      )

      ConversationCard(
        turn: turn,
        isExpanded: expanded,
        branding: branding,
        allowToggle: allowToggle,
        toggle: toggleExpanded
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear {
      if autoExpandVisible {
        isVisible = true
      }
    }
    .onDisappear {
      if autoExpandVisible {
        isVisible = false
      }
    }
    .onChange(of: autoExpandVisible) { _, newValue in
      if !newValue {
        isVisible = false
      }
    }
  }
}

private struct TimelineMarker: View {
  let position: Int
  let timeText: String
  let isFirst: Bool
  let isLast: Bool

  var body: some View {
    VStack(alignment: .center, spacing: 6) {
      Text(String(position))
        .font(.caption.bold())
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
          Capsule()
            .fill(Color.accentColor)
        )

      Text(timeText)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Color.accentColor)

      VStack(spacing: 0) {
        Rectangle()
          .fill(Color.secondary.opacity(isFirst ? 0 : 0.25))
          .frame(width: 2)
          .frame(height: isFirst ? 0 : 12)

        RoundedRectangle(cornerRadius: 1.5)
          .fill(Color.accentColor)
          .frame(width: 3, height: 12)

        Rectangle()
          .fill(Color.secondary.opacity(isLast ? 0 : 0.25))
          .frame(width: 2)
          .frame(maxHeight: .infinity)
      }
    }
    .frame(width: 72, alignment: .top)
  }
}

private struct ConversationCard: View {
  let turn: ConversationTurn
  let isExpanded: Bool
  let branding: SessionSourceBranding
  let allowToggle: Bool
  let toggle: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      if isExpanded {
        expandedBody
      } else {
        collapsedBody
      }
    }
    .padding(16)
    .background(
      UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 14,
        bottomTrailingRadius: 14,
        topTrailingRadius: 14
      )
      .fill(Color(nsColor: .controlBackgroundColor))
    )
    .overlay(
      UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 14,
        bottomTrailingRadius: 14,
        topTrailingRadius: 14
      )
      .stroke(Color.primary.opacity(0.07), lineWidth: 1)
    )
  }

  private var header: some View {
    HStack {
      Text(turn.actorSummary(using: branding.displayName))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
      Spacer()
      if allowToggle {
        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if allowToggle {
        toggle()
      }
    }
    .hoverHand()
  }

  @ViewBuilder
  private var collapsedBody: some View {
    if let preview = turn.previewText, !preview.isEmpty {
      Text(preview)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      Text("Tap to view details")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private var expandedBody: some View {
    if let user = turn.userMessage {
      EventSegmentView(event: user, branding: branding)
    }

    ForEach(Array(turn.outputs.enumerated()), id: \.offset) { index, event in
      if index > 0 || turn.userMessage != nil {
        Divider()
      }
      EventSegmentView(event: event, branding: branding)
    }
  }
}

private struct EventSegmentView: View {
  let event: TimelineEvent
  let branding: SessionSourceBranding
  @State private var isHover = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        roleIconView
          .foregroundStyle(roleColor)

        Text(roleTitle)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)

        if event.repeatCount > 1 {
          Text("×\(event.repeatCount)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
              Capsule()
                .fill(Color.secondary.opacity(0.1))
            )
        }

        Spacer()

        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(event.text ?? "", forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isHover ? 1 : 0)
        .help("Copy to clipboard")
      }

      if let text = event.text, !text.isEmpty {
        // User messages and tool_output use collapsible text
        if event.visibilityKind == .user {
          CollapsibleText(text: text, lineLimit: 10)
        } else if event.actor == .tool {
          CollapsibleText(text: text, lineLimit: 3)
        } else {
          Text(text)
            .textSelection(.enabled)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      if let metadata = event.metadata {
        MetadataView(metadata: metadata)
      }
    }
    .onHover { hovering in
      isHover = hovering
    }
  }

  private var roleTitle: String {
    event.visibilityKind.settingsLabel
  }

  @ViewBuilder
  private var roleIconView: some View {
    switch event.visibilityKind {
    case .assistant:
      ProviderIconView(provider: branding.providerKind, size: 12, cornerRadius: 2)
    default:
      Image(systemName: roleIconName)
        .font(.caption2)
    }
  }

  private var roleIconName: String {
    switch event.visibilityKind {
    case .user: return "person.fill"
    case .assistant: return branding.symbolName
    case .tool: return "hammer.fill"
    case .codeEdit: return "square.and.pencil"
    case .reasoning: return "brain"
    case .tokenUsage: return "gauge"
    case .environmentContext: return "macwindow"
    case .turnContext: return "arrow.triangle.2.circlepath"
    case .infoOther: return "info.circle"
    }
  }

  private var roleColor: Color {
    switch event.visibilityKind {
    case .user: return .accentColor
    case .assistant: return branding.iconColor
    case .tool: return .yellow
    case .codeEdit: return .green
    case .reasoning: return .purple
    case .tokenUsage: return .orange
    case .environmentContext, .turnContext, .infoOther:
      return .gray
    }
  }
}

private struct CollapsibleText: View {
  let text: String
  let lineLimit: Int
  @State private var isExpanded = false

  var body: some View {
    let previewInfo = linePreview(text, limit: lineLimit)
    let preview = previewInfo.text
    let truncated = previewInfo.truncated
    VStack(alignment: .leading, spacing: 6) {
      Text(isExpanded ? text : preview)
        .textSelection(.enabled)
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)

      if truncated {
        Button(action: { isExpanded.toggle() }) {
          Image(systemName: "ellipsis")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(4)  // Add padding to increase tap area
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())  // Make entire button area tappable
        .hoverHand()
      }
    }
  }

  private func linePreview(_ text: String, limit: Int) -> (text: String, truncated: Bool) {
    // limit = 0 means no truncation, show all
    guard limit > 0 else { return (text, false) }
    var newlineCount = 0
    for index in text.indices {
      if text[index] == "\n" {
        newlineCount += 1
        if newlineCount == limit {
          return (String(text[..<index]), true)
        }
      }
    }
    return (text, false)
  }
}

private struct MetadataView: View {
  let metadata: [String: String]
  private let keyColumnWidth: CGFloat = 240

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(metadata.keys.sorted(), id: \.self) { key in
        if let value = metadata[key], !value.isEmpty {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(width: keyColumnWidth, alignment: .trailing)
            Text(value)
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
          }
        }
      }
    }
    .padding(.top, 4)
  }
}

#Preview {
  ConversationTimelinePreview()
}

private struct ConversationTimelinePreview: View {
  @State private var expanded: Set<String> = []

  private var sampleTurn: ConversationTurn {
    let now = Date()
    let userEvent = TimelineEvent(
      id: UUID().uuidString,
      timestamp: now,
      actor: .user,
      title: nil,
      text: "Please outline a multi-tenant design for the MCP Mate project.",
      metadata: nil,
      repeatCount: 1,
      attachments: [],
      visibilityKind: .user
    )
    let infoEvent = TimelineEvent(
      id: UUID().uuidString,
      timestamp: now.addingTimeInterval(6),
      actor: .info,
      title: "Context Updated",
      text: "model: gpt-5.2-codex\npolicy: on-request",
      metadata: nil,
      repeatCount: 3,
      attachments: [],
      visibilityKind: .turnContext
    )
    let assistantEvent = TimelineEvent(
      id: UUID().uuidString,
      timestamp: now.addingTimeInterval(12),
      actor: .assistant,
      title: nil,
      text: "Certainly. Here are the key considerations for a multi-tenant design...",
      metadata: nil,
      repeatCount: 1,
      attachments: [],
      visibilityKind: .assistant
    )
    return ConversationTurn(
      id: UUID().uuidString,
      timestamp: now,
      userMessage: userEvent,
      outputs: [infoEvent, assistantEvent]
    )
  }

  var body: some View {
    ConversationTimelineView(
      turns: [sampleTurn],
      expandedTurnIDs: $expanded,
      branding: SessionSource.codexLocal.branding
    )
    .padding()
    .frame(width: 540)
  }
}

// Provide a handy pointer extension to keep cursor behavior consistent on clickable areas
extension View {
  func hoverHand() -> some View {
    self.onHover { inside in
      if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }
  }
}
