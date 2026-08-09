import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

struct LivePreviewConfiguration {
    let isEnabled: Bool
    let rotationAngle: CGFloat
    let captureMode: CaptureMode
    let photoFormat: PhotoFileFormat
    let photoResolution: PhotoResolution
    let videoResolution: VideoResolution
    let colorLevels: ColorLevels
    let contrast: ImageContrast
    let videoChromaMode: VideoChromaMode
    let pixelUpscaleFactor: PixelUpscaleFactor
}

struct LivePreviewFrame {
    let image: CGImage
    let pixelDimensionsText: String
}

enum CaptureImageKernels {
    static let rgbQuantize = CIColorKernel(source: """
        kernel vec4 quantizeColor(__sample pixel, float steps) {
            float divisor = max(steps - 1.0, 1.0);
            vec3 reduced = floor(pixel.rgb * divisor + 0.5) / divisor;
            return vec4(reduced, pixel.a);
        }
        """)

    // This is a display-oriented BT.709 approximation of the recorder's direct
    // Y′CbCr chroma-plane quantization. Luma is retained while Cb/Cr are stepped.
    static let chromaQuantize = CIColorKernel(source: """
        kernel vec4 quantizeChroma(__sample pixel, float byteStep, float monochrome) {
            float y = dot(pixel.rgb, vec3(0.2126, 0.7152, 0.0722));
            float cb = (pixel.b - y) / 1.8556;
            float cr = (pixel.r - y) / 1.5748;
            float unit = max(byteStep / 255.0, 1.0 / 255.0);
            vec2 chroma = vec2(cb, cr);
            vec2 reduced = sign(chroma) * floor(abs(chroma) / unit + 0.5) * unit;
            reduced *= 1.0 - monochrome;

            float r = y + 1.5748 * reduced.y;
            float b = y + 1.8556 * reduced.x;
            float g = (y - 0.2126 * r - 0.0722 * b) / 0.7152;
            return vec4(clamp(vec3(r, g, b), 0.0, 1.0), pixel.a);
        }
        """)

    static func applyingContrast(_ contrast: ImageContrast, to image: CIImage) -> CIImage {
        guard contrast.requiresProcessing else { return image }
        return image.applyingFilter(
            "CIColorControls",
            parameters: [kCIInputContrastKey: contrast.rawValue]
        )
    }
}

final class LivePreviewProcessor {
    var onFrame: ((LivePreviewFrame) -> Void)?

