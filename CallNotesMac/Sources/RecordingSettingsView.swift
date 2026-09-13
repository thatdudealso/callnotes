import CallNotesCore
import SwiftUI

struct RecordingSettingsView: View {
    @AppStorage(ConsentPolicy.defaultsKey) private var consentPolicy = ConsentPolicy.announce.rawValue

    var body: some View {
        Form {
            Section("Consent") {
                Picker("On a Mac call", selection: $consentPolicy) {
                    ForEach(ConsentPolicy.allCases, id: \.rawValue) { policy in
                        Text(policy.displayName).tag(policy.rawValue)
                    }
                }
                Text(ConsentPolicy.resolved(consentPolicy).guidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ConsentPolicy.farSideLimit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 280)
    }
}
