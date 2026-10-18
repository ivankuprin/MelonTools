import SwiftUI

/// Live view of the fleet status feed: per-unit snapshot + recent log.
struct FleetStatusView: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var store = FleetStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "fleet status",
                    title: L("Fleet Status"),
                    subtitle: L("Fleet status subtitle")
                )

                if store.snapshots.isEmpty {
                    MTCard {
                        MTEmptyState(
                            systemImage: "antenna.radiowaves.left.and.right",
                            title: L("No live units"),
                            subtitle: L("A unit appears here while its MCP server runs a call. Start Claude Code and call a unit.")
                        )
                        .frame(height: 140)
                    }
                } else {
                    unitCards
                }

                logCard
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(MTTheme.background)
        .onAppear { store.start() }
    }

    private var unitCards: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: MTTheme.s3)], spacing: MTTheme.s3) {
            ForEach(store.snapshots) { snap in
                unitCard(snap)
            }
        }
    }

    private func unitCard(_ snap: FleetStatusSnapshot) -> some View {
        MTCard(title: snap.fleetUnit?.displayName ?? snap.unit, systemImage: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                HStack {
                    Spacer()
                    if let updated = snap.updatedAt {
                        Text(ISODate.relative(updated))
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                }

                if let active = snap.active, !active.isEmpty {
                    ForEach(active) { call in
                        HStack(spacing: MTTheme.s2) {
                            MTStatusDot(status: .running)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(call.tool ?? L("Tool"))
                                    .font(MTTheme.mono(11, weight: .semibold))
                                    .foregroundStyle(MTTheme.textPrimary)
                                if let model = call.model {
                                    Text(model)
                                        .font(MTTheme.mono(10))
                                        .foregroundStyle(MTTheme.textSecondary)
                                }
                            }
                            Spacer()
                            Text(ISODate.relative(call.startedAt))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                    }
                } else {
                    Text(L("idle"))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }

                Divider().overlay(MTTheme.borderColor)

                if let last = snap.lastEvent {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: MTTheme.s2) {
                            MTStatusPill(text: last.status ?? "?", status: last.mtStatus)
                            Text(last.tool ?? "")
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textPrimary)
                            Spacer()
                            Text(ISODate.duration(last.durationMs))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                        }
                        HStack(spacing: MTTheme.s3) {
                            if let usage = last.usage {
                                if let input = usage.input {
                                    usageBit("in", input)
                                }
                                if let cached = usage.cachedInput {
                                    usageBit("cached", cached)
                                }
                                if let output = usage.output {
                                    usageBit("out", output)
                                }
                                if let reasoning = usage.reasoning {
                                    usageBit("reason", reasoning)
                                }
                            }
                            Spacer()
                        }
                        if let error = last.error, !error.isEmpty {
                            Text(error)
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.danger)
                                .lineLimit(2)
                        }
                    }
                } else {
                    Text(L("no calls yet"))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
            }
        }
    }

    private func usageBit(_ label: String, _ value: Int) -> some View {
        Text("\(L(label)) \(value)")
            .font(MTTheme.mono(9))
            .foregroundStyle(MTTheme.textSecondary)
    }

    private var logCard: some View {
        MTCard(title: L("Recent activity"), systemImage: "list.bullet.rectangle") {
            if store.recentEvents.isEmpty {
                Text(L("Waiting for fleet events…"))
                    .font(MTTheme.mono(11))
                    .foregroundStyle(MTTheme.textSecondary)
                    .padding(.vertical, MTTheme.s3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.recentEvents.prefix(60)) { event in
                        HStack(spacing: MTTheme.s2) {
                            Text(ISODate.relative(event.ts))
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textSecondary)
                                .frame(width: 74, alignment: .leading)
                            MTStatusDot(status: event.event == "start" ? .running : status(for: event), size: 6)
                            Text(event.unit)
                                .font(MTTheme.mono(10, weight: .semibold))
                                .foregroundStyle(MTTheme.textPrimary)
                                .frame(width: 52, alignment: .leading)
                            Text(event.tool ?? "")
                                .font(MTTheme.mono(10))
                                .foregroundStyle(MTTheme.textPrimary)
                            if event.event == "end", let dur = event.durationMs {
                                Text(ISODate.duration(dur))
                                    .font(MTTheme.mono(9))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func status(for event: FleetLogEvent) -> MTStatus {
        switch event.status {
        case "ok": return .ok
        case "error": return .error
        case "cancelled": return .warn
        default: return .absent
        }
    }
}
