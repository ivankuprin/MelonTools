import SwiftUI
import AppKit

/// Codex CLI multi-instances: isolated CODEX_HOME per instance, bound to an account.
struct CodexInstancesView: View {
    @ObservedObject private var store = CodexStore.shared
    @ObservedObject private var instances = CodexInstanceStore.shared
    @State private var showCreate = false
    @State private var newName = ""
    @State private var newAccountId: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "codex",
                    title: L("Instances"),
                    subtitle: L("Instances subtitle")
                )

                HStack(spacing: MTTheme.s3) {
                    MTPrimaryButton(title: L("New instance"), systemImage: "plus") {
                        showCreate = true
                    }
                    Spacer()
                    if let message = instances.lastMessage {
                        Text(message)
                            .font(MTTheme.mono(10))
                            .foregroundStyle(MTTheme.textSecondary)
                            .lineLimit(1)
                    }
                }

                if instances.instances.isEmpty {
                    MTCard {
                        MTEmptyState(
                            systemImage: "square.on.square",
                            title: L("No instances"),
                            subtitle: L("Create an instance to run a Codex CLI session under a specific account.")
                        )
                        .frame(height: 160)
                    }
                } else {
                    ForEach(instances.instances) { instance in
                        instanceRow(instance)
                    }
                }

                Text(L("An instance keeps its own login, settings and history. Launch opens it in Terminal."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(MTTheme.background)
        .onAppear {
            store.load()
            instances.load()
        }
        .sheet(isPresented: $showCreate) {
            createSheet
        }
    }

    private func instanceRow(_ instance: CodexInstance) -> some View {
        MTCard {
            HStack(spacing: MTTheme.s3) {
                MTStatusDot(status: instance.accountId == store.currentAccountId ? .ok : .idle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.name)
                        .font(MTTheme.body(13, weight: .semibold))
                        .foregroundStyle(MTTheme.textPrimary)
                    Text(accountLabel(instance.accountId))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                Spacer()
                MTSecondaryButton(title: L("Launch"), systemImage: "play.fill") {
                    instances.launch(instance, accounts: store.accounts)
                }
                MTSecondaryButton(title: L("Reveal"), systemImage: "folder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: instance.homePath)
                }
                Button {
                    instances.delete(instance)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(L("Delete"))
            }
        }
    }

    private func accountLabel(_ accountId: String?) -> String {
        guard let accountId, let account = store.accounts.first(where: { $0.id == accountId }) else {
            return L("Follow current account")
        }
        return account.displayName
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: MTTheme.s4) {
            Text(L("New instance"))
                .font(MTTheme.display(20))
                .foregroundStyle(MTTheme.textPrimary)
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                Text(L("name"))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                TextField(L("e.g. work"), text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(MTTheme.mono(11))
                Text(L("account"))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
                Picker("", selection: $newAccountId) {
                    Text(L("Follow current account")).tag(String?.none)
                    ForEach(store.accounts) { account in
                        Text(account.displayName).tag(String?.some(account.id))
                    }
                }
                .labelsHidden()
            }
            HStack {
                Spacer()
                MTSecondaryButton(title: L("Cancel")) { showCreate = false }
                MTPrimaryButton(title: L("Create"), systemImage: "checkmark") {
                    if instances.create(name: newName, accountId: newAccountId, accounts: store.accounts) {
                        showCreate = false
                        newName = ""
                        newAccountId = nil
                    }
                }
            }
        }
        .padding(MTTheme.s5)
        .frame(width: 460)
        .background(MTTheme.background)
    }
}

// MARK: - Instance model + store

/// Non-isolated path namespace (usable from any context).
enum CodexInstancePaths {
    static var instancesDir: URL {
        let dir = CodexStore.supportDir.appendingPathComponent("instances", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

struct CodexInstance: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var accountId: String?
    var createdAt: Date = Date()

    var homePath: String {
        CodexInstancePaths.instancesDir
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("codex-home", isDirectory: true)
            .path
    }
}

@MainActor
final class CodexInstanceStore: ObservableObject {
    static let shared = CodexInstanceStore()

    @Published private(set) var instances: [CodexInstance] = []
    @Published var lastMessage: String?

    static var instancesDir: URL { CodexInstancePaths.instancesDir }

    private var filePath: String { CodexStore.supportDir.appendingPathComponent("instances.json").path }

    func load() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
           let list = try? JSONDecoder().decode([CodexInstance].self, from: data) {
            instances = list
        }
    }

    private func save() {
        if let data = try? JSONEncoder.pretty.encode(instances) {
            try? data.write(to: URL(fileURLWithPath: filePath), options: [.atomic])
        }
    }

    @discardableResult
    func create(name: String, accountId: String?, accounts: [CodexAccount]) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            lastMessage = L("Name is required")
            return false
        }
        guard !instances.contains(where: { $0.name == clean }) else {
            lastMessage = String(format: L("Instance '%@' already exists"), clean)
            return false
        }
        let instance = CodexInstance(name: clean, accountId: accountId)
        do {
            try FileManager.default.createDirectory(atPath: instance.homePath, withIntermediateDirectories: true)
            try writeAuth(for: instance, accounts: accounts)
        } catch {
            lastMessage = L("Create failed") + ": \(error.localizedDescription)"
            return false
        }
        instances.append(instance)
        save()
        lastMessage = String(format: L("Created '%@'"), clean)
        return true
    }

    func delete(_ instance: CodexInstance) {
        instances.removeAll { $0.id == instance.id }
        save()
        try? FileManager.default.removeItem(atPath: instance.homePath)
        lastMessage = String(format: L("Removed '%@'"), instance.name)
    }

    /// Write the bound (or current) account's tokens into the instance auth.json.
    private func writeAuth(for instance: CodexInstance, accounts: [CodexAccount]) throws {
        let account: CodexAccount? = {
            if let bound = instance.accountId { return accounts.first { $0.id == bound } }
            let path = (NSString(string: "~/.codex").expandingTildeInPath as NSString).appendingPathComponent("auth.json")
            guard let auth = try? CodexAuthFile.load(from: path), let tokens = auth.tokens else { return nil }
            return CodexAccount(tokens: tokens)
        }()
        guard let account else { return }
        let auth = CodexAuthFile.make(from: account)
        let data = try auth.encoded()
        let authPath = (instance.homePath as NSString).appendingPathComponent("auth.json")
        try data.write(to: URL(fileURLWithPath: authPath), options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authPath)
    }

    /// Launch `codex` in Terminal with CODEX_HOME pointed at the instance dir.
    func launch(_ instance: CodexInstance, accounts: [CodexAccount]) {
        do {
            try writeAuth(for: instance, accounts: accounts)
        } catch {
            lastMessage = L("auth sync failed") + ": \(error.localizedDescription)"
        }
        let codexBin = ShellService.which("codex") ?? "codex"
        let script = "export CODEX_HOME=\(TerminalLauncher.shellQuote(instance.homePath))\ncd ~\n\(TerminalLauncher.shellQuote(codexBin))"
        if let error = TerminalLauncher.run(script) {
            lastMessage = L("Launch failed") + ": \(error)"
        } else {
            lastMessage = String(format: L("Launched '%@'"), instance.name)
        }
    }
}