    private let processingQueue = DispatchQueue(
        label: "CompactCapture.livePreview",
        qos: .userInteractive
    )
    private let stateLock = NSLock()
    private lazy var ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false
    ])

    private var configuration = LivePreviewConfiguration(
        isEnabled: true,
        rotationAngle: 90,
        captureMode: .photo,
        photoFormat: .png,
        photoResolution: .fourMP,
        videoResolution: .hd,
        colorLevels: .full,
        contrast: .standard,
        videoChromaMode: .standard,
        pixelUpscaleFactor: .one
    )
    private var photoNativeDimensions: CMVideoDimensions?
    private var latestPixelBuffer: CVPixelBuffer?
    private var frameIsPending = false
    private var lastAcceptedTime = CMTime.invalid
    private var requestedRenderGeneration: UInt64 = 0
    private var completedRenderGeneration: UInt64 = 0
    private var isAcceptingFrames = true
    private var framesToSkip = 0

    func update(configuration: LivePreviewConfiguration) {
        let shouldStartRendering: Bool
        stateLock.lock()
        self.configuration = configuration
        if configuration.isEnabled, latestPixelBuffer != nil {
            requestedRenderGeneration &+= 1
            shouldStartRendering = !frameIsPending
            frameIsPending = true
        } else {
            shouldStartRendering = false
        }
        stateLock.unlock()

        if shouldStartRendering {
            schedulePendingRender()
        }
    }

    func updatePhotoNativeDimensions(_ dimensions: CMVideoDimensions) {
        stateLock.lock()
        photoNativeDimensions = dimensions
        stateLock.unlock()
    }

    func beginCaptureReconfiguration() {
        stateLock.lock()
        isAcceptingFrames = false
        framesToSkip = 0
        stateLock.unlock()
    }

    func endCaptureReconfiguration(skippingInitialFrames: Int = 2) {
        stateLock.lock()
        latestPixelBuffer = nil
        lastAcceptedTime = .invalid
        framesToSkip = max(skippingInitialFrames, 0)
        isAcceptingFrames = true
        stateLock.unlock()
    }

    func submit(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        stateLock.lock()
        let snapshot = configuration
        guard snapshot.isEnabled, isAcceptingFrames else {
            stateLock.unlock()
            return
        }
        if framesToSkip > 0 {
            framesToSkip -= 1
            stateLock.unlock()
            return
        }
        latestPixelBuffer = pixelBuffer
        let hasRecentFrame: Bool
        if lastAcceptedTime.isValid, presentationTime.isValid {
            let elapsed = CMTimeSubtract(presentationTime, lastAcceptedTime).seconds
            hasRecentFrame = elapsed.isFinite && elapsed >= 0 && elapsed < 0.12
        } else {
            hasRecentFrame = false
        }

        guard !hasRecentFrame else {
            stateLock.unlock()
            return
        }
        lastAcceptedTime = presentationTime
        requestedRenderGeneration &+= 1
        let shouldStartRendering = !frameIsPending
        frameIsPending = true
        stateLock.unlock()

        if shouldStartRendering {
            schedulePendingRender()
        }
    }

    private func schedulePendingRender() {
        processingQueue.async { [weak self] in
            self?.renderPendingFrames()
        }
    }

    private func renderPendingFrames() {
        while true {
            stateLock.lock()
            guard configuration.isEnabled,
                  completedRenderGeneration < requestedRenderGeneration,
                  let pixelBuffer = latestPixelBuffer
            else {
                frameIsPending = false
                stateLock.unlock()
                return
            }
            let generation = requestedRenderGeneration
            let snapshot = configuration
            let nativeDimensions = photoNativeDimensions
            stateLock.unlock()

            if let frame = makeFrame(
                from: pixelBuffer,
                configuration: snapshot,
                photoNativeDimensions: nativeDimensions
            ) {
                onFrame?(frame)
            }

            stateLock.lock()
            completedRenderGeneration = max(completedRenderGeneration, generation)
            let hasMoreWork = completedRenderGeneration < requestedRenderGeneration
            if !hasMoreWork {
                frameIsPending = false
            }
            stateLock.unlock()

            if !hasMoreWork { return }
        }
    }

    private func makeFrame(
        from pixelBuffer: CVPixelBuffer,
        configuration: LivePreviewConfiguration,
        photoNativeDimensions: CMVideoDimensions?
    ) -> LivePreviewFrame? {
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        // Keep the data output in the sensor's native orientation, then rotate only
        // the on-screen result to match the current iPhone/iPad interface. Saved media
        // receives its independent capture-time orientation in CameraController.
        image = image.oriented(imageOrientation(for: configuration.rotationAngle))
        let sourceExtent = image.extent.integral
        guard sourceExtent.width > 0, sourceExtent.height > 0 else { return nil }

        let orientedPhotoNativeSize = orientedPhotoNativeSize(
            sourceSize: sourceExtent.size,
            photoNativeDimensions: photoNativeDimensions
        )
        if configuration.captureMode == .photo {
            image = centerCrop(
                image,
                toAspectRatio: orientedPhotoNativeSize.width / orientedPhotoNativeSize.height
            )
        } else {
            var videoSize = configuration.videoResolution.dimensions.size
            let sourceIsPortrait = sourceExtent.height > sourceExtent.width
            let videoIsPortrait = videoSize.height > videoSize.width
            if sourceIsPortrait != videoIsPortrait {
                videoSize = CGSize(width: videoSize.height, height: videoSize.width)
            }
            image = centerCrop(
                image,
                toAspectRatio: videoSize.width / videoSize.height
            )
        }

        let comparisonExtent = image.extent.integral

        let plannedSize = plannedPixelSize(
            sourceSize: comparisonExtent.size,
            configuration: configuration,
            photoNativeDimensions: photoNativeDimensions
        )
        // Render low-resolution choices at their actual logical pixel dimensions.
        // Scaling by the still camera's native-to-target ratio made the proxy stream
        // much smaller than requested (for example 0.05 MP could become only a few
        // thousand pixels), which produced unstable, over-enlarged previews.
        let widthScale = plannedSize.width / comparisonExtent.width
        let heightScale = plannedSize.height / comparisonExtent.height
        let resolutionScale = min(1, widthScale, heightScale)
        if resolutionScale < 0.999 {
            image = image.transformed(
                by: CGAffineTransform(scaleX: resolutionScale, y: resolutionScale)
            )
        }

        // Match the save pipeline: resize first, then adjust contrast and RGB levels/chroma.
        // Display-only cropping and the 1,440 px render cap come afterwards.
        image = CaptureImageKernels.applyingContrast(configuration.contrast, to: image)

        switch configuration.captureMode {
        case .photo:
            if configuration.colorLevels.isReduced,
               let kernel = CaptureImageKernels.rgbQuantize,
               let reduced = kernel.apply(
                   extent: image.extent,
                   arguments: [image, Float(configuration.colorLevels.rawValue)]
               ) {
                image = reduced
            }

        case .video:
            if configuration.colorLevels.isReduced,
               let kernel = CaptureImageKernels.rgbQuantize,
               let reduced = kernel.apply(
                   extent: image.extent,
                   arguments: [image, Float(configuration.colorLevels.rawValue)]
               ) {
                image = reduced
            }

            if configuration.videoChromaMode.requiresProcessing,
               let kernel = CaptureImageKernels.chromaQuantize,
               let reduced = kernel.apply(
                   extent: image.extent,
                   arguments: [
                       image,
                       Float(configuration.videoChromaMode.chromaQuantizationStep),
                       configuration.videoChromaMode == .monochrome ? Float(1) : Float(0)
                   ]
               ) {
                image = reduced
            }
        }

        let longestEdge = max(image.extent.width, image.extent.height)
        if longestEdge > 1_440 {
            let displayScale = 1_440 / longestEdge
            image = image.transformed(
                by: CGAffineTransform(scaleX: displayScale, y: displayScale)
            )
        }

        let renderExtent = image.extent.integral
        guard let cgImage = ciContext.createCGImage(image, from: renderExtent) else { return nil }
        let appliedFactor = configuration.captureMode == .photo
            && configuration.photoFormat != .png
            ? 1
            : configuration.pixelUpscaleFactor.rawValue
        let logicalText = "\(Int(plannedSize.width))×\(Int(plannedSize.height))"
        let savedText: String
        if appliedFactor > 1 {
            let savedWidth = Int(plannedSize.width) * appliedFactor
            let savedHeight = Int(plannedSize.height) * appliedFactor
            savedText = "\(logicalText) → \(savedWidth)×\(savedHeight) (\(appliedFactor)×)"
        } else {
            savedText = logicalText
        }
        return LivePreviewFrame(image: cgImage, pixelDimensionsText: savedText)
    }

    private func imageOrientation(for rotationAngle: CGFloat) -> CGImagePropertyOrientation {
        let positive = (rotationAngle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        switch Int((positive / 90).rounded()) % 4 {
        case 1: return CGImagePropertyOrientation.right
        case 2: return CGImagePropertyOrientation.down
        case 3: return CGImagePropertyOrientation.left
        default: return CGImagePropertyOrientation.up
        }
    }

    private func plannedPixelSize(
        sourceSize: CGSize,
        configuration: LivePreviewConfiguration,
        photoNativeDimensions: CMVideoDimensions?
    ) -> CGSize {
        if configuration.captureMode == .video {
            var outputSize = configuration.videoResolution.dimensions.size
            let sourceIsPortrait = sourceSize.height > sourceSize.width
            let outputIsPortrait = outputSize.height > outputSize.width
            if sourceIsPortrait != outputIsPortrait {
                outputSize = CGSize(width: outputSize.height, height: outputSize.width)
            }
            return outputSize
        }

        let nativeSize = orientedPhotoNativeSize(
            sourceSize: sourceSize,
            photoNativeDimensions: photoNativeDimensions
        )

        guard let maximumPixelCount = configuration.photoResolution.maximumPixelCount else {
            return nativeSize
        }
        let nativePixelCount = nativeSize.width * nativeSize.height
        guard nativePixelCount > CGFloat(maximumPixelCount) else { return nativeSize }

        let scale = sqrt(CGFloat(maximumPixelCount) / nativePixelCount)
        return CGSize(
            width: max(1, floor(nativeSize.width * scale)),
            height: max(1, floor(nativeSize.height * scale))
        )
    }

    private func orientedPhotoNativeSize(
        sourceSize: CGSize,
        photoNativeDimensions: CMVideoDimensions?
    ) -> CGSize {
        var nativeSize = photoNativeDimensions?.size ?? sourceSize
        let sourceIsPortrait = sourceSize.height > sourceSize.width
        let nativeIsPortrait = nativeSize.height > nativeSize.width
        if sourceIsPortrait != nativeIsPortrait {
            nativeSize = CGSize(width: nativeSize.height, height: nativeSize.width)
        }
        return nativeSize
    }

    private func centerCrop(_ image: CIImage, toAspectRatio targetAspectRatio: CGFloat) -> CIImage {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0, targetAspectRatio > 0 else { return image }

        let currentAspectRatio = extent.width / extent.height
        let cropRect: CGRect
        if currentAspectRatio > targetAspectRatio {
            let width = extent.height * targetAspectRatio
            cropRect = CGRect(
                x: extent.midX - width / 2,
                y: extent.minY,
                width: width,
                height: extent.height
            )
        } else {
            let height = extent.width / targetAspectRatio
            cropRect = CGRect(
                x: extent.minX,
                y: extent.midY - height / 2,
                width: extent.width,
                height: height
            )
        }
        return image.cropped(to: cropRect.integral)
    }
}
