@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// The camera as a QR reader: a live picture and a callback for each code it reads (on the main actor). It runs only
/// while the view is on screen and `isActive`; the session starts and stops off the main thread.
struct QRScannerView: UIViewRepresentable {
    var isActive: Bool
    var onCode: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = context.coordinator.session
        context.coordinator.onCode = onCode
        context.coordinator.prepare()
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.setActive(isActive)
    }

    static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        // swiftlint:disable:next force_cast
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    // @unchecked: `onCode` is only touched on the main actor; the session is only touched on `queue`.
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "dev.bandito.ios.qr-scanner")
        private var configured = false
        private var wantsRunning = false
        @MainActor var onCode: @MainActor (String) -> Void = { _ in }

        /// Adds the camera and the QR reader, once.
        func prepare() {
            queue.async { [self] in
                guard !configured, let device = AVCaptureDevice.default(for: .video),
                    let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
                else { return }
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else { return }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
                configured = true
                if wantsRunning { session.startRunning() }
            }
        }

        func setActive(_ active: Bool) {
            queue.async { [self] in
                wantsRunning = active
                guard configured else { return }
                if active, !session.isRunning {
                    session.startRunning()
                } else if !active, session.isRunning {
                    session.stopRunning()
                }
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection
        ) {
            guard let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first(where: { $0.type == .qr }),
                let text = code.stringValue
            else { return }
            // The delegate queue is the main queue.
            MainActor.assumeIsolated { onCode(text) }
        }
    }
}

enum CameraPermission {
    static var hasCamera: Bool { AVCaptureDevice.default(for: .video) != nil }

    static func current() -> CameraAccess {
        let status: CameraAccess.Status =
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined: .notDetermined
            case .restricted: .restricted
            case .denied: .denied
            case .authorized: .authorized
            @unknown default: .denied
            }
        return CameraAccess.from(status: status, hasCamera: hasCamera)
    }

    /// Asks once, with the system's own dialog (the explanation is on the screen before this is called).
    static func request() async -> CameraAccess {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return current()
    }
}
