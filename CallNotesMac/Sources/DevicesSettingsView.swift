import AppKit
import CallNotesCore
import CoreImage.CIFilterBuiltins
import SwiftUI

struct DevicesSettingsView: View {
    @Bindable var appModel: AppModel

    var body: some View {
        Form {
            Section("Pair iPhone") {
                Text("Scan this code in CallNotes on iPhone. The fingerprint is pinned for TLS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let payload = appModel.pairingQRPayload, let image = Self.qrImage(payload: payload) {
                    image
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 196, height: 196)
                        .padding(12)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Pairing QR code for iPhone")
                } else {
                    Text("The phone sync server is not running yet.")
                        .foregroundStyle(.secondary)
                }
                Button("Show a new code") {
                    Task { await appModel.refreshPairingTicket() }
                }
                .accessibilityLabel("Show a new iPhone pairing code")
            }

            Section("Paired phones") {
                if let warning = appModel.pairedDevicesWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Revocation was not saved: \(warning)")
                }
                if appModel.pairedDevices.isEmpty {
                    Text("No iPhones are paired.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.pairedDevices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.revokedAt == nil ? "Active" : "Revoked")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.revokedAt == nil {
                                Button("Revoke", role: .destructive) {
                                    Task { await appModel.revokePairedDevice(device.id) }
                                }
                                .accessibilityLabel("Revoke \(device.name)")
                            }
                        }
                        .frame(minHeight: 28)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 520, minHeight: 430)
        .task { await appModel.refreshPairingTicket() }
    }

    private static func qrImage(payload: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return Image(nsImage: image)
    }
}
