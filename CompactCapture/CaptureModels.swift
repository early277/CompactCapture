import AVFoundation
import CoreGraphics
import Foundation

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case photo = "写真"
    case video = "動画"

    var id: Self { self }
    var title: String { L10n.string(rawValue) }
}

enum PhotoFileFormat: String, CaseIterable, Identifiable, Codable {
    case png = "PNG"
    case jpeg = "JPEG"
    case heif = "HEIF"

    var id: Self { self }
    var shortTitle: String { rawValue }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heif: "heic"
        }
    }
}

enum PhotoResolution: String, CaseIterable, Identifiable, Codable {
    case original = "最大"
    case twelveMP = "12 MP"
    case eightMP = "8 MP"
    case fourMP = "4 MP"
    case twoMP = "2 MP"
    case oneMP = "1 MP"
    case halfMP = "0.5 MP"
    case quarterMP = "0.25 MP"
    case tenthMP = "0.10 MP"
    case twentiethMP = "0.05 MP"
    case fortiethMP = "0.025 MP"

    var id: Self { self }
    var title: String { L10n.string(rawValue) }

    var shortTitle: String {
        switch self {
        case .original: L10n.string("最大")
        case .twelveMP: "12M"
        case .eightMP: "8M"
        case .fourMP: "4M"
        case .twoMP: "2M"
        case .oneMP: "1M"
        case .halfMP: "0.5M"
        case .quarterMP: "0.25M"
        case .tenthMP: "0.10M"
        case .twentiethMP: "0.05M"
        case .fortiethMP: "0.025M"
        }
    }

    var maximumPixelCount: Int? {
        switch self {
        case .original: nil
        case .twelveMP: 12_000_000
        case .eightMP: 8_000_000
        case .fourMP: 4_000_000
        case .twoMP: 2_000_000
        case .oneMP: 1_000_000
        case .halfMP: 500_000
        case .quarterMP: 250_000
        case .tenthMP: 100_000
        case .twentiethMP: 50_000
        case .fortiethMP: 25_000
        }
    }
}

enum ColorLevels: Int, CaseIterable, Identifiable, Codable {
    case full = 256
    case sixtyFour = 64
    case thirtyTwo = 32
    case sixteen = 16
    case eight = 8
    case four = 4

    var id: Self { self }

    var title: String {
        self == .full
            ? L10n.string("標準")
            : L10n.format("%d段階/色", rawValue)
    }

    var shortTitle: String {
        self == .full
            ? L10n.string("標準")
            : L10n.format("%d段", rawValue)
    }
    var isReduced: Bool { self != .full }
}

enum ImageContrast: Double, CaseIterable, Identifiable, Codable {
    case low = 0.70
    case slightlyLow = 0.85
    case standard = 1.00
    case slightlyHigh = 1.20
    case high = 1.40

    var id: Self { self }

    var shortTitle: String {
        switch self {
        case .low: L10n.string("低")
        case .slightlyLow: L10n.string("弱")
        case .standard: L10n.string("標準")
        case .slightlyHigh: L10n.string("強")
        case .high: L10n.string("高")
        }
    }

    var summaryTitle: String { shortTitle }
    var requiresProcessing: Bool { self != .standard }
}

enum PixelUpscaleFactor: Int, CaseIterable, Identifiable, Codable {
    case one = 1
    case two = 2
    case four = 4
    case eight = 8
    case sixteen = 16

    var id: Self { self }
    var title: String { "\(rawValue)×" }
}

enum VideoChromaMode: String, CaseIterable, Identifiable, Codable {
    case standard = "標準"
    case reduced = "解像感優先・弱"
    case strong = "解像感優先・強"
    case monochrome = "モノクロ"

    var id: Self { self }
    var requiresProcessing: Bool { self != .standard }

    var chromaQuantizationStep: Int {
        switch self {
        case .standard: 1
        case .reduced: 8
        case .strong: 32
        case .monochrome: 256
        }
    }

