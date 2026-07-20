import Defaults
import SwiftUI

struct MessagesSettings: View {
    @Default(.messagesPanelEnabled) private var messagesPanelEnabled

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .messagesPanelEnabled) {
                    Text("Show Messages panel")
                }
                .onChange(of: messagesPanelEnabled) { _, enabled in
                    MessageCenterModel.shared.setEnabled(enabled)
                    if !enabled, BoringViewCoordinator.shared.currentView == .messages {
                        BoringViewCoordinator.shared.currentView = .home
                    }
                }
            } header: {
                Text("Messages")
            } footer: {
                Text("When disabled, the Messages tab is hidden and all message providers stop monitoring Apple Messages, WeChat, WeCom and Telegram.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Messages")
    }
}
