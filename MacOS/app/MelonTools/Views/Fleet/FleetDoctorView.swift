import SwiftUI

struct FleetDoctorView: View {
    @ObservedObject private var store = FleetStore.shared
    @State private var showRaw = false
    @State private var probeModels = false
    @State private var probeSandbox = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "fleet doctor",
                    title: L("Doctor"),
                    subtitle: L("Doctor subtitle")
                )

                controls

                if let report = store.doctor {
                    reportView(report)
                } else {
                    MTCard {
                        MTEmptyState(
                            systemImage: "stethoscope",
                            title: store.isDoctorRunning ? L("Running doctor…") : L("No report yet"),
                            subtitle: L("Run the doctor to inspect the fleet install.")
                        )
                        .frame(height: 160)
                    }
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(MTTheme.background)
        .onAppear {
            store.start()
            store.refreshAll()
            if store.doctor == nil { Task { await store.runDoctor() } }
        }
    }

    private var controls: some View {
        HStack(spacing: MTTheme.s3) {
            MTPrimaryButton(title: L("Run doctor"), systemImage: "stethoscope", isLoading: store.isDoctorRunning) {
                Task { await store.runDoctor(probeModels: probeModels, probeSandbox: probeSandbox) }
            }
            Toggle(L("probe models"), isOn: $probeModels)
                .toggleStyle(.checkbox)
                .font(MTTheme.mono(11))
            Toggle(L("probe sandbox"), isOn: $probeSandbox)
                .toggleStyle(.checkbox)
                .font(MTTheme.mono(11))
            Spacer()
            if let version = store.fleetVersion {
                Text(version)
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            Toggle(L("raw output"), isOn: $showRaw)
                .toggleStyle(.checkbox)
                .font(MTTheme.mono(11))
        }
    }

    @ViewBuilder
    private func reportView(_ report: DoctorReport) -> some View {
        if !report.header.isEmpty {
            HStack(spacing: MTTheme.s3) {
                MTStatusPill(text: report.exitCode == 0 ? L("no faults") : L("faults found"),
                             status: report.exitCode == 0 ? .ok : .error)
                Text(sanitized(report.header))
                    .font(MTTheme.mono(11, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                    .textSelection(.enabled)
                Spacer()
            }
        }

        if !report.globals.isEmpty {
            MTCard(title: L("Install")) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(report.globals.enumerated()), id: \.offset) { _, row in
                        MTKeyValueRow(key: row.key, value: sanitized(row.value), status: row.status)
                    }
                }
            }
        }

        ForEach(Array(report.sections.enumerated()), id: \.offset) { _, section in
            MTCard(title: "\(section.displayName)  ·  \(section.unit)", systemImage: "cpu") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                        MTKeyValueRow(key: row.key, value: sanitized(row.value), status: row.status)
                    }
                }
            }
        }

        if let next = report.next, !next.isEmpty {
            MTCard(title: L("Next step"), systemImage: "arrow.right.circle") {
                Text(sanitized(next))
                    .font(MTTheme.mono(11))
                    .foregroundStyle(MTTheme.textPrimary)
                    .textSelection(.enabled)
            }
        }

        if showRaw {
            MTCard(title: L("Raw output")) {
                Text(sanitized(report.rawOutput))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The fleet CLI prints its own name in a few lines; show them as «fleet».
    private func sanitized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "melon-fleet", with: "fleet")
            .replacingOccurrences(of: "fleet-", with: "")
            .replacingOccurrences(of: "fleet_", with: "FLEET_")
    }
}