    var shortTitle: String {
        switch self {
        case .standard: L10n.string("色差標準")
        case .reduced: L10n.string("色差弱")
        case .strong: L10n.string("色差強")
        case .monochrome: L10n.string("モノクロ")
        }
    }

    var compactTitle: String {
        switch self {
        case .standard: L10n.string("標準")
        case .reduced: L10n.string("色差 弱")
        case .strong: L10n.string("色差 強")
        case .monochrome: L10n.string("白黒")
        }
    }

    var explanation: String {
        switch self {
        case .standard:
            L10n.string("色差情報を変更しません。")
        case .reduced:
            L10n.string("明るさはそのままに、色差の階調を控えめに整理します。")
        case .strong:
            L10n.string("明るさはそのままに、色差の階調を大きく整理します。色の縞が見える場合があります。")
        case .monochrome:
            L10n.string("明るさだけを残し、色差を中立値に固定します。")
        }
    }
}

enum VideoResolution: String, CaseIterable, Identifiable, Codable {
    case uhd = "4K"
    case fullHD = "1080p"
    case hd = "720p"
    case halfMP = "0.5 MP"
    case vga = "480p"
    case quarterMP = "0.25 MP"
    case low240 = "240p"
    case low180 = "180p"
    case pixel = "160×90"

    var id: Self { self }

    var shortTitle: String {
        switch self {
        case .pixel: "160×90"
        case .low180: "180p"
        case .low240: "240p"
        case .quarterMP: "0.25M"
        case .vga: "480p"
        case .halfMP: "0.5M"
        case .hd: "720p"
        case .fullHD: "1080p"
        case .uhd: "4K"
        }
    }

    var dimensions: CMVideoDimensions {
        switch self {
        case .pixel: CMVideoDimensions(width: 160, height: 90)
        case .low180: CMVideoDimensions(width: 320, height: 180)
        case .low240: CMVideoDimensions(width: 426, height: 240)
        case .quarterMP: CMVideoDimensions(width: 640, height: 360)
        case .vga: CMVideoDimensions(width: 640, height: 480)
        case .halfMP: CMVideoDimensions(width: 960, height: 540)
        case .hd: CMVideoDimensions(width: 1280, height: 720)
        case .fullHD: CMVideoDimensions(width: 1920, height: 1080)
        case .uhd: CMVideoDimensions(width: 3840, height: 2160)
        }
    }
}

enum VideoFrameRate: Int, CaseIterable, Identifiable, Codable {
    case five = 5
    case ten = 10
    case fifteen = 15
    case twentyFour = 24
    case thirty = 30

    var id: Self { self }
    var title: String { "\(rawValue) fps" }
}

enum VideoCodec: String, CaseIterable, Identifiable, Codable {
    case hevc = "HEVC (H.265)"
    case h264 = "H.264"
    case proRes4444 = "ProRes 4444"

    var id: Self { self }

    var avCodec: AVVideoCodecType {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        case .proRes4444: .proRes4444
        }
    }

    var shortTitle: String {
        switch self {
        case .hevc: "HEVC"
        case .h264: "H.264"
        case .proRes4444: "P4444"
        }
    }

    var supportsBitRateSelection: Bool { self != .proRes4444 }
    var requiresRGBProcessing: Bool { self == .proRes4444 }
}

enum VideoBitRate: Int, CaseIterable, Identifiable, Codable {
    case veryLow = 500_000
    case low = 1_000_000
    case medium = 2_500_000
    case high = 5_000_000
    case veryHigh = 10_000_000

    var id: Self { self }

    var title: String {
        let mbps = Double(rawValue) / 1_000_000
        return mbps == floor(mbps) ? "\(Int(mbps)) Mbps" : String(format: "%.1f Mbps", mbps)
    }

    var shortTitle: String {
        let mbps = Double(rawValue) / 1_000_000
        return mbps == floor(mbps) ? "\(Int(mbps))M" : String(format: "%.1fM", mbps)
    }
}

enum CameraControlAdjustmentStyle: String, CaseIterable, Identifiable, Codable {
    case stepped = "段階"
    case continuous = "連続"

