import GlassUI
import ListenKit
import MeetingKit
import SwiftUI
import SynthesisKit

/// A synthesis drawn as what it says: decisions as decisions, tasks as owner, task and
/// date, risks and disagreements marked, every person in their colour.
///
/// The owner read his first analysis as a wall of Markdown and "more or less" worked out
/// what it said (2026-10-08). The model's text is unchanged; `SynthesisDocument` tells
/// this view what each part is, and the view gives each kind its own shape.
struct SynthesisView: View {
    let document: SynthesisDocument
    let palette: MeetingPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let title = document.title {
                Text(palette.inline(title)).font(.system(size: 18, weight: .bold))
            }
            SummaryTiles(document: document)
            ForEach(document.sections) { section in
                SectionCard(section: section, number: topicNumber(of: section), palette: palette)
            }
        }
        .textSelection(.enabled)
    }

    /// Topics are numbered among themselves, as the model numbered them.
    private func topicNumber(of section: SynthesisDocument.Section) -> Int? {
        guard section.kind == .topic, section.title != nil else { return nil }
        let topics = document.sections.filter { $0.kind == .topic && $0.title != nil }
        guard topics.count > 1, let index = topics.firstIndex(where: { $0.id == section.id }) else { return nil }
        return index + 1
    }
}

/// How each kind of section looks.
enum SectionStyle {
    static func icon(_ kind: SynthesisDocument.Kind) -> String {
        switch kind {
        case .decisions: "checkmark.seal.fill"
        case .tasks: "checklist"
        case .risks: "exclamationmark.triangle.fill"
        case .disagreements: "arrow.left.arrow.right"
        case .insight: "lightbulb.fill"
        case .topic: "text.bubble.fill"
        }
    }

    static func color(_ kind: SynthesisDocument.Kind) -> Color {
        switch kind {
        case .decisions: .green
        case .tasks: .blue
        case .risks: .orange
        case .disagreements: .purple
        case .insight: .indigo
        case .topic: .gray
        }
    }

    static func label(_ kind: SynthesisDocument.Kind) -> String {
        switch kind {
        case .decisions: MeetingCopy.t("analysis.kind.decisions")
        case .tasks: MeetingCopy.t("analysis.kind.tasks")
        case .risks: MeetingCopy.t("analysis.kind.risks")
        case .disagreements: MeetingCopy.t("analysis.kind.disagreements")
        case .insight: MeetingCopy.t("analysis.kind.insight")
        case .topic: MeetingCopy.t("analysis.kind.topic")
        }
    }

    static func callout(_ kind: SynthesisDocument.CalloutKind) -> (icon: String, color: Color) {
        switch kind {
        case .decision: ("checkmark.seal.fill", .green)
        case .task: ("checklist", .blue)
        case .risk: ("exclamationmark.triangle.fill", .orange)
        case .disagreement: ("arrow.left.arrow.right", .purple)
        case .context: ("info.circle.fill", .secondary)
        }
    }
}

/// The counts at the top: how many decisions, tasks, risks and disagreements.
private struct SummaryTiles: View {
    let document: SynthesisDocument

