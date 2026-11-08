#if os(iOS)
import SwiftUI
@preconcurrency import AVFoundation

/// Camera view that reports the first QR code it sees. Needs the camera permission; on a Mac-hosted simulator there is no camera.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        var onUnavailable: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: configure()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { ok in
                    DispatchQueue.main.async { ok ? self.configure() : self.onUnavailable?(String(localized: "Camera access was denied. You can allow it in Settings, or type the code instead.")) }
                }
            default:
                onUnavailable?(String(localized: "Camera access was denied. You can allow it in Settings, or type the code instead."))
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                onUnavailable?(String(localized: "No camera is available here. Type the code instead."))
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            session.stopRunning()
            onCode?(text)
        }
    }
}

/// The sheet around the camera: scan the QR code shown on the other device.
struct QRScanSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerView(onCode: handle, onUnavailable: { problem = $0 }).ignoresSafeArea()
                if let problem {
                    Text(problem).multilineTextAlignment(.center).padding().background(.regularMaterial, in: .rect(cornerRadius: 12)).padding()
                } else {
                    VStack { Spacer(); Text("Point the camera at the QR code on your other device.")
                        .padding(10).background(.regularMaterial, in: .capsule).padding(.bottom, 40) }
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close", systemImage: "xmark") { dismiss() } } }
        }
    }

    private func handle(_ text: String) {
        Task {
            if await app.sync.join(code: text) { dismiss() }
            else { problem = app.sync.joinError ?? String(localized: "That QR code is not a Musicam pairing code.") }
        }
    }
}
#endif
