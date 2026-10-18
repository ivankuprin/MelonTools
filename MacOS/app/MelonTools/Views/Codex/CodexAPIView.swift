import AppKit
import SwiftUI

/// Codex API: local OpenAI-compatible gateway on the account pool (CLIProxyAPI sidecar).
struct CodexAPIView: View {
    @ObservedObject private var gateway = CodexGatewayService.shared
    @ObservedObject private var store = CodexStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "codex api",
                    title: L("API Service"),
                    subtitle: L("API subtitle")
                )

                CodexControlCard()
                configCard
                endpointsCard
            }
            .padding(MTTheme.s5)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(MTTheme.background)
        .onAppear {
            store.load()
            Task { await gateway.healthCheck() }
        }
    }

    private var configCard: some View {
        MTCard(title: L("Configuration"), systemImage: "gear") {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                HStack(spacing: MTTheme.s3) {
                    Text(L("api key"))
                        .font(MTTheme.mono(11))
                        .foregroundStyle(MTTheme.textSecondary)
                        .frame(width: 90, alignment: .leading)
                    Text(gateway.apiKey)
                        .font(MTTheme.mono(11))
                        .foregroundStyle(MTTheme.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MTSecondaryButton(title: L("Copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(gateway.apiKey, forType: .string)
                    }
                    MTSecondaryButton(title: L("Rotate")) {
                        gateway.apiKey = CodexGatewayService.generateKey()
                        gateway.auditLog("api key rotated — restart the gateway to apply")
                    }
                }
                Text(L("Use this key as the OpenAI API key in other tools. Restart the service after rotating the key."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    private var endpointsCard: some View {
        MTCard(title: L("Client setup"), systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                snippet(L("Base URL"), gateway.baseURL, copy: true)
                snippet(L("API key"), gateway.apiKey)
                Text(L("Any OpenAI-compatible tool can point at this service. Requests are served from the signed-in Codex accounts and are billed to your ChatGPT subscriptions."))
                    .font(MTTheme.mono(10))
                    .foregroundStyle(MTTheme.textSecondary)
            }
        }
    }

    private func snippet(_ label: String, _ value: String, copy: Bool = false) -> some View {
        HStack(spacing: MTTheme.s3) {
            Text(label)
                .font(MTTheme.mono(10))
                .foregroundStyle(MTTheme.textSecondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(MTTheme.mono(11))
                .foregroundStyle(MTTheme.textPrimary)
                .textSelection(.enabled)
            if copy {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(MTTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(L("Copy"))
            }
            Spacer()
        }
    }

}
