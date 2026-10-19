import SwiftUI

/// Fleet config viewer/editor. Edits go through the Fleet CLI (`set`) so validation lives in one place.
struct FleetConfigView: View {
    @ObservedObject private var store = FleetStore.shared

    @State private var editingKey: String?
    @State private var draftValue: String = ""
    @State private var freeformKey = ""
    @State private var freeformValue = ""
    @State private var banner: (text: String, isError: Bool)?
    @State private var showRaw = false
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "fleet config",
                    title: L("Fleet Config"),
                    subtitle: L("Fleet Config subtitle")
                )

                if let banner {
                    MTCard {
                        HStack(spacing: MTTheme.s2) {
                            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(banner.isError ? MTTheme.danger : MTTheme.ok)
                            Text(banner.text)
                                .font(MTTheme.mono(11))
                                .foregroundStyle(MTTheme.textPrimary)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                self.banner = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10))
                                    .foregroundStyle(MTTheme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                entriesCard

                setCard

                if showRaw || store.editableConfigEntries.isEmpty {
                    rawCard
                }
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        .mtScrollMemory("scroll.fleet-config")
        }
        .background(MTTheme.background)
        .onAppear {
            store.start()
            store.refreshAll()
        }
    }

    // MARK: - Entries

    private var entriesCard: some View {
        MTCard(title: L("Keys"), systemImage: "slider.horizontal.3") {
            if store.editableConfigEntries.isEmpty {
                Text(L("No config file yet — built-in defaults are in force. Set a key below to create one."))
                    .font(MTTheme.mono(11))
                    .foregroundStyle(MTTheme.textSecondary)
                    .padding(.vertical, MTTheme.s2)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(store.editableConfigEntries) { entry in
                        entryRow(entry)
                        if entry.id != store.editableConfigEntries.last?.id {
                            Divider().overlay(MTTheme.borderColor.opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: FleetStore.ConfigEntry) -> some View {
        HStack(spacing: MTTheme.s3) {
            Text(entry.key)
                .font(MTTheme.mono(11))
                .foregroundStyle(MTTheme.textSecondary)
                .frame(width: 220, alignment: .leading)

            if editingKey == entry.key {
                TextField(L("value"), text: $draftValue)
                    .textFieldStyle(.roundedBorder)
                    .font(MTTheme.mono(11))
                    .frame(maxWidth: 300)
                MTPrimaryButton(title: L("Set"), isLoading: isSaving) {
                    save(cliKey(for: entry), draftValue)
                }
                MTSecondaryButton(title: L("Cancel")) {
                    editingKey = nil
                }
            } else {
                Text(entry.value)
                    .font(MTTheme.mono(11))
                    .foregroundStyle(MTTheme.textPrimary)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    editingKey = entry.key
                    draftValue = entry.value
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
    }

    /// "units.codex.timeoutS" → "codex.timeoutS"; other paths map 1:1.
    private func cliKey(for entry: FleetStore.ConfigEntry) -> String {
        if entry.key.hasPrefix("units.") {
            return String(entry.key.dropFirst("units.".count))
        }
        return entry.key
    }

    // MARK: - Free-form set

    private var setCard: some View {
        MTCard(title: L("Set any key"), systemImage: "plus.circle") {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                HStack(spacing: MTTheme.s2) {
                    TextField(L("key (e.g. codex.timeoutS)"), text: $freeformKey)
                        .textFieldStyle(.roundedBorder)
                        .font(MTTheme.mono(11))
                        .frame(width: 240)
                    TextField(L("value"), text: $freeformValue)
                        .textFieldStyle(.roundedBorder)
                        .font(MTTheme.mono(11))
                        .frame(width: 180)
                    MTPrimaryButton(title: L("Set"), systemImage: "checkmark", isLoading: isSaving) {
                        guard !freeformKey.isEmpty else { return }
                        save(freeformKey, freeformValue)
                    }
                }
                Text(L("Bare keys: updateCheck, contract · units: <unit>.<key> · agents.<role>.<key> · handoff.enabled · workflow.merge"))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    private func save(_ key: String, _ value: String) {
        isSaving = true
        Task {
            let result = await store.setConfig(key: key, value: value)
            banner = (result.message.isEmpty ? (result.ok ? L("saved") : L("failed")) : result.message, !result.ok)
            isSaving = false
            editingKey = nil
            freeformKey = ""
            freeformValue = ""
        }
    }

    private var rawCard: some View {
        MTCard(title: L("Raw config"), systemImage: "doc.plaintext") {
            Text(store.configRaw.isEmpty ? L("(no config file — defaults in force)") : store.configRaw)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
