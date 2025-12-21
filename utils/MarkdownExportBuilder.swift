import Foundation

struct MarkdownExportBuilder {
    static func build(
        session: SessionSummary,
        turns: [ConversationTurn],
        visibleKinds: Set<MessageVisibilityKind>,
        exportURL: URL
    ) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        var lines: [String] = []
        let title = session.effectiveTitle
        lines.append("# \(title)")
        lines.append("")

        // Metadata summary
        let sourceName = session.source.baseKind.displayName
        let remoteSuffix = session.source.remoteHost.map { " (\($0))" } ?? ""
        lines.append("- Source: \(sourceName)\(remoteSuffix)")
        lines.append("- Started: \(df.string(from: session.startedAt))")
        if let end = session.endedAt ?? session.lastUpdatedAt, end != session.startedAt {
            lines.append("- Updated: \(df.string(from: end))")
        }
        if session.duration > 0 {
            lines.append("- Duration: \(session.readableDuration)")
        }
        if let model = session.displayModel ?? session.model, !model.isEmpty {
            lines.append("- Model: \(model)")
        }
        if !session.cwd.isEmpty {
            lines.append("- CWD: \(session.cwd)")
        }
        if let approval = session.approvalPolicy, !approval.isEmpty {
            lines.append("- Approval Policy: \(approval)")
        }
        if let originator = session.originator.nonEmpty {
            lines.append("- Originator: \(originator)")
        }
        lines.append("")

        if let comment = session.userComment?.trimmingCharacters(in: .whitespacesAndNewlines),
           !comment.isEmpty {
            lines.append("## Comment")
            lines.append(comment)
            lines.append("")
        }

        if let instructions = session.instructions?.trimmingCharacters(in: .whitespacesAndNewlines),
           !instructions.isEmpty {
            lines.append("## Task Instructions")
            lines.append(instructions)
            lines.append("")
        }

        lines.append("## Conversation")
        let filteredTurns = turns.filtering(visibleKinds: visibleKinds)
        for turn in filteredTurns {
            let events = turn.allEvents
            for event in events where visibleKinds.contains(event.visibilityKind) {
                lines.append("")
                lines.append(eventHeader(event: event, dateFormatter: df, session: session))
                if let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    lines.append("")
                    lines.append(text)
                }
                if event.repeatCount > 1 {
                    lines.append("")
                    lines.append("_Repeated ×\(event.repeatCount)_")
                }
                if !event.attachments.isEmpty {
                    lines.append("")
                    lines.append("_Attachments: \(attachmentSummary(event.attachments))_")
                }
                if let metadata = event.metadata, !metadata.isEmpty {
                    lines.append("")
                    lines.append("Metadata:")
                    for key in metadata.keys.sorted() {
                        if let value = metadata[key], !value.isEmpty {
                            lines.append("- \(key): \(value)")
                        }
                    }
                }
            }
        }
        lines.append("")
        lines.append("_Exported to \(exportURL.lastPathComponent)_")
        return lines.joined(separator: "\n")
    }

    private static func eventHeader(
        event: TimelineEvent,
        dateFormatter: DateFormatter,
        session: SessionSummary
    ) -> String {
        let role = eventRoleTitle(event: event, session: session)
        let time = dateFormatter.string(from: event.timestamp)
        if let title = event.title,
           !title.isEmpty,
           title != role,
           MessageVisibilityKind.kindFromToken(title) != event.visibilityKind {
            return "### \(role) · \(title) · \(time)"
        }
        return "### \(role) · \(time)"
    }

    private static func eventRoleTitle(event: TimelineEvent, session: SessionSummary) -> String {
        event.visibilityKind.settingsLabel
    }

    private static func attachmentSummary(_ attachments: [TimelineAttachment]) -> String {
        let imageCount = attachments.filter { $0.kind == .image }.count
        if imageCount > 0 {
            return "\(imageCount) image" + (imageCount == 1 ? "" : "s")
        }
        return "\(attachments.count) attachment" + (attachments.count == 1 ? "" : "s")
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
