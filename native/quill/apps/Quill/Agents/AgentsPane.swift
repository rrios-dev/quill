import QuillAgent
import MCPKit
import SwiftUI

/// Settings › Agents: whether Claude Code, Codex and other agents may use Quill, connecting
/// them, and what they did (docs/initiatives/mac-apps-mcp/DESIGN.md §5–6).
struct AgentsPane: View {
    @Bindable var service: AgentService

    var body: some View {
        Form {
            Section(t("agents.section.access")) {
                Toggle(t("agents.toggle"), isOn: Binding(get: { service.access.enabled }, set: { service.setEnabled($0) }))
                Text(t("agents.help")).font(.caption).foregroundStyle(.secondary)
                Text(t("agents.privacy")).font(.caption).foregroundStyle(.secondary)
            }
            Section(t("agents.section.connect")) {
                ForEach(AgentClient.allCases) { client in
                    LabeledContent(client.name) {
                        HStack {
                            if service.working == client { ProgressView().controlSize(.small) }
                            Button(t("agents.disconnect")) { Task { await service.disconnect(client) } }
                            Button(t("agents.connect")) { Task { await service.connect(client) } }
                                .buttonStyle(.borderedProminent)
                        }
                        .disabled(service.working != nil)
                    }
                    if let status = service.clientStatus[client] {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(t("agents.connect.help")).font(.caption).foregroundStyle(.secondary)
                ForEach(AgentClient.allCases) { client in
                    Text(client.addCommand(server: AgentService.server, path: AgentService.serverPath))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            Section(t("agents.section.log")) {
                if service.recent.isEmpty {
                    Text(t("agents.log.empty")).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(service.recent.enumerated()), id: \.offset) { _, entry in
                        LabeledContent {
                            Text(entry.date, format: .dateTime.day().month().hour().minute())
                        } label: {
                            Text(verbatim: "\(entry.client ?? t("agents.client.unknown")) · \(entry.tool)")
                            if !entry.succeeded { Text(t("agents.log.refused")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Button(t("agents.log.clear"), role: .destructive) { service.clearLog() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { service.refreshLog() }
    }

    private func t(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .localized)
    }
}