    var body: some View {
        let kinds: [SynthesisDocument.Kind] = [.decisions, .tasks, .risks, .disagreements]
        let present = kinds.filter { document.count(of: $0) > 0 }
        if !present.isEmpty {
            // As many per row as fit, so four counters wrap to two rows on a narrow window.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Metrics.Spacing.regular)],
                      spacing: Metrics.Spacing.regular) {
                ForEach(present, id: \.self) { kind in
                    let color = SectionStyle.color(kind)
                    VStack(alignment: .leading, spacing: 4) {
                        Image(systemName: SectionStyle.icon(kind))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(color)
                            .accessibilityHidden(true)
                        Text("\(document.count(of: kind))")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(SectionStyle.label(kind))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(color.opacity(0.1), in: .rect(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.25)) }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct SectionCard: View {
    let section: SynthesisDocument.Section
    let number: Int?
    let palette: MeetingPalette

    var body: some View {
        let color = SectionStyle.color(section.kind)
        VStack(alignment: .leading, spacing: 10) {
            if let title = section.title {
                HStack(spacing: 10) {
                    Group {
                        if let number {
                            Text("\(number)").font(.system(size: 13, weight: .bold, design: .rounded))
                        } else {
                            Image(systemName: SectionStyle.icon(section.kind)).font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(section.kind == .topic ? Color.accentColor : color, in: .rect(cornerRadius: 7))
                    .accessibilityHidden(true)
                    Text(palette.inline(title)).font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 0)
                    if section.kind != .topic, section.itemCount > 0 {
                        Text("\(section.itemCount)")
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(color.opacity(0.15), in: .capsule)
                            .foregroundStyle(color)
                    }
                }
                .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block, kind: section.kind, palette: palette)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
            .overlay(alignment: .leading) {
                if section.kind != .topic {
                    UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                        .fill(color.opacity(0.8))
                        .frame(width: 3)
                }
            }
        }
    }
}

private struct BlockView: View {
    let block: SynthesisDocument.Block
    let kind: SynthesisDocument.Kind
    let palette: MeetingPalette

    var body: some View {
        switch block {
        case .subheading(let text):
            Text(palette.inline(text))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        case .paragraph(let text):
            Text(palette.inline(text)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        case .callout(let calloutKind, let label, let text):
            let style = SectionStyle.callout(calloutKind)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.icon).foregroundStyle(style.color).font(.system(size: 13)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(palette.inline(label)).font(.system(size: 12, weight: .semibold)).foregroundStyle(style.color)
                    Text(palette.inline(text)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.color.opacity(calloutKind == .context ? 0.06 : 0.1), in: .rect(cornerRadius: 10))
        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ListRow(text: item, index: ordered ? index + 1 : nil, kind: kind, palette: palette)
                }
            }
        case .table(let table):
            if let owner = table.ownerColumn, kind == .tasks || table.dateColumn != nil {
                TaskTable(table: table, ownerColumn: owner, palette: palette)
            } else {
                PlainTable(table: table, palette: palette)
            }
        }
    }
}

private struct ListRow: View {
    let text: String
    let index: Int?
    let kind: SynthesisDocument.Kind
    let palette: MeetingPalette

    var body: some View {
        // "Lucía: runbook, miércoles 15." in a task list is an owner and a task.
        if kind == .tasks, let (owner, task) = palette.ownerPrefix(of: text) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PersonChip(entry: owner)
                Text(palette.inline(task)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                marker
                Text(palette.inline(text)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var marker: some View {
        if let index {
            Text("\(index)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(SectionStyle.color(kind))
                .frame(width: 18, height: 18)
                .background(SectionStyle.color(kind).opacity(0.15), in: .circle)
        } else {
            switch kind {
            case .decisions: icon("checkmark.circle.fill")
            case .risks: icon("exclamationmark.circle.fill")
            case .disagreements: icon("arrow.left.arrow.right.circle.fill")
            case .insight: icon("lightbulb.circle.fill")
            case .tasks: icon("circle")
            case .topic:
                Circle().fill(.secondary).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0.height + 1 }
                    .frame(width: 18)
            }
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 13))
            .foregroundStyle(SectionStyle.color(kind))
            .frame(width: 18)
            .accessibilityHidden(true)
    }
}

/// Owner, task, date: the table people act on.
private struct TaskTable: View {
    let table: SynthesisDocument.Table
    let ownerColumn: Int
    let palette: MeetingPalette
    @Environment(\.compactAnalysis) private var compact

    var body: some View {
        let date = table.dateColumn
        let rest = table.header.indices.filter { $0 != ownerColumn && $0 != date }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                Group {
                    if compact {
                        // Narrow: who and when on one line, the task under them.
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                owner(row)
                                Spacer(minLength: 0)
                                if let date { DateBadge(text: cell(row, date)) }
                            }
                            task(row, columns: rest)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            owner(row).frame(width: 140, alignment: .leading)
                            task(row, columns: rest).frame(maxWidth: .infinity, alignment: .leading)
                            if let date { DateBadge(text: cell(row, date)) }
                        }
                    }
                }
                .padding(.vertical, 8)
                if index < table.rows.count - 1 { Divider().opacity(0.5) }
            }
        }
    }

    @ViewBuilder private func owner(_ row: [String]) -> some View {
        let owner = cell(row, ownerColumn)
        if let entry = palette.entry(named: owner) {
            PersonChip(entry: entry)
        } else {
            Text(palette.inline(owner)).font(.system(size: 12, weight: .semibold))
        }
    }

    private func task(_ row: [String], columns: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(columns, id: \.self) { column in
                Text(palette.inline(cell(row, column))).font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func cell(_ row: [String], _ column: Int) -> String { row.indices.contains(column) ? row[column] : "" }
}

/// Any other table, as a grid with its header.
private struct PlainTable: View {
    let table: SynthesisDocument.Table
    let palette: MeetingPalette
    @Environment(\.compactAnalysis) private var compact

    var body: some View {
        if compact { cards } else { grid }
    }

    /// Narrow: one card per row, each value under its column's name.
    private var cards: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(table.header.indices, id: \.self) { column in
                        let value = row.indices.contains(column) ? row[column] : ""
                        if !value.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                if column > 0 {
                                    Text(palette.inline(table.header[column]))
                                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                }
                                Text(palette.inline(value))
                                    .font(.system(size: 13, weight: column == 0 ? .semibold : .regular))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
            }
        }
    }

    private var grid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { _, title in
                    Text(palette.inline(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        Text(palette.inline(row.indices.contains(column) ? row[column] : ""))
                            .font(.system(size: 13, weight: column == 0 ? .semibold : .regular))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: column == 0 ? 180 : .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

/// A person in their colour, with an initial.
struct PersonChip: View {
    let entry: MeetingPalette.Entry

    var body: some View {
        HStack(spacing: 5) {
            Avatar(entry: entry, size: 18)
            Text(entry.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .padding(.leading, 2).padding(.trailing, 8).padding(.vertical, 2)
        .background(entry.color.opacity(0.15), in: .capsule)
        .fixedSize()
    }
}

struct Avatar: View {
    let entry: MeetingPalette.Entry
    let size: CGFloat

    var body: some View {
        Text(entry.initial)
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(entry.color, in: .circle)
            .accessibilityHidden(true)
    }
}

/// A deadline, or the lack of one, which is worth seeing too.
private struct DateBadge: View {
    let text: String

    var body: some View {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let none = text.isEmpty || folded.contains("sin fecha") || folded.contains("no date") || folded == "-"
        Label(none ? MeetingCopy.t("analysis.noDate") : text, systemImage: none ? "calendar.badge.exclamationmark" : "calendar")
            .font(.system(size: 12, weight: .medium))
            .lineLimit(2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((none ? Color.secondary : Color.blue).opacity(0.12), in: .capsule)
            .foregroundStyle(none ? Color.secondary : Color.blue)
            .frame(maxWidth: 190, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Who is who in one meeting, and their colours: shared by the window, the analysis and
/// the history, so a person is the same colour everywhere.
struct MeetingPalette {
    struct Entry: Equatable {
        let label: String
        let name: String
        let color: Color

        var initial: String {
            if label == "me", name == "Yo" { return "Y" }
            return name.first.map { String($0).uppercased() } ?? "?"
        }
    }

    let entries: [Entry]

    init(record: MeetingRecord) {
        entries = record.labels.map { label in
            let segment = TranscriptSegment(channel: label == "me" ? .me : .others, start: 0, end: 0, text: "",
                                            speaker: label == "me" || label == "others" ? nil : label)
            return Entry(label: label, name: record.transcript.label(for: segment), color: SpeakerColors.color(for: label))
        }
    }

    func name(for label: String) -> String { entries.first { $0.label == label }?.name ?? label }

    func entry(for label: String) -> Entry? { entries.first { $0.label == label } }

    /// The person a table cell names: the whole cell, or its first name.
    func entry(named text: String) -> Entry? {
        let key = Self.fold(text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces))
        return entries.first { Self.fold($0.name) == key }
            ?? entries.first { Self.fold($0.name.split(separator: " ").first.map(String.init) ?? "") == key }
    }

    /// "Lucía: runbook" → (Lucía, "runbook").
    func ownerPrefix(of text: String) -> (Entry, String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        guard let entry = entry(named: String(text[..<colon])) else { return nil }
        return (entry, text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    /// Inline Markdown, with every participant's name in bold and in their colour.
    func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for entry in entries where entry.name.count > 1 {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                  let range = attributed[searchStart...].range(of: entry.name) {
                if isWordBoundary(attributed, before: range.lowerBound), isWordBoundary(attributed, after: range.upperBound) {
                    attributed[range].foregroundColor = entry.color
                    attributed[range].inlinePresentationIntent = .stronglyEmphasized
                }
                searchStart = range.upperBound
            }
        }
        return attributed
    }

    private func isWordBoundary(_ text: AttributedString, before index: AttributedString.Index) -> Bool {
        guard index > text.startIndex else { return true }
        return !text.characters[text.characters.index(before: index)].isLetter
    }

    private func isWordBoundary(_ text: AttributedString, after index: AttributedString.Index) -> Bool {
        guard index < text.endIndex else { return true }
        return !text.characters[index].isLetter
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// Stable colours per transcript label.
enum SpeakerColors {
    static func color(for label: String) -> Color {
        if label == "me" { return .cyan }
        let palette: [Color] = [.orange, .purple, .green, .pink, .yellow, .teal, .indigo, .mint]
        let number = Int(label.split(separator: "-").last ?? "") ?? 0
        return palette[(max(number, 1) - 1) % palette.count]
    }
}

/// Wraps chips onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension EnvironmentValues {
    /// The analysis is drawn narrow: tables as cards, rows stacked.
    @Entry var compactAnalysis = false
}
