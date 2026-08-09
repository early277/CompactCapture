import CoreImage
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct EncodedPhoto {
    let data: Data
    let fileExtension: String
    let uniformTypeIdentifier: String
}

struct PhotoReviewPreview {
    let image: UIImage
    let pixelWidth: Int
    let pixelHeight: Int
}

enum PhotoProcessingError: LocalizedError {
    case invalidImage
    case renderFailed
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: "写真データを読み取れませんでした。"
        case .renderFailed: "写真の変換に失敗しました。"
        case .encodeFailed: "指定形式で保存データを作れませんでした。"
        }
    }
}

enum PhotoProcessor {
    private static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false
    ])

    static func encode(
        sourceData: Data,
        configuration: PhotoEncodingConfiguration
    ) throws -> EncodedPhoto {
        guard let sourceImage = UIImage(data: sourceData) else {
            throw PhotoProcessingError.invalidImage
        }

        let resized = resize(sourceImage, maximumPixelCount: configuration.resolution.maximumPixelCount)
        let reduced = try applyColorAdjustments(
            to: resized,
            contrast: configuration.contrast,
            levels: configuration.colorLevels
        )

        switch configuration.format {
        case .png:
            let output = try nearestNeighborUpscale(
                reduced,
                factor: configuration.appliedPixelUpscaleFactor.rawValue
            )
            guard let data = output.pngData() else {
                throw PhotoProcessingError.encodeFailed
            }
            return EncodedPhoto(
                data: data,
                fileExtension: "png",
                uniformTypeIdentifier: UTType.png.identifier
            )

        case .jpeg:
            guard let data = reduced.jpegData(compressionQuality: configuration.lossyQuality) else {
                throw PhotoProcessingError.encodeFailed
            }
            return EncodedPhoto(
                data: data,
                fileExtension: "jpg",
                uniformTypeIdentifier: UTType.jpeg.identifier
            )

        case .heif:
            guard let cgImage = reduced.cgImage else {
                throw PhotoProcessingError.renderFailed
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.heic.identifier as CFString,
                1,
                nil
            ) else {
                throw PhotoProcessingError.encodeFailed
            }
            let properties = [
                kCGImageDestinationLossyCompressionQuality: configuration.lossyQuality
            ] as CFDictionary
            CGImageDestinationAddImage(destination, cgImage, properties)
            guard CGImageDestinationFinalize(destination) else {
                throw PhotoProcessingError.encodeFailed
            }
            return EncodedPhoto(
                data: output as Data,
                fileExtension: "heic",
                uniformTypeIdentifier: UTType.heic.identifier
            )
        }
    }

    static func makeReviewPreview(
        from encodedData: Data,
        maximumPixelDimension: Int = 2_048
    ) -> PhotoReviewPreview? {
        guard let source = CGImageSourceCreateWithData(encodedData as CFData, nil) else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return PhotoReviewPreview(
            image: UIImage(cgImage: thumbnail, scale: 1, orientation: .up),
            pixelWidth: pixelWidth > 0 ? pixelWidth : thumbnail.width,
            pixelHeight: pixelHeight > 0 ? pixelHeight : thumbnail.height
        )
    }

    private static func resize(_ image: UIImage, maximumPixelCount: Int?) -> UIImage {
        let sourcePixelSize: CGSize
        if let cgImage = image.cgImage {
            let isSideways = image.imageOrientation == .left
                || image.imageOrientation == .leftMirrored
                || image.imageOrientation == .right
                || image.imageOrientation == .rightMirrored
            sourcePixelSize = isSideways
                ? CGSize(width: CGFloat(cgImage.height), height: CGFloat(cgImage.width))
                : CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        } else {
            sourcePixelSize = CGSize(
                width: image.size.width * image.scale,
                height: image.size.height * image.scale
            )
        }

        let sourcePixels = sourcePixelSize.width * sourcePixelSize.height
        let scale: CGFloat
        if let maximumPixelCount, sourcePixels > CGFloat(maximumPixelCount) {
            scale = sqrt(CGFloat(maximumPixelCount) / sourcePixels)
        } else {
            scale = 1
        }

        let outputSize = CGSize(
            width: max(1, floor(sourcePixelSize.width * scale)),
            height: max(1, floor(sourcePixelSize.height * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: outputSize))
        }
    }

    private static func applyColorAdjustments(
        to image: UIImage,
        contrast: ImageContrast,
        levels: ColorLevels
    ) throws -> UIImage {
        guard contrast.requiresProcessing || levels.isReduced else { return image }
        guard let inputImage = CIImage(image: image) else {
            throw PhotoProcessingError.renderFailed
        }

        var outputImage = CaptureImageKernels.applyingContrast(contrast, to: inputImage)
        if levels.isReduced {
            guard let kernel = CaptureImageKernels.rgbQuantize,
                  let quantized = kernel.apply(
                      extent: outputImage.extent,
                      arguments: [outputImage, Float(levels.rawValue)]
                  )
            else {
                throw PhotoProcessingError.renderFailed
            }
            outputImage = quantized
        }

        guard let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            throw PhotoProcessingError.renderFailed
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func nearestNeighborUpscale(
        _ image: UIImage,
        factor: Int
    ) throws -> UIImage {
        guard factor > 1 else { return image }
        guard image.cgImage != nil else { throw PhotoProcessingError.renderFailed }

        let outputSize = CGSize(
            width: image.size.width * CGFloat(factor),
            height: image.size.height * CGFloat(factor)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { renderer in
            renderer.cgContext.interpolationQuality = .none
            renderer.cgContext.setShouldAntialias(false)
            renderer.cgContext.setAllowsAntialiasing(false)
            image.draw(
                in: CGRect(origin: .zero, size: outputSize),
                blendMode: .copy,
                alpha: 1
            )
        }
    }
}
