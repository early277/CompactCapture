import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Darwin
import Foundation

enum VideoRecorderError: LocalizedError {
    case alreadyRecording
    case noVideoFrames
    case writerCreationFailed
    case unsupportedSettings
    case pixelBufferCreationFailed
    case appendFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: L10n.string("すでに録画中です。")
        case .noVideoFrames: L10n.string("動画フレームを取得できませんでした。")
        case .writerCreationFailed: L10n.string("動画ファイルを作成できませんでした。")
        case .unsupportedSettings: L10n.string("この端末では指定した動画設定を使用できません。")
        case .pixelBufferCreationFailed:
            L10n.string("色の細かさを変換するためのバッファを作成できませんでした。")
        case let .appendFailed(message):
            L10n.format("動画の書き込みに失敗しました。\n%@", message)
        }
    }
}

struct RecordedVideo {
    let url: URL
    let duration: TimeInterval
    let pixelWidth: Int
    let pixelHeight: Int
}

final class VideoRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private enum State: Equatable {
        case idle
        case waitingForFirstFrame
        case recording
        case finishing
    }

    private var state: State = .idle
    private var configuration: VideoRecordingConfiguration?
    private var completion: ((Result<RecordedVideo, Error>) -> Void)?
    private var outputURL: URL?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstPresentationTime: CMTime?
    private var lastAcceptedVideoTime: CMTime?
    private var frameRequiresCIProcessing = false
    private var sourceRotationAngle: CGFloat = 0
    private var captureRotationAngle: CGFloat = 0
    private var recordedPixelWidth = 0
    private var recordedPixelHeight = 0
    private lazy var ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false
    ])
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    // start/stop and both sample-buffer delegate methods are called on the same serial queue.
    func start(
        configuration: VideoRecordingConfiguration,
        sourceRotationAngle: CGFloat,
        captureRotationAngle: CGFloat,
        completion: @escaping (Result<RecordedVideo, Error>) -> Void
    ) {
        guard state == .idle else {
            completion(.failure(VideoRecorderError.alreadyRecording))
            return
        }

        self.configuration = configuration
        self.sourceRotationAngle = Self.normalizedRotationAngle(sourceRotationAngle)
        self.captureRotationAngle = Self.normalizedRotationAngle(captureRotationAngle)
        self.completion = completion
        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompactCapture-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        state = .waitingForFirstFrame
    }

    func stop() {
        switch state {
        case .idle:
            return
        case .waitingForFirstFrame:
            finishWithFailure(VideoRecorderError.noVideoFrames)
        case .recording:
            state = .finishing
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()

            guard let writer else {
                finishWithFailure(VideoRecorderError.writerCreationFailed)
                return
            }
            writer.finishWriting { [weak self] in
                guard let self else { return }
                if writer.status == .completed, let url = self.outputURL {
                    self.finishWithSuccess(url)
                } else {
                    self.finishWithFailure(
                        VideoRecorderError.appendFailed(
                            writer.error?.localizedDescription ?? L10n.string("不明なエラー")
                        )
                    )
                }
            }
        case .finishing:
            return
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard state == .waitingForFirstFrame || state == .recording else { return }

        if output is AVCaptureVideoDataOutput {
            appendVideo(sampleBuffer)
        } else if output is AVCaptureAudioDataOutput {
            appendAudio(sampleBuffer)
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard
            CMSampleBufferDataIsReady(sampleBuffer),
            let configuration,
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let minimumInterval = 1.0 / Double(configuration.frameRate.rawValue)
        if let lastAcceptedVideoTime {
            let elapsed = CMTimeSubtract(presentationTime, lastAcceptedVideoTime).seconds
            if elapsed.isFinite, elapsed < minimumInterval * 0.9 {
                return
            }
        }

        if state == .waitingForFirstFrame {
            do {
                try createWriter(
                    width: CVPixelBufferGetWidth(imageBuffer),
                    height: CVPixelBufferGetHeight(imageBuffer),
                    startTime: presentationTime
                )
                state = .recording
            } catch {
                finishWithFailure(error)
                return
            }
        }

        guard state == .recording, let videoInput, videoInput.isReadyForMoreMediaData else { return }

        let appended: Bool
        if frameRequiresCIProcessing {
            appended = appendCIProcessedFrame(
                imageBuffer,
                at: presentationTime,
                configuration: configuration
            )
        } else if configuration.chromaMode.requiresProcessing {
            appended = appendChromaReduced(
                imageBuffer,
                at: presentationTime,
                mode: configuration.chromaMode
            )
        } else {
            appended = videoInput.append(sampleBuffer)
        }

        if appended {
            lastAcceptedVideoTime = presentationTime
        } else if let writer, writer.status == .failed {
            finishWithFailure(
                VideoRecorderError.appendFailed(
                    writer.error?.localizedDescription ?? L10n.string("フレームを追加できませんでした。")
                )
            )
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard
            state == .recording,
            configuration?.includeAudio == true,
            let firstPresentationTime,
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= firstPresentationTime,
            let audioInput,
            audioInput.isReadyForMoreMediaData
        else { return }

        if !audioInput.append(sampleBuffer), let writer, writer.status == .failed {
            finishWithFailure(
                VideoRecorderError.appendFailed(
                    writer.error?.localizedDescription ?? L10n.string("音声を追加できませんでした。")
                )
            )
        }
    }

    private func createWriter(width: Int, height: Int, startTime: CMTime) throws {
        guard let configuration, let outputURL else {
            throw VideoRecorderError.writerCreationFailed
        }

        let desired = configuration.logicalDimensions
        let sourceIsPortrait = height > width
        let logicalWidth = sourceIsPortrait ? Int(desired.height) : Int(desired.width)
        let logicalHeight = sourceIsPortrait ? Int(desired.width) : Int(desired.height)
        let factor = configuration.pixelUpscaleFactor.rawValue
        let outputWidth = logicalWidth * factor
        let outputHeight = logicalHeight * factor
        frameRequiresCIProcessing = configuration.colorLevels.isReduced
            || configuration.contrast.requiresProcessing
            || configuration.codec.requiresRGBProcessing
            || logicalWidth != width
            || logicalHeight != height
            || factor > 1

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: configuration.codec.avCodec,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        if configuration.codec.supportsBitRateSelection {
            videoSettings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: configuration.bitRate.rawValue,
                AVVideoExpectedSourceFrameRateKey: configuration.frameRate.rawValue,
                AVVideoMaxKeyFrameIntervalKey: configuration.frameRate.rawValue * 2,
                AVVideoAllowFrameReorderingKey: false
            ]
        }

        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw VideoRecorderError.unsupportedSettings
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let displayRotationAngle = Self.normalizedRotationAngle(
            captureRotationAngle - sourceRotationAngle
        )
        videoInput.transform = Self.trackTransform(for: displayRotationAngle)
        if displayRotationAngle == 90 || displayRotationAngle == 270 {
            recordedPixelWidth = outputHeight
            recordedPixelHeight = outputWidth
        } else {
            recordedPixelWidth = outputWidth
            recordedPixelHeight = outputHeight
        }
        guard writer.canAdd(videoInput) else {
            throw VideoRecorderError.unsupportedSettings
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if configuration.includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ]
            if writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }
        }

        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if frameRequiresCIProcessing || configuration.chromaMode.requiresProcessing {
            let pixelFormat = frameRequiresCIProcessing
                ? kCVPixelFormatType_32BGRA
                : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: attributes
            )
        }

        guard writer.startWriting() else {
            throw VideoRecorderError.appendFailed(
                writer.error?.localizedDescription ?? L10n.string("書き込みを開始できませんでした。")
            )
        }
        writer.startSession(atSourceTime: startTime)

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        pixelBufferAdaptor = adaptor
        firstPresentationTime = startTime
    }

    private func appendCIProcessedFrame(
        _ sourceBuffer: CVPixelBuffer,
        at presentationTime: CMTime,
        configuration: VideoRecordingConfiguration
    ) -> Bool {
        guard
            let adaptor = pixelBufferAdaptor,
            let pool = adaptor.pixelBufferPool
        else { return false }

        var destinationBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destinationBuffer) == kCVReturnSuccess,
              let destinationBuffer
        else { return false }

        let outputBounds = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(destinationBuffer),
            height: CVPixelBufferGetHeight(destinationBuffer)
        )
        let factor = configuration.pixelUpscaleFactor.rawValue
        let logicalBounds = CGRect(
            x: 0,
            y: 0,
            width: outputBounds.width / CGFloat(factor),
            height: outputBounds.height / CGFloat(factor)
        )
        var image = aspectFill(
            CIImage(cvPixelBuffer: sourceBuffer),
            to: logicalBounds
        )

        image = CaptureImageKernels.applyingContrast(configuration.contrast, to: image)

        if configuration.colorLevels.isReduced {
            guard let rgbKernel = CaptureImageKernels.rgbQuantize,
                  let quantized = rgbKernel.apply(
                      extent: image.extent,
                      arguments: [image, Float(configuration.colorLevels.rawValue)]
                  )
            else { return false }
            image = quantized
        }

        if configuration.chromaMode.requiresProcessing,
           let chromaKernel = CaptureImageKernels.chromaQuantize,
           let reduced = chromaKernel.apply(
               extent: image.extent,
               arguments: [
                   image,
                   Float(configuration.chromaMode.chromaQuantizationStep),
                   configuration.chromaMode == .monochrome ? Float(1) : Float(0)
               ]
           ) {
            image = reduced
        }

        if factor > 1 {
            image = image
                .samplingNearest()
                .transformed(
                    by: CGAffineTransform(
                        scaleX: CGFloat(factor),
                        y: CGFloat(factor)
                    )
                )
        }

        ciContext.render(
            image,
            to: destinationBuffer,
            bounds: outputBounds,
            colorSpace: rgbColorSpace
        )
        return adaptor.append(destinationBuffer, withPresentationTime: presentationTime)
    }

    private func aspectFill(_ image: CIImage, to bounds: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return image }

        let scale = max(bounds.width / source.width, bounds.height / source.height)
        let scaled = image.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let scaledExtent = scaled.extent
        let crop = CGRect(
            x: scaledExtent.midX - bounds.width / 2,
            y: scaledExtent.midY - bounds.height / 2,
            width: bounds.width,
            height: bounds.height
        )
        return scaled
            .cropped(to: crop)
            .transformed(
                by: CGAffineTransform(
                    translationX: -crop.minX,
                    y: -crop.minY
                )
            )
    }

    private func appendChromaReduced(
        _ sourceBuffer: CVPixelBuffer,
        at presentationTime: CMTime,
        mode: VideoChromaMode
    ) -> Bool {
        guard
            let adaptor = pixelBufferAdaptor,
            let pool = adaptor.pixelBufferPool,
            CVPixelBufferGetPlaneCount(sourceBuffer) >= 2
        else { return false }

        var destinationBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destinationBuffer) == kCVReturnSuccess,
              let destinationBuffer
        else { return false }

        guard copyLumaAndReduceChroma(
            from: sourceBuffer,
            to: destinationBuffer,
            mode: mode
        ) else { return false }
        return adaptor.append(destinationBuffer, withPresentationTime: presentationTime)
    }

    private func copyLumaAndReduceChroma(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        mode: VideoChromaMode
    ) -> Bool {
        guard
            CVPixelBufferGetPlaneCount(source) >= 2,
            CVPixelBufferGetPlaneCount(destination) >= 2,
            CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess
        else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }

        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            return false
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        guard copyPlane(from: source, to: destination, plane: 0) else { return false }
        guard copyPlane(from: source, to: destination, plane: 1) else { return false }

        guard let chromaBase = CVPixelBufferGetBaseAddressOfPlane(destination, 1) else {
            return false
        }
        let chromaHeight = CVPixelBufferGetHeightOfPlane(destination, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(destination, 1)
        let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, 1)
        let activeBytesPerRow = min(chromaWidth * 2, chromaBytesPerRow)

        for row in 0..<chromaHeight {
            let bytes = chromaBase
                .advanced(by: row * chromaBytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for index in 0..<activeBytesPerRow {
                if mode == .monochrome {
                    bytes[index] = 128
                } else {
                    bytes[index] = quantizeChromaByte(
                        bytes[index],
                        step: mode.chromaQuantizationStep
                    )
                }
            }
        }
        return true
    }

    private func copyPlane(
        from source: CVPixelBuffer,
        to destination: CVPixelBuffer,
        plane: Int
    ) -> Bool {
        guard
            let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
            let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane)
        else { return false }

        let rows = min(
            CVPixelBufferGetHeightOfPlane(source, plane),
            CVPixelBufferGetHeightOfPlane(destination, plane)
        )
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
        let bytesToCopy = min(sourceBytesPerRow, destinationBytesPerRow)

        for row in 0..<rows {
            memcpy(
                destinationBase.advanced(by: row * destinationBytesPerRow),
                sourceBase.advanced(by: row * sourceBytesPerRow),
                bytesToCopy
            )
        }
        return true
    }

    private func quantizeChromaByte(_ value: UInt8, step: Int) -> UInt8 {
        guard step > 1 else { return value }
        let difference = Int(value) - 128
        let magnitude = abs(difference)
        let roundedMagnitude = ((magnitude + step / 2) / step) * step
        let signed = difference < 0 ? -roundedMagnitude : roundedMagnitude
        return UInt8(clamping: 128 + signed)
    }

    private static func normalizedRotationAngle(_ angle: CGFloat) -> CGFloat {
        let positive = (angle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let quadrant = Int((positive / 90).rounded()) % 4
        return CGFloat(quadrant * 90)
    }

    private static func trackTransform(for rotationAngle: CGFloat) -> CGAffineTransform {
        switch Int(normalizedRotationAngle(rotationAngle)) {
        case 90:
            CGAffineTransform(rotationAngle: .pi / 2)
        case 180:
            CGAffineTransform(rotationAngle: .pi)
        case 270:
            CGAffineTransform(rotationAngle: -.pi / 2)
        default:
            .identity
        }
    }

    private func finishWithSuccess(_ url: URL) {
        let frameDuration = configuration.map { 1.0 / Double($0.frameRate.rawValue) } ?? 0
        let measuredDuration: TimeInterval
        if let firstPresentationTime, let lastAcceptedVideoTime {
            let elapsed = CMTimeSubtract(lastAcceptedVideoTime, firstPresentationTime).seconds
            measuredDuration = elapsed.isFinite ? max(elapsed + frameDuration, 0) : 0
        } else {
            measuredDuration = 0
        }
        let callback = completion
        let pixelWidth = recordedPixelWidth
        let pixelHeight = recordedPixelHeight
        reset()
        callback?(.success(RecordedVideo(
            url: url,
            duration: measuredDuration,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )))
    }

    private func finishWithFailure(_ error: Error) {
        writer?.cancelWriting()
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        let callback = completion
        reset()
        callback?(.failure(error))
    }

    private func reset() {
        state = .idle
        configuration = nil
        completion = nil
        outputURL = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        pixelBufferAdaptor = nil
        firstPresentationTime = nil
        lastAcceptedVideoTime = nil
        frameRequiresCIProcessing = false
        sourceRotationAngle = 0
        captureRotationAngle = 0
        recordedPixelWidth = 0
        recordedPixelHeight = 0
    }
}
