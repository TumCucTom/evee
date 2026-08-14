import EveeCore
import SwiftUI

struct PrivacyModeView: View {
    @EnvironmentObject private var store: AppStore

    private let presentation = PrivacyPresentation(enabled: true)

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye.slash.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(AnimaTheme.indigo)
                .accessibilityHidden(true)
            Text("Privacy mode")
                .font(.title2.bold())
            Text("Sensitive Evee content is hidden for this session.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(presentation.windowProtectionCopy)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Turn off privacy mode") {
                store.privacyModeEnabled = false
            }
            .buttonStyle(AlphaButtonStyle())
            .accessibilityHint("Restores sensitive Evee content in this window.")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AnimaTheme.paper)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}
