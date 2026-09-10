import SwiftUI
import VisionKit

struct QRScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scannerFailed = false

    private var scannerIsUsable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable && !scannerFailed
    }

    var body: some View {
        NavigationStack {
            Group {
                if scannerIsUsable {
                    QRScanner(onCode: { code in onCode(code); dismiss() }, onUnavailable: { scannerFailed = true })
                } else {
                    cameraUnavailable
                }
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cancel") { dismiss() }.accessibilityLabel("Cancel QR scan") }
        }
    }

    /// The camera is the first step of pairing, so a refused or unavailable
    /// scanner has to name the typed route rather than show an empty viewfinder.
    private var cameraUnavailable: some View {
        ContentUnavailableView {
            Label("Camera unavailable", systemImage: "camera.fill")
        } description: {
            Text("CallNotes could not open the camera to scan your Mac’s QR code. Allow camera access in Settings, or close this and paste the code into the “Pairing QR payload” field.")
        } actions: {
            Button("Close and paste instead") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true)
        scanner.delegate = context.coordinator
        do {
            try scanner.startScanning()
        } catch {
            Task { @MainActor in onUnavailable() }
        }
        return scanner
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard case let .barcode(barcode) = addedItems.first, let code = barcode.payloadStringValue else { return }
            dataScanner.stopScanning(); onCode(code)
        }
    }
}