    var id: Self { self }
    var title: String { L10n.string(rawValue) }

    var explanation: String {
        switch self {
        case .stepped:
            L10n.string("シャッターとISOは1/3段または1段、色温度は100 K、色かぶりは5ずつ変更します。")
        case .continuous:
            L10n.string("シャッターとISOは対数スライダー、ホワイトバランスは連続スライダーで変更します。")
        }
    }
}

enum WhiteBalanceControlMode: String, CaseIterable, Identifiable, Codable {
    case automatic = "自動"
    case manual = "手動"

    var id: Self { self }
    var title: String { L10n.string(rawValue) }
}

enum WhiteBalanceAdjustmentMode: String, CaseIterable, Identifiable, Codable {
    case preset = "プリセット"
    case temperature = "色温度"

    var id: Self { self }
    var title: String { L10n.string(rawValue) }
}

enum WhiteBalancePreset: String, CaseIterable, Identifiable, Codable {
    case automatic = "自動"
    case daylight = "晴天"
    case cloudy = "曇天"
    case shade = "日陰"
    case tungsten = "電球"
    case fluorescent = "蛍光灯"

    var id: Self { self }
    var title: String { L10n.string(rawValue) }

    var shortTitle: String {
        switch self {
        case .automatic: L10n.string("自動")
        case .daylight: L10n.string("晴天")
        case .cloudy: L10n.string("曇天")
        case .shade: L10n.string("日陰")
        case .tungsten: L10n.string("電球")
        case .fluorescent: L10n.string("蛍光")
        }
    }

    var temperature: Double? {
        switch self {
        case .automatic: nil
        case .daylight: 5_200
        case .cloudy: 6_000
        case .shade: 7_000
        case .tungsten: 3_200
        case .fluorescent: 4_000
        }
    }

    var tint: Double { 0 }
}

struct PhotoEncodingConfiguration {
    let format: PhotoFileFormat
    let resolution: PhotoResolution
    let colorLevels: ColorLevels
    let contrast: ImageContrast
    let lossyQuality: Double
    let pixelUpscaleFactor: PixelUpscaleFactor

    var appliedPixelUpscaleFactor: PixelUpscaleFactor {
        format == .png ? pixelUpscaleFactor : .one
    }

    func estimatedMegabytesPerPhoto(nativePixelCount: Int64) -> Double {
        let safeNativePixels = max(nativePixelCount, 1)
        let logicalPixels = resolution.maximumPixelCount
            .map { min(Int64($0), safeNativePixels) } ?? safeNativePixels
        let pixelCount = Double(max(logicalPixels, 1))

        let estimatedBytesPerPixel: Double
        switch format {
        case .png:
            let pngBytesPerPixel: Double
            switch colorLevels {
            case .full: pngBytesPerPixel = 2.50
            case .sixtyFour: pngBytesPerPixel = 2.10
            case .thirtyTwo: pngBytesPerPixel = 1.80
            case .sixteen: pngBytesPerPixel = 1.50
            case .eight: pngBytesPerPixel = 1.15
            case .four: pngBytesPerPixel = 0.85
            }
            // Integer nearest-neighbour enlargement repeats pixels, so PNG size
            // grows much more slowly than the output pixel count.
            let upscalePenalty = 1 + 0.18 * log2(Double(appliedPixelUpscaleFactor.rawValue))
            estimatedBytesPerPixel = pngBytesPerPixel * upscalePenalty

        case .jpeg, .heif:
            let quality = min(max(lossyQuality, 0), 1)
            let jpegBytesPerPixel = 0.08 + 0.87 * pow(quality, 4.5)
            let colorEntropyFactor: Double
            switch colorLevels {
            case .full: colorEntropyFactor = 1.00
            case .sixtyFour: colorEntropyFactor = 0.95
            case .thirtyTwo: colorEntropyFactor = 0.89
            case .sixteen: colorEntropyFactor = 0.80
            case .eight: colorEntropyFactor = 0.68
            case .four: colorEntropyFactor = 0.55
            }
            let formatFactor = format == .heif ? 0.62 : 1.00
            estimatedBytesPerPixel = jpegBytesPerPixel * colorEntropyFactor * formatFactor
        }

        // Metadata and container overhead matter for very small images.
        let estimatedBytes = max(8_000, pixelCount * estimatedBytesPerPixel + 6_000)
        return estimatedBytes / 1_000_000
    }
}

