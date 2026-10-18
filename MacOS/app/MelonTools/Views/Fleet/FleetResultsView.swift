import AppKit
import SwiftUI

/// Fleet results: everything the units produced, newest first.
struct FleetResultsView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var store = FleetStore.shared
    @State private var unitFilter: FleetUnit? = nil
    @State private var selected: FleetResultFile?
    @State private var selectedBody: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                MTPageHeader(
                    kicker: "fleet results",
                    title: L("Results"),
                    subtitle: L("Results subtitle")
                )
                HStack(spacing: MTTheme.s3) {
                    filterPill(nil, label: L("All"))
                    ForEach(FleetUnit.allCases) { unit in
                        filterPill(unit, label: unit.displayName)
                    }
                    Spacer()
                    MTSecondaryButton(title: L("Refresh"), systemImage: "arrow.clockwise") {
                        Task { await store.refreshResults() }
                    }
                }
            }
            .padding(MTTheme.s5)
            .padding(.bottom, 0)

            HStack(alignment: .top, spacing: 0) {
                resultList
                    .frame(width: 420)
                Divider().overlay(MTTheme.borderColor)
                detailPane
                    .frame(maxWidth: .infinity)
            }
        }
        .background(MTTheme.background)
        .onAppear {
            store.start()
            store.refreshAll()
        }
    }

    private func filterPill(_ unit: FleetUnit?, label: String) -> some View {
        Button {
            unitFilter = unit
        } label: {
            Text(label)
                .font(MTTheme.mono(11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(unitFilter == unit ? AnyShapeStyle(MTTheme.gold) : AnyShapeStyle(MTTheme.cardSoft))
                .foregroundStyle(unitFilter == unit ? MTTheme.onGold : MTTheme.textPrimary)
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(unitFilter == unit ? .clear : MTTheme.borderColor, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var filtered: [FleetResultFile] {
        guard let unitFilter else { return store.results }
        return store.results.filter { $0.unit == unitFilter.rawValue }
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if filtered.isEmpty {
                    MTEmptyState(
                        systemImage: "tray",
                        title: L("No results yet"),
                        subtitle: L("Results appear after a unit call completes.")
                    )
                    .frame(height: 200)
                }
                ForEach(filtered) { item in
                    resultRow(item)
                    Divider().overlay(MTTheme.borderColor.opacity(0.5))
                }
            }
            .padding(.vertical, MTTheme.s2)
        }
    }

    private func resultRow(_ item: FleetResultFile) -> some View {
        Button {
            selected = item
            selectedBody = store.loadResultBody(item)
        } label: {
            HStack(alignment: .top, spacing: MTTheme.s2) {
                MTStatusDot(status: item.mtStatus, size: 7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: MTTheme.s2) {
                        Text(item.unit)
                            .font(MTTheme.mono(10, weight: .semibold))
                            .foregroundStyle(MTTheme.textPrimary)
                        Text(item.tool ?? "")
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                        Spacer()
                        Text(ISODate.duration(item.durationMs))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                    if let preview = item.promptPreview, !preview.isEmpty {
                        Text(preview)
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Text(ISODate.relative(item.endedAt))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textSecondary.opacity(0.8))
                }
            }
            .padding(.horizontal, MTTheme.s3)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected?.id == item.id ? MTTheme.gold.opacity(0.15) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var detailPane: some View {
        ScrollView {
            if let selected {
                VStack(alignment: .leading, spacing: MTTheme.s3) {
                    HStack(spacing: MTTheme.s2) {
                        MTStatusPill(text: selected.status ?? "?", status: selected.mtStatus)
                        Text(selected.resultId)
                            .font(MTTheme.mono(11, weight: .semibold))
                            .foregroundStyle(MTTheme.textPrimary)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(selectedBody, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Copy full result"))
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        if let model = selected.model { MTKeyValueRow(key: "model", value: model) }
                        if let usage = selected.usageLine { MTKeyValueRow(key: "usage", value: usage) }
                        MTKeyValueRow(key: "started", value: selected.startedAt ?? "—")
                        MTKeyValueRow(key: "ended", value: selected.endedAt ?? "—")
                        if selected.partial == true { MTKeyValueRow(key: "partial", value: "true", status: .warn) }
                        if selected.detached == true { MTKeyValueRow(key: "detached", value: "true", status: .warn) }
                    }

                    Divider().overlay(MTTheme.borderColor)

                    let body = stripHeader(selectedBody)
                    Text(body.isEmpty ? L("(empty body)") : body)
                        .font(MTTheme.mono(11))
                        .foregroundStyle(MTTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(MTTheme.s4)
            } else {
                MTEmptyState(
                    systemImage: "doc.text.magnifyingglass",
                    title: L("Select a result"),
                    subtitle: L("The full answer is shown here.")
                )
            }
        }
    }

    private func stripHeader(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---" else { return text }
        var endIndex: Int? = nil
        for (i, line) in lines.enumerated() where i > 0 && line == "---" {
            endIndex = i
            break
        }
        guard let endIndex else { return text }
        lines.removeSubrange(0...endIndex)
        return lines.joined(separator: "\n")
    }
}
