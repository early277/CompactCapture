import AVFoundation
import CoreGraphics
import SwiftUI
import UIKit

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var onRotationAngleChanged: ((CGFloat) -> Void)?

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var rotationDeviceID: String?
    private var lastReportedRotationAngle: CGFloat?

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshRotationCoordinatorIfNeeded()
        applyPreviewOrientation()
    }

    func update(session: AVCaptureSession, onRotationAngleChanged: @escaping (CGFloat) -> Void) {
        self.onRotationAngleChanged = onRotationAngleChanged
        if previewLayer.session !== session {
            previewLayer.session = session
            rotationObservation = nil
            rotationCoordinator = nil
            rotationDeviceID = nil
            lastReportedRotationAngle = nil
        }
        refreshRotationCoordinatorIfNeeded()
        applyPreviewOrientation()
    }

    private func refreshRotationCoordinatorIfNeeded() {
        guard let deviceInput = previewLayer.session?.inputs
            .compactMap({ $0 as? AVCaptureDeviceInput })
            .first(where: { $0.device.hasMediaType(.video) })
        else { return }

        let device = deviceInput.device
        guard rotationDeviceID != device.uniqueID else { return }

        rotationObservation = nil
        let coordinator = AVCaptureDevice.RotationCoordinator(
            device: device,
            previewLayer: previewLayer
        )
        rotationDeviceID = device.uniqueID
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            self?.applyPreviewOrientation(
                angle: coordinator.videoRotationAngleForHorizonLevelPreview
            )
        }
    }

    private func applyPreviewOrientation() {
        applyPreviewOrientation(
            angle: rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 90
        )
    }

    private func applyPreviewOrientation(angle reportedAngle: CGFloat) {
        // iPadOS can resize or visually rotate a scene even when the app prefers
        // portrait. Follow the camera's physical rotation so both preview paths
        // remain upright in that compatibility case as well.
        let angle = normalizedRotationAngle(reportedAngle)
        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }

        guard lastReportedRotationAngle != angle else { return }
        lastReportedRotationAngle = angle
        onRotationAngleChanged?(angle)
    }

    private func normalizedRotationAngle(_ angle: CGFloat) -> CGFloat {
        let positive = (angle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let quadrant = Int((positive / 90).rounded()) % 4
        return CGFloat(quadrant * 90)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onRotationAngleChanged: (CGFloat) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.update(session: session, onRotationAngleChanged: onRotationAngleChanged)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.update(session: session, onRotationAngleChanged: onRotationAngleChanged)
    }
}

struct ResultCameraPreview: View {
    let image: CGImage

    var body: some View {
        GeometryReader { proxy in
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black)
    }
}