struct VideoRecordingConfiguration {
    let logicalDimensions: CMVideoDimensions
    let codec: VideoCodec
    let frameRate: VideoFrameRate
    let bitRate: VideoBitRate
    let colorLevels: ColorLevels
    let contrast: ImageContrast
    let chromaMode: VideoChromaMode
    let includeAudio: Bool
    let pixelUpscaleFactor: PixelUpscaleFactor

    var outputDimensions: CMVideoDimensions {
        logicalDimensions.scaled(by: pixelUpscaleFactor.rawValue)
    }

    var estimatedMegabytesPerMinute: Double {
        let videoBitsPerSecond: Double
        if codec == .proRes4444 {
            // Apple cites about 330 Mbps for 1920×1080 at 29.97 fps.
            let referencePixelsPerSecond = 1_920.0 * 1_080.0 * 29.97
            let outputPixelsPerSecond = Double(outputDimensions.pixelCount) * Double(frameRate.rawValue)
            videoBitsPerSecond = 330_000_000 * outputPixelsPerSecond / referencePixelsPerSecond
        } else {
            videoBitsPerSecond = Double(bitRate.rawValue)
        }
        let audioBitsPerSecond = includeAudio ? 128_000.0 : 0
        return (videoBitsPerSecond + audioBitsPerSecond) * 60 / 8 / 1_000_000
    }
}

struct PersistedCameraSettings: Codable {
    var captureMode: CaptureMode
    var photoFormat: PhotoFileFormat
    var photoResolution: PhotoResolution
    var photoLossyQuality: Double
    var videoResolution: VideoResolution
    var videoFrameRate: VideoFrameRate
    var videoCodec: VideoCodec
    var videoBitRate: VideoBitRate
    var colorLevels: ColorLevels
    var contrast: ImageContrast?
    var videoChromaMode: VideoChromaMode
    var includeAudio: Bool
    var pixelUpscaleFactor: PixelUpscaleFactor
    var saveToPhotoLibraryEnabled: Bool?
    var stabilizationEnabled: Bool
    var lensCorrectionEnabled: Bool
    var hdrEnabled: Bool
    var lowLightBoostEnabled: Bool
    var minimizeTextureProcessing: Bool
    var isShutterLocked: Bool
    var isISOLocked: Bool
    var shutterSeconds: Double
    var iso: Double
    var exposureBias: Double
    var cameraControlAdjustmentStyle: CameraControlAdjustmentStyle
    var whiteBalanceAdjustmentMode: WhiteBalanceAdjustmentMode
    var whiteBalancePreset: WhiteBalancePreset
    var whiteBalanceControlMode: WhiteBalanceControlMode
    var whiteBalanceTemperature: Double
    var whiteBalanceTint: Double
    var zoomFactor: Double?
}

struct CameraSettingsPreset: Identifiable, Codable {
    var id: UUID
    var name: String
    var settings: PersistedCameraSettings

    var summary: String {
        switch settings.captureMode {
        case .photo:
            L10n.format(
                "写真・%@・色 %@",
                settings.photoResolution.title,
                settings.colorLevels.title
            )
        case .video:
            L10n.format(
                "動画・%@・%@",
                settings.videoResolution.rawValue,
                settings.videoFrameRate.title
            )
        }
    }
}

enum CameraAuthorizationState: Equatable {
    case checking
    case ready
    case denied
    case unavailable
}

extension CMVideoDimensions {
    var pixelCount: Int64 { Int64(width) * Int64(height) }
    var size: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }

    func scaled(by factor: Int) -> CMVideoDimensions {
        CMVideoDimensions(
            width: width * Int32(factor),
            height: height * Int32(factor)
        )
    }
}
