import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import UIKit

private struct CameraLensOption {
    let device: AVCaptureDevice
    let nativeZoomFactor: Double
}

final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var authorizationState: CameraAuthorizationState = .checking
    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var microphoneAvailable = true
    @Published private(set) var availableVideoCodecs: [VideoCodec] = [.hevc, .h264]
    @Published private(set) var actualVideoFormatText = ""
    @Published private(set) var lastSavedFileSizeText = ""
    @Published private(set) var lastCapturedPhotoPreview: UIImage?
    @Published private(set) var lastCapturedPhotoInformation = ""
    @Published private(set) var livePreviewImage: CGImage?
    @Published private(set) var livePreviewDimensionsText = L10n.string("解像度を確認中…")
    @Published private(set) var zoomFactor = 1.0
    @Published private(set) var minimumZoomFactor = 1.0
    @Published private(set) var maximumZoomFactor = 1.0
    @Published private(set) var activeLensMinimumZoomFactor = 1.0
    @Published private(set) var activeLensMaximumZoomFactor = 1.0
    @Published private(set) var zoomQuickFactors: [Double] = [1.0]
    @Published private(set) var savedPresets: [CameraSettingsPreset] = []
    @Published var statusMessage = L10n.string("カメラを準備しています…")

    @Published var captureMode: CaptureMode = .photo {
        didSet {
            clampPixelUpscaleFactorIfNeeded()
            updateLivePreviewConfiguration()
            reconfigureForCaptureMode()
            settingsDidChange()
        }
    }

    @Published var photoFormat: PhotoFileFormat = .png {
        didSet {
            clampPixelUpscaleFactorIfNeeded()
            updateLivePreviewConfiguration()
            settingsDidChange()
        }
    }
    @Published var photoResolution: PhotoResolution = .fourMP {
        didSet {
            clampPixelUpscaleFactorIfNeeded()
            updateLivePreviewConfiguration()
            settingsDidChange()
        }
    }
    @Published var photoLossyQuality = 0.78 {
        didSet { settingsDidChange() }
    }

    @Published var videoResolution: VideoResolution = .hd {
        didSet {
            clampPixelUpscaleFactorIfNeeded()
            updateLivePreviewConfiguration()
            reconfigureVideoFormat()
            settingsDidChange()
        }
    }
    @Published var videoFrameRate: VideoFrameRate = .fifteen {
        didSet {
            reconfigureVideoFormat()
            settingsDidChange()
        }
    }
    @Published var videoCodec: VideoCodec = .hevc {
        didSet { settingsDidChange() }
    }
    @Published var videoBitRate: VideoBitRate = .low {
        didSet { settingsDidChange() }
    }
    @Published var colorLevels: ColorLevels = .full {
        didSet {
            updateLivePreviewConfiguration()
            settingsDidChange()
        }
    }
    @Published var contrast: ImageContrast = .standard {
        didSet {
            updateLivePreviewConfiguration()
            settingsDidChange()
        }
    }
    @Published var pixelUpscaleFactor: PixelUpscaleFactor = .one {
        didSet {
            updateLivePreviewConfiguration()
            settingsDidChange()
        }
    }
    @Published var videoChromaMode: VideoChromaMode = .standard {
        didSet {
            updateLivePreviewConfiguration()
            settingsDidChange()
        }
    }
    @Published var includeAudio = true {
        didSet { settingsDidChange() }
    }
    @Published var saveToPhotoLibraryEnabled = UserDefaults.standard.bool(
        forKey: "CompactCapture.saveToPhotoLibraryEnabled.v1"
    ) {
        didSet {
            UserDefaults.standard.set(
                saveToPhotoLibraryEnabled,
                forKey: "CompactCapture.saveToPhotoLibraryEnabled.v1"
            )
        }
    }

    @Published var resultPreviewEnabled = true {
        didSet {
            if !resultPreviewEnabled {
                livePreviewImage = nil
            }
            updateLivePreviewConfiguration()
        }
    }
    // Corrections are intentionally independent. Geometric/stabilizing corrections stay on by default.
    @Published var stabilizationEnabled = true {
        didSet {
            applyCorrectionPreferences()
            settingsDidChange()
        }
    }
    @Published var lensCorrectionEnabled = true {
        didSet {
            applyCorrectionPreferences()
            settingsDidChange()
        }
    }
    @Published var hdrEnabled = false {
        didSet {
            applyCorrectionPreferences()
            settingsDidChange()
        }
    }
    @Published var lowLightBoostEnabled = false {
        didSet {
            applyCorrectionPreferences()
            settingsDidChange()
        }
    }
    @Published var minimizeTextureProcessing = true {
        didSet { settingsDidChange() }
    }

    @Published private(set) var isShutterLocked = false {
        didSet {
            if isShutterLocked != oldValue {
                resetExposureAutomationTracking()
            }
            applyExposurePreferences()
            settingsDidChange()
        }
    }
    @Published private(set) var isISOLocked = false {
        didSet {
            if isISOLocked != oldValue {
                resetExposureAutomationTracking()
            }
            applyExposurePreferences()
            settingsDidChange()
        }
    }
    @Published var cameraControlAdjustmentStyle: CameraControlAdjustmentStyle = .stepped {
        didSet {
            if cameraControlAdjustmentStyle == .stepped {
                snapCameraControlsToSteps()
            }
            settingsDidChange()
        }
    }
    @Published var shutterSeconds = 1.0 / 60.0 {
        didSet {
            if isShutterLocked { applyExposurePreferences() }
            settingsDidChange()
        }
    }
    @Published var iso = 100.0 {
        didSet {
            if isISOLocked { applyExposurePreferences() }
            settingsDidChange()
        }
    }
    @Published var exposureBias = 0.0 {
        didSet {
            if exposureBiasIsEnabled { applyExposurePreferences() }
            settingsDidChange()
        }
    }
    @Published private(set) var measuredShutterSeconds = 1.0 / 60.0
    @Published private(set) var measuredISO = 100.0
    @Published private(set) var measuredExposureOffset = 0.0
    @Published private(set) var exposureAutomationStatus = L10n.string("露出自動")
    @Published private(set) var minimumShutterSeconds = 1.0 / 8_000.0
    @Published private(set) var maximumShutterSeconds = 1.0
    @Published private(set) var minimumISO = 25.0
    @Published private(set) var maximumISO = 2_000.0
    @Published private(set) var minimumExposureBias = -2.0
    @Published private(set) var maximumExposureBias = 2.0

    @Published var whiteBalanceAdjustmentMode: WhiteBalanceAdjustmentMode = .preset {
        didSet {
            applyWhiteBalanceSelection(
                seedFromAutomatic: whiteBalanceAdjustmentMode == .temperature
                    && oldValue != .temperature
            )
            settingsDidChange()
        }
    }
    @Published var whiteBalancePreset: WhiteBalancePreset = .automatic {
        didSet {
            guard whiteBalanceAdjustmentMode == .preset else { return }
            applyWhiteBalanceSelection(seedFromAutomatic: false)
            settingsDidChange()
        }
    }
    @Published var whiteBalanceControlMode: WhiteBalanceControlMode = .automatic {
        didSet {
            guard !isApplyingWhiteBalanceSelection else { return }
            if whiteBalanceControlMode == .manual, oldValue == .automatic {
                isSeedingWhiteBalance = true
                if cameraControlAdjustmentStyle == .stepped {
                    whiteBalanceTemperature = (measuredWhiteBalanceTemperature / 100).rounded() * 100
                    whiteBalanceTint = (measuredWhiteBalanceTint / 5).rounded() * 5
                } else {
                    whiteBalanceTemperature = measuredWhiteBalanceTemperature
                    whiteBalanceTint = measuredWhiteBalanceTint
                }
                isSeedingWhiteBalance = false
            }
            applyWhiteBalancePreferences()
            settingsDidChange()
        }
    }
    @Published var whiteBalanceTemperature = 5_000.0 {
        didSet {
            guard whiteBalanceControlMode == .manual, !isSeedingWhiteBalance else { return }
            applyWhiteBalancePreferences()
            settingsDidChange()
        }
    }
    @Published var whiteBalanceTint = 0.0 {
        didSet {
            guard whiteBalanceControlMode == .manual, !isSeedingWhiteBalance else { return }
            applyWhiteBalancePreferences()
            settingsDidChange()
        }
    }
    @Published private(set) var measuredWhiteBalanceTemperature = 5_000.0
    @Published private(set) var measuredWhiteBalanceTint = 0.0

    var estimatedVideoSizeText: String {
        let config = currentVideoConfiguration
        return L10n.format("約 %.1f MB/分", config.estimatedMegabytesPerMinute)
    }

    func estimatedPhotoChoiceSizeText(
        format: PhotoFileFormat? = nil,
        resolution: PhotoResolution? = nil,
        lossyQuality: Double? = nil,
        colorLevels: ColorLevels? = nil,
        upscaleFactor: PixelUpscaleFactor? = nil
    ) -> String {
        let configuration = PhotoEncodingConfiguration(
            format: format ?? photoFormat,
            resolution: resolution ?? photoResolution,
            colorLevels: colorLevels ?? self.colorLevels,
            contrast: contrast,
            lossyQuality: lossyQuality ?? photoLossyQuality,
            pixelUpscaleFactor: upscaleFactor ?? pixelUpscaleFactor
        )
        let configuredPixels = photoOutput.maxPhotoDimensions.pixelCount
        let nativePixels = configuredPixels > 0 ? configuredPixels : 12_000_000
        return Self.compactEstimatedSize(
            megabytes: configuration.estimatedMegabytesPerPhoto(
                nativePixelCount: nativePixels
            )
        )
    }

    func estimatedVideoChoiceSizeText(
        bitRate: VideoBitRate? = nil,
        includeAudio: Bool? = nil
    ) -> String {
        let configuration = VideoRecordingConfiguration(
            logicalDimensions: videoResolution.dimensions,
            codec: videoCodec,
            frameRate: videoFrameRate,
            bitRate: bitRate ?? videoBitRate,
            colorLevels: colorLevels,
            contrast: contrast,
            chromaMode: videoChromaMode,
            includeAudio: includeAudio ?? (self.includeAudio && microphoneAvailable),
            pixelUpscaleFactor: pixelUpscaleFactor
        )
        return Self.compactEstimatedSize(
            megabytes: configuration.estimatedMegabytesPerMinute
        )
    }

    var livePreviewSummaryText: String {
        switch captureMode {
        case .photo:
            return L10n.format(
                "保存 %@・色 %@・コントラスト %@",
                livePreviewDimensionsText,
                colorLevels.title,
                contrast.summaryTitle
            )
        case .video:
            return L10n.format(
                "保存 %@・%@・色 %@・コントラスト %@",
                livePreviewDimensionsText,
                videoFrameRate.title,
                colorLevels.title,
                contrast.summaryTitle
            )
        }
    }

    var zoomFactorText: String {
        Self.formatZoomFactor(zoomFactor)
    }

    var zoomIsAvailable: Bool {
        maximumZoomFactor > minimumZoomFactor * 1.01
    }

    func zoomButtonIsSelected(_ factor: Double) -> Bool {
        abs(log(max(zoomFactor, 0.01) / max(factor, 0.01))) < 0.045
    }

    func zoomFactorIsSelectable(_ factor: Double) -> Bool {
        guard isRecording else { return true }
        return factor >= activeLensMinimumZoomFactor * 0.999
            && factor <= activeLensMaximumZoomFactor * 1.001
    }

    func setZoomFactor(_ factor: Double, smoothly: Bool = false) {
        let range = zoomControlRange
        let clamped = min(max(factor, range.lowerBound), range.upperBound)
        zoomFactor = clamped
        settingsDidChange()
        scheduleZoomApplication(smoothly: smoothly)
    }

    var exposureBiasIsEnabled: Bool { !(isShutterLocked && isISOLocked) }

    func isPixelUpscaleFactorSupported(_ factor: PixelUpscaleFactor) -> Bool {
        switch captureMode {
        case .photo:
            guard photoFormat == .png else { return true }
            guard let logicalPixels = photoResolution.maximumPixelCount else {
                return factor == .one
            }
            let outputPixels = Int64(logicalPixels) * Int64(factor.rawValue * factor.rawValue)
            return outputPixels <= 48_000_000

        case .video:
            let output = videoResolution.dimensions.scaled(by: factor.rawValue)
            return output.width <= 4_096
                && output.height <= 4_096
                && output.pixelCount <= 8_847_360
        }
    }

    var shutterStepValues: [Double] {
        Self.filteredSteps(
            Self.standardShutterSteps,
            minimum: minimumShutterSeconds,
            maximum: maximumShutterSeconds
        )
    }

    var isoStepValues: [Double] {
        Self.filteredSteps(
            Self.standardISOSteps,
            minimum: minimumISO,
            maximum: maximumISO
        )
    }

    private let sessionQueue = DispatchQueue(label: "CompactCapture.session")
    private let outputQueue = DispatchQueue(label: "CompactCapture.output")
    private let processingQueue = DispatchQueue(label: "CompactCapture.photoProcessing", qos: .userInitiated)

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let videoRecorder = VideoRecorder()
    private let recordingCuePlayer = RecordingCuePlayer()
    private let livePreviewProcessor = LivePreviewProcessor()

    private var videoDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var livePreviewRotationAngle: CGFloat = 90
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var cameraLensOptions: [CameraLensOption] = []
    private var currentLensNativeZoomFactor = 1.0
    private var permissionRequestInFlight = false
    private var sessionConfigurationInProgress = false
    private var sessionIsConfigured = false
    private var sessionShouldRun = true
    private var pendingPhotoConfiguration: PhotoEncodingConfiguration?
    private var exposureMonitorTimer: DispatchSourceTimer?
    private var pendingExposureWorkItem: DispatchWorkItem?
    private var pendingWhiteBalanceWorkItem: DispatchWorkItem?
    private var pendingSettingsSaveWorkItem: DispatchWorkItem?
    private var pendingZoomWorkItem: DispatchWorkItem?
    private var pendingRecordingStartWorkItem: DispatchWorkItem?
    private var isWaitingForRecordingStartCue = false
    private var smoothedExposureOffset = 0.0
    private var exposureAutomationUpdateInFlight = false
    private var isSeedingWhiteBalance = false
    private var isApplyingWhiteBalanceSelection = false
    private var isRestoringSettings = false

    private static let persistedSettingsKey = "CompactCapture.cameraSettings.v2"
    private static let savedPresetsKey = "CompactCapture.cameraPresets.v1"
    private static let whiteBalanceTemperatureRange = 2_500.0...10_000.0
    private static let whiteBalanceTintRange = -150.0...150.0

    private var currentPhotoConfiguration: PhotoEncodingConfiguration {
        PhotoEncodingConfiguration(
            format: photoFormat,
            resolution: photoResolution,
            colorLevels: colorLevels,
            contrast: contrast,
            lossyQuality: photoLossyQuality,
            pixelUpscaleFactor: pixelUpscaleFactor
        )
    }

    private var currentVideoConfiguration: VideoRecordingConfiguration {
        VideoRecordingConfiguration(
            logicalDimensions: videoResolution.dimensions,
            codec: videoCodec,
            frameRate: videoFrameRate,
            bitRate: videoBitRate,
            colorLevels: colorLevels,
            contrast: contrast,
            chromaMode: videoChromaMode,
            includeAudio: includeAudio && microphoneAvailable,
            pixelUpscaleFactor: pixelUpscaleFactor
        )
    }

    private var zoomControlRange: ClosedRange<Double> {
        if isRecording {
            let lower = min(activeLensMinimumZoomFactor, activeLensMaximumZoomFactor)
            let upper = max(activeLensMinimumZoomFactor, activeLensMaximumZoomFactor)
            return lower...upper
        }
        let lower = min(minimumZoomFactor, maximumZoomFactor)
        let upper = max(minimumZoomFactor, maximumZoomFactor)
        return lower...upper
    }

    override init() {
        super.init()
        restorePersistedSettings()
        restoreSavedPresets()
        livePreviewProcessor.onFrame = { [weak self] frame in
            DispatchQueue.main.async {
                guard let self, self.resultPreviewEnabled else { return }
                self.livePreviewImage = frame.image
                self.livePreviewDimensionsText = frame.pixelDimensionsText
            }
        }
        updateLivePreviewConfiguration()
    }

    deinit {
        pendingExposureWorkItem?.cancel()
        pendingWhiteBalanceWorkItem?.cancel()
        pendingSettingsSaveWorkItem?.cancel()
        pendingZoomWorkItem?.cancel()
        pendingRecordingStartWorkItem?.cancel()
        exposureMonitorTimer?.cancel()
        recordingCuePlayer.cancel()
    }

    func start() {
        if isConfigured {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.sessionShouldRun = true
                guard self.sessionIsConfigured,
                      !self.session.isRunning
                else { return }
                self.resetExposureAutomationTrackingOnSessionQueue()
                self.session.startRunning()
            }
            return
        }
        guard !permissionRequestInFlight else { return }
        permissionRequestInFlight = true
        requestCameraPermission()
    }

    func stopSession() {
        cancelPendingRecordingStartCue()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.sessionShouldRun = false
            guard self.session.isRunning, !self.isRecording else { return }
            self.session.stopRunning()
        }
    }

    func enterSettings() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.sessionShouldRun = true
            if self.sessionIsConfigured, !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                self.statusMessage = L10n.string("設定中もライブ表示しています。")
            }
        }
    }

    func leaveSettings() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.sessionShouldRun = true
            guard self.sessionIsConfigured else { return }
            self.livePreviewProcessor.beginCaptureReconfiguration()
            self.applyCaptureFormatOnSessionQueue()
            self.updateOutputOrientation()
            self.livePreviewProcessor.endCaptureReconfiguration()
            self.resetExposureAutomationTrackingOnSessionQueue()
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                self.statusMessage = self.microphoneAvailable
                    ? L10n.string("撮影できます。")
                    : L10n.string("撮影できます（動画は音声なし）。")
            }
        }
    }

    func performCapture() {
        switch captureMode {
        case .photo:
            capturePhoto()
        case .video:
            toggleRecording()
        }
    }

    func setLivePreviewRotationAngle(_ angle: CGFloat) {
        let normalized = Self.normalizedRotationAngle(angle)
        guard normalized != livePreviewRotationAngle else { return }
        livePreviewRotationAngle = normalized
        updateLivePreviewConfiguration()
    }

    func toggleShutterLock() {
        if isShutterLocked {
            isShutterLocked = false
        } else {
            let seeded = min(
                max(measuredShutterSeconds, minimumShutterSeconds),
                maximumShutterSeconds
            )
            shutterSeconds = cameraControlAdjustmentStyle == .stepped
                ? Self.nearestStep(to: seeded, in: shutterStepValues)
                : seeded
            isShutterLocked = true
        }
    }

    func toggleISOLock() {
        if isISOLocked {
            isISOLocked = false
        } else {
            let seeded = min(max(measuredISO, minimumISO), maximumISO)
            iso = cameraControlAdjustmentStyle == .stepped
                ? Self.nearestStep(to: seeded, in: isoStepValues)
                : seeded
            isISOLocked = true
        }
    }

    func saveSettingsNow() {
        pendingSettingsSaveWorkItem?.cancel()
        persistSettings()
    }

    @discardableResult
    func savePreset(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }

        let settings = makePersistedSettings()
        if let index = savedPresets.firstIndex(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            savedPresets[index].name = name
            savedPresets[index].settings = settings
        } else {
            savedPresets.append(
                CameraSettingsPreset(id: UUID(), name: name, settings: settings)
            )
        }
        savedPresets.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        persistSavedPresets()
        statusMessage = L10n.format("プリセット「%@」を保存しました。", name)
        return true
    }

    func applyPreset(_ preset: CameraSettingsPreset) {
        applyPersistedSettings(preset.settings, applyZoomImmediately: true)
        persistSettings()
        statusMessage = L10n.format("プリセット「%@」を適用しました。", preset.name)
    }

    func deletePreset(id: UUID) {
        savedPresets.removeAll { $0.id == id }
        persistSavedPresets()
    }

    private func clampPixelUpscaleFactorIfNeeded() {
        guard !isRestoringSettings,
              !isPixelUpscaleFactorSupported(pixelUpscaleFactor)
        else { return }
        pixelUpscaleFactor = PixelUpscaleFactor.allCases.last(where: {
            isPixelUpscaleFactorSupported($0)
        }) ?? .one
    }

    private func settingsDidChange() {
        guard !isRestoringSettings else { return }
        pendingSettingsSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistSettings()
        }
        pendingSettingsSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180), execute: workItem)
    }

    private func persistSettings() {
        guard !isRestoringSettings else { return }
        guard let data = try? JSONEncoder().encode(makePersistedSettings()) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistedSettingsKey)
    }

    private func makePersistedSettings() -> PersistedCameraSettings {
        PersistedCameraSettings(
            captureMode: captureMode,
            photoFormat: photoFormat,
            photoResolution: photoResolution,
            photoLossyQuality: photoLossyQuality,
            videoResolution: videoResolution,
            videoFrameRate: videoFrameRate,
            videoCodec: videoCodec,
            videoBitRate: videoBitRate,
            colorLevels: colorLevels,
            contrast: contrast,
            videoChromaMode: videoChromaMode,
            includeAudio: includeAudio,
            pixelUpscaleFactor: pixelUpscaleFactor,
            saveToPhotoLibraryEnabled: saveToPhotoLibraryEnabled,
            stabilizationEnabled: stabilizationEnabled,
            lensCorrectionEnabled: lensCorrectionEnabled,
            hdrEnabled: hdrEnabled,
            lowLightBoostEnabled: lowLightBoostEnabled,
            minimizeTextureProcessing: minimizeTextureProcessing,
            isShutterLocked: isShutterLocked,
            isISOLocked: isISOLocked,
            shutterSeconds: shutterSeconds,
            iso: iso,
            exposureBias: exposureBias,
            cameraControlAdjustmentStyle: cameraControlAdjustmentStyle,
            whiteBalanceAdjustmentMode: whiteBalanceAdjustmentMode,
            whiteBalancePreset: whiteBalancePreset,
            whiteBalanceControlMode: whiteBalanceControlMode,
            whiteBalanceTemperature: whiteBalanceTemperature,
            whiteBalanceTint: whiteBalanceTint,
            zoomFactor: zoomFactor
        )
    }

    private func restorePersistedSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedSettingsKey),
              let settings = try? JSONDecoder().decode(PersistedCameraSettings.self, from: data)
        else { return }

        applyPersistedSettings(settings, applyZoomImmediately: false)
    }

    private func applyPersistedSettings(
        _ settings: PersistedCameraSettings,
        applyZoomImmediately: Bool
    ) {
        isRestoringSettings = true
        captureMode = settings.captureMode
        photoFormat = settings.photoFormat
        photoResolution = settings.photoResolution
        photoLossyQuality = settings.photoLossyQuality
        videoResolution = settings.videoResolution
        videoFrameRate = settings.videoFrameRate
        videoCodec = settings.videoCodec
        videoBitRate = settings.videoBitRate
        colorLevels = settings.colorLevels
        contrast = settings.contrast ?? .standard
        videoChromaMode = settings.videoChromaMode
        includeAudio = settings.includeAudio
        pixelUpscaleFactor = settings.pixelUpscaleFactor
        if let savedPhotoLibraryPreference = settings.saveToPhotoLibraryEnabled {
            saveToPhotoLibraryEnabled = savedPhotoLibraryPreference
        }
        stabilizationEnabled = settings.stabilizationEnabled
        lensCorrectionEnabled = settings.lensCorrectionEnabled
        hdrEnabled = settings.hdrEnabled
        lowLightBoostEnabled = settings.lowLightBoostEnabled
        minimizeTextureProcessing = settings.minimizeTextureProcessing
        shutterSeconds = settings.shutterSeconds
        iso = settings.iso
        exposureBias = settings.exposureBias
        cameraControlAdjustmentStyle = settings.cameraControlAdjustmentStyle
        whiteBalanceAdjustmentMode = settings.whiteBalanceAdjustmentMode
        whiteBalancePreset = settings.whiteBalancePreset
        whiteBalanceControlMode = settings.whiteBalanceControlMode
        let restoredTemperature = settings.whiteBalanceTemperature.isFinite
            ? settings.whiteBalanceTemperature
            : 5_000
        let restoredTint = settings.whiteBalanceTint.isFinite
            ? settings.whiteBalanceTint
            : 0
        whiteBalanceTemperature = min(
            max(restoredTemperature, Self.whiteBalanceTemperatureRange.lowerBound),
            Self.whiteBalanceTemperatureRange.upperBound
        )
        whiteBalanceTint = min(
            max(restoredTint, Self.whiteBalanceTintRange.lowerBound),
            Self.whiteBalanceTintRange.upperBound
        )
        zoomFactor = max(settings.zoomFactor ?? 1.0, 0.1)
        isShutterLocked = settings.isShutterLocked
        isISOLocked = settings.isISOLocked
        isRestoringSettings = false
        clampPixelUpscaleFactorIfNeeded()
        updateLivePreviewConfiguration()
        if applyZoomImmediately {
            setZoomFactor(settings.zoomFactor ?? 1.0, smoothly: false)
        }
    }

    private func restoreSavedPresets() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedPresetsKey),
              let presets = try? JSONDecoder().decode([CameraSettingsPreset].self, from: data)
        else { return }
        savedPresets = presets.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func persistSavedPresets() {
        guard let data = try? JSONEncoder().encode(savedPresets) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedPresetsKey)
    }

    private func resetExposureAutomationTracking() {
        sessionQueue.async { [weak self] in
            self?.resetExposureAutomationTrackingOnSessionQueue()
        }
    }

    func formatShutter(_ seconds: Double) -> String {
        if seconds >= 1 {
            if abs(seconds.rounded() - seconds) < 0.05 {
                return L10n.format("%d秒", Int(seconds.rounded()))
            }
            return L10n.format("%.1f秒", seconds)
        }
        if seconds >= 0.3 {
            return L10n.format("%.1f秒", seconds)
        }
        let denominator = max(1, Int((1 / seconds).rounded()))
        return L10n.format("1/%d秒", denominator)
    }

    private static let standardShutterSteps: [Double] = [
        1.0 / 32_000, 1.0 / 25_000, 1.0 / 20_000,
        1.0 / 16_000, 1.0 / 12_500, 1.0 / 10_000,
        1.0 / 8_000, 1.0 / 6_400, 1.0 / 5_000,
        1.0 / 4_000, 1.0 / 3_200, 1.0 / 2_500,
        1.0 / 2_000, 1.0 / 1_600, 1.0 / 1_250,
        1.0 / 1_000, 1.0 / 800, 1.0 / 640,
        1.0 / 500, 1.0 / 400, 1.0 / 320,
        1.0 / 250, 1.0 / 200, 1.0 / 160,
        1.0 / 125, 1.0 / 100, 1.0 / 80,
        1.0 / 60, 1.0 / 50, 1.0 / 40,
        1.0 / 30, 1.0 / 25, 1.0 / 20,
        1.0 / 15, 1.0 / 13, 1.0 / 10,
        1.0 / 8, 1.0 / 6, 1.0 / 5,
        1.0 / 4, 1.0 / 3, 1.0 / 2.5,
        1.0 / 2, 1.0 / 1.6, 1.0 / 1.3,
        1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30
    ]

    private static let standardISOSteps: [Double] = [
        12, 16, 20, 25, 32, 40, 50, 64, 80,
        100, 125, 160, 200, 250, 320, 400, 500,
        640, 800, 1_000, 1_250, 1_600, 2_000,
        2_500, 3_200, 4_000, 5_000, 6_400,
        8_000, 10_000, 12_800, 16_000, 20_000,
        25_600, 32_000, 40_000, 51_200
    ]

    private static func filteredSteps(
        _ standardValues: [Double],
        minimum: Double,
        maximum: Double
    ) -> [Double] {
        let lower = min(minimum, maximum)
        let upper = max(minimum, maximum)
        guard lower > 0, upper > 0 else { return [lower] }

        var result = standardValues.filter {
            $0 >= lower * 0.999 && $0 <= upper * 1.001
        }
        if result.isEmpty {
            return lower == upper ? [lower] : [lower, upper]
        }
        if let first = result.first, abs(first - lower) / lower > 0.01 {
            result.insert(lower, at: 0)
        }
        if let last = result.last, abs(upper - last) / upper > 0.01 {
            result.append(upper)
        }
        return result
    }

    private func snapCameraControlsToSteps() {
        shutterSeconds = Self.nearestStep(to: shutterSeconds, in: shutterStepValues)
        iso = Self.nearestStep(to: iso, in: isoStepValues)
        whiteBalanceTemperature = min(
            max((whiteBalanceTemperature / 100).rounded() * 100, 2_500),
            10_000
        )
        whiteBalanceTint = min(max((whiteBalanceTint / 5).rounded() * 5, -150), 150)
    }

    private static func nearestStep(to value: Double, in values: [Double]) -> Double {
        guard let closest = values.min(by: { left, right in
            let leftDistance = abs(log2(max(left, 0.000_001) / max(value, 0.000_001)))
            let rightDistance = abs(log2(max(right, 0.000_001) / max(value, 0.000_001)))
            return leftDistance < rightDistance
        }) else {
            return value
        }
        return closest
    }

    private func updateLivePreviewConfiguration() {
        livePreviewProcessor.update(
            configuration: LivePreviewConfiguration(
                isEnabled: resultPreviewEnabled,
                rotationAngle: livePreviewRotationAngle,
                captureMode: captureMode,
                photoFormat: photoFormat,
                photoResolution: photoResolution,
                videoResolution: videoResolution,
                colorLevels: colorLevels,
                contrast: contrast,
                videoChromaMode: videoChromaMode,
                pixelUpscaleFactor: pixelUpscaleFactor
            )
        )
    }

    private func requestCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            requestMicrophoneThenConfigure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.requestMicrophoneThenConfigure()
                } else {
                    self.publishAuthorization(
                        .denied,
                        message: L10n.string("設定でカメラへのアクセスを許可してください。")
                    )
                }
            }
        case .denied, .restricted:
            publishAuthorization(
                .denied,
                message: L10n.string("設定でカメラへのアクセスを許可してください。")
            )
        @unknown default:
            publishAuthorization(.unavailable, message: L10n.string("カメラを利用できません。"))
        }
    }

    private func requestMicrophoneThenConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configureSession(microphoneAllowed: true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                self?.configureSession(microphoneAllowed: granted)
            }
        case .denied, .restricted:
            configureSession(microphoneAllowed: false)
        @unknown default:
            configureSession(microphoneAllowed: false)
        }
    }

    private func configureSession(microphoneAllowed: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.microphoneAvailable = microphoneAllowed
            if !microphoneAllowed {
                self?.includeAudio = false
            }
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard !self.sessionConfigurationInProgress, !self.sessionIsConfigured else { return }
            self.sessionConfigurationInProgress = true

            var configurationSucceeded = false
            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority
            defer {
                self.session.commitConfiguration()
                self.sessionConfigurationInProgress = false
                if configurationSucceeded {
                    self.sessionIsConfigured = true
                    self.applyCaptureFormatOnSessionQueue()
                    if self.sessionShouldRun {
                        self.session.startRunning()
                    }
                    self.updateAvailableVideoCodecsOnSessionQueue()
                    self.startExposureMonitoringOnSessionQueue()
                    DispatchQueue.main.async {
                        self.permissionRequestInFlight = false
                        self.authorizationState = .ready
                        self.isConfigured = true
                        self.statusMessage = microphoneAllowed
                            ? L10n.string("撮影できます。")
                            : L10n.string("撮影できます（動画は音声なし）。")
                    }
                }
            }

            self.cameraLensOptions = Self.discoverBackCameraLenses()
            guard let initialLens = self.preferredLensOption(for: self.zoomFactor)
                ?? self.cameraLensOptions.first
            else {
                self.publishAuthorization(
                    .unavailable,
                    message: L10n.string("背面カメラが見つかりません。")
                )
                return
            }
            let device = initialLens.device

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    self.publishAuthorization(
                        .unavailable,
                        message: L10n.string("カメラ入力を追加できません。")
                    )
                    return
                }
                self.session.addInput(input)
                self.videoDevice = device
                self.videoInput = input
                self.currentLensNativeZoomFactor = initialLens.nativeZoomFactor
                self.installRotationCoordinator(for: device)
            } catch {
                self.publishAuthorization(.unavailable, message: error.localizedDescription)
                return
            }

            if microphoneAllowed,
               let microphone = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: microphone),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                self.audioInput = input
            }

            guard self.session.canAddOutput(self.photoOutput) else {
                self.publishAuthorization(
                    .unavailable,
                    message: L10n.string("写真出力を追加できません。")
                )
                return
            }
            self.session.addOutput(self.photoOutput)
            self.photoOutput.maxPhotoQualityPrioritization = .balanced

            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            guard self.session.canAddOutput(self.videoOutput) else {
                self.publishAuthorization(
                    .unavailable,
                    message: L10n.string("動画出力を追加できません。")
                )
                return
            }
            self.session.addOutput(self.videoOutput)
            self.videoOutput.setSampleBufferDelegate(self, queue: self.outputQueue)

            if microphoneAllowed, self.session.canAddOutput(self.audioOutput) {
                self.session.addOutput(self.audioOutput)
                self.audioOutput.setSampleBufferDelegate(self, queue: self.outputQueue)
            }

            self.updateOutputOrientation()

            configurationSucceeded = true
        }
    }

    private func updateOutputOrientation() {
        // Keep data-output buffers in the camera sensor's native orientation.
        // Preview rendering normalizes them separately, while each saved photo/video
        // receives the device's physical orientation at capture time.
        if let videoConnection = videoOutput.connection(with: .video),
           videoConnection.isVideoRotationAngleSupported(0) {
            videoConnection.videoRotationAngle = 0
        }
        if let photoConnection = photoOutput.connection(with: .video),
           photoConnection.isVideoRotationAngleSupported(90) {
            photoConnection.videoRotationAngle = 90
        }
    }

    private func installRotationCoordinator(for device: AVCaptureDevice) {
        DispatchQueue.main.async { [weak self] in
            self?.rotationCoordinator = AVCaptureDevice.RotationCoordinator(
                device: device,
                previewLayer: nil
            )
        }
    }

    private var captureRotationAngle: CGFloat {
        let reported = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        return Self.normalizedRotationAngle(reported)
    }

    private static func normalizedRotationAngle(_ angle: CGFloat) -> CGFloat {
        let positive = (angle.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let quadrant = Int((positive / 90).rounded()) % 4
        return CGFloat(quadrant * 90)
    }

    private func updateAvailableVideoCodecsOnSessionQueue() {
        let writerCodecs = videoOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
        var codecs: [VideoCodec] = []
        if writerCodecs.contains(.hevc) {
            codecs.append(.hevc)
        }
        if writerCodecs.contains(.h264) {
            codecs.append(.h264)
        }
        if writerCodecs.contains(.proRes4444) {
            codecs.append(.proRes4444)
        }
        if codecs.isEmpty {
            codecs = [.h264]
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.availableVideoCodecs = codecs
            if !codecs.contains(self.videoCodec) {
                self.videoCodec = codecs.first ?? .h264
            }
        }
    }

    private static func discoverBackCameraLenses() -> [CameraLensOption] {
        guard let wide = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else { return [] }

        var options: [CameraLensOption] = []
        if let ultraWide = AVCaptureDevice.default(
            .builtInUltraWideCamera,
            for: .video,
            position: .back
        ) {
            options.append(CameraLensOption(device: ultraWide, nativeZoomFactor: 0.5))
        }
        options.append(CameraLensOption(device: wide, nativeZoomFactor: 1.0))

        if let telephoto = AVCaptureDevice.default(
            .builtInTelephotoCamera,
            for: .video,
            position: .back
        ) {
            let wideFOV = Double(wide.activeFormat.videoFieldOfView)
            let telephotoFOV = Double(telephoto.activeFormat.videoFieldOfView)
            let estimatedFactor: Double
            if wideFOV > 0, telephotoFOV > 0, telephotoFOV < wideFOV {
                estimatedFactor = tan(wideFOV * .pi / 360)
                    / tan(telephotoFOV * .pi / 360)
            } else {
                estimatedFactor = 3.0
            }
            let familiarFactors = [2.0, 2.5, 3.0, 5.0]
            let nativeFactor = familiarFactors.min(by: {
                abs(log($0 / estimatedFactor)) < abs(log($1 / estimatedFactor))
            }) ?? 3.0
            options.append(
                CameraLensOption(device: telephoto, nativeZoomFactor: nativeFactor)
            )
        }

        return options.sorted { $0.nativeZoomFactor < $1.nativeZoomFactor }
    }

    private func preferredLensOption(for displayFactor: Double) -> CameraLensOption? {
        let target = max(displayFactor, 0.01)
        return cameraLensOptions.last(where: {
            $0.nativeZoomFactor <= target * 1.001
        }) ?? cameraLensOptions.first
    }

    private func scheduleZoomApplication(smoothly: Bool) {
        guard isConfigured else { return }
        pendingZoomWorkItem?.cancel()
        let target = zoomFactor
        let workItem = DispatchWorkItem { [weak self] in
            self?.applyDisplayedZoomOnSessionQueue(target, smoothly: smoothly)
        }
        pendingZoomWorkItem = workItem
        sessionQueue.asyncAfter(
            deadline: .now() + (smoothly ? .milliseconds(0) : .milliseconds(12)),
            execute: workItem
        )
    }

    private func applyDisplayedZoomOnSessionQueue(
        _ requestedDisplayFactor: Double,
        smoothly: Bool
    ) {
        guard let currentDevice = videoDevice else { return }

        var selectedLens = preferredLensOptionForLiveZoom(
            requestedDisplayFactor,
            currentDevice: currentDevice
        )
        if isRecording {
            selectedLens = cameraLensOptions.first(where: {
                $0.device.uniqueID == currentDevice.uniqueID
            })
        }

        if let selectedLens,
           selectedLens.device.uniqueID != currentDevice.uniqueID {
            livePreviewProcessor.beginCaptureReconfiguration()
            if switchCameraLensOnSessionQueue(to: selectedLens) {
                applyCaptureFormatOnSessionQueue()
                updateOutputOrientation()
                updateAvailableVideoCodecsOnSessionQueue()
            }
            livePreviewProcessor.endCaptureReconfiguration()
        }

        applyZoomToCurrentLensOnSessionQueue(
            requestedDisplayFactor,
            smoothly: smoothly
        )
    }

    private func switchCameraLensOnSessionQueue(to option: CameraLensOption) -> Bool {
        guard !isRecording,
              let oldInput = videoInput,
              option.device.uniqueID != oldInput.device.uniqueID,
              let newInput = try? AVCaptureDeviceInput(device: option.device)
        else { return false }

        var switched = false
        session.beginConfiguration()
        session.removeInput(oldInput)
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            switched = true
        } else if session.canAddInput(oldInput) {
            session.addInput(oldInput)
        }
        session.commitConfiguration()

        guard switched else {
            publishStatus(L10n.string("この倍率ではカメラを切り替えられませんでした。"))
            return false
        }

        videoInput = newInput
        videoDevice = option.device
        currentLensNativeZoomFactor = option.nativeZoomFactor
        installRotationCoordinator(for: option.device)
        return true
    }

    private func preferredLensOptionForLiveZoom(
        _ displayFactor: Double,
        currentDevice: AVCaptureDevice
    ) -> CameraLensOption? {
        guard let currentOption = cameraLensOptions.first(where: {
            $0.device.uniqueID == currentDevice.uniqueID
        }) else {
            return preferredLensOption(for: displayFactor)
        }

        let target = max(displayFactor, 0.01)
        if target >= currentOption.nativeZoomFactor {
            let nextLens = cameraLensOptions.first(where: {
                $0.nativeZoomFactor > currentOption.nativeZoomFactor
            })
            if let nextLens, target >= nextLens.nativeZoomFactor * 0.95 {
                return preferredLensOption(for: target)
            }
        } else if target < currentOption.nativeZoomFactor * 0.80 {
            return preferredLensOption(for: target)
        }
        return currentOption
    }

    private func refreshZoomCapabilitiesOnSessionQueue() {
        guard let device = videoDevice else { return }

        let globalMinimum = cameraLensOptions.map(\.nativeZoomFactor).min() ?? 1.0
        let uncappedGlobalMaximum = cameraLensOptions.map { option in
            let formatMaximum = Double(option.device.activeFormat.videoMaxZoomFactor)
            let deviceMaximum = option.device.uniqueID == device.uniqueID
                ? min(formatMaximum, Double(option.device.maxAvailableVideoZoomFactor))
                : formatMaximum
            return option.nativeZoomFactor * max(deviceMaximum, 1.0)
        }.max() ?? 1.0
        let globalMaximum = max(globalMinimum, min(uncappedGlobalMaximum, 15.0))

        let lensMinimum = max(
            globalMinimum,
            currentLensNativeZoomFactor * Double(device.minAvailableVideoZoomFactor)
        )
        let lensMaximum = max(
            lensMinimum,
            min(
                globalMaximum,
                currentLensNativeZoomFactor * Double(device.maxAvailableVideoZoomFactor)
            )
        )

        var quickFactors = Self.representativeZoomFactors
        quickFactors.append(globalMinimum)
        quickFactors.append(globalMaximum)
        quickFactors.append(contentsOf: cameraLensOptions.map(\.nativeZoomFactor))
        quickFactors = quickFactors
            .filter { $0 >= globalMinimum * 0.999 && $0 <= globalMaximum * 1.001 }
            .sorted()
            .reduce(into: [Double]()) { result, factor in
                if let last = result.last,
                   abs(log(max(last, 0.01) / max(factor, 0.01))) < 0.04 {
                    return
                }
                result.append(factor)
            }
        if quickFactors.count > 7 {
            let requiredFactors = [globalMinimum, globalMaximum]
                + cameraLensOptions.map(\.nativeZoomFactor)
            var compactFactors: [Double] = []
            for factor in requiredFactors + Self.representativeZoomFactors {
                guard factor >= globalMinimum * 0.999,
                      factor <= globalMaximum * 1.001,
                      compactFactors.count < 7,
                      !compactFactors.contains(where: {
                          abs(log(max($0, 0.01) / max(factor, 0.01))) < 0.04
                      })
                else { continue }
                compactFactors.append(factor)
            }
            quickFactors = compactFactors.sorted()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.minimumZoomFactor = globalMinimum
            self.maximumZoomFactor = globalMaximum
            self.activeLensMinimumZoomFactor = lensMinimum
            self.activeLensMaximumZoomFactor = max(lensMinimum, lensMaximum)
            self.zoomQuickFactors = quickFactors
        }
    }

    private func applyZoomToCurrentLensOnSessionQueue(
        _ requestedDisplayFactor: Double,
        smoothly: Bool
    ) {
        guard let device = videoDevice else { return }
        refreshZoomCapabilitiesOnSessionQueue()

        let minimumDeviceFactor = Double(device.minAvailableVideoZoomFactor)
        let maximumDeviceFactor = max(
            minimumDeviceFactor,
            min(
                Double(device.maxAvailableVideoZoomFactor),
                Double(device.activeFormat.videoMaxZoomFactor)
            )
        )
        let requestedDeviceFactor = requestedDisplayFactor / currentLensNativeZoomFactor
        let deviceFactor = min(
            max(requestedDeviceFactor, minimumDeviceFactor),
            maximumDeviceFactor
        )

        do {
            try device.lockForConfiguration()
            if smoothly {
                let distance = abs(Double(device.videoZoomFactor) - deviceFactor)
                device.ramp(
                    toVideoZoomFactor: CGFloat(deviceFactor),
                    withRate: Float(max(2.0, distance * 5.0))
                )
            } else {
                if device.isRampingVideoZoom {
                    device.cancelVideoZoomRamp()
                }
                device.videoZoomFactor = CGFloat(deviceFactor)
            }
            device.unlockForConfiguration()

            let appliedDisplayFactor = currentLensNativeZoomFactor * deviceFactor
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.zoomFactor = appliedDisplayFactor
                self.activeLensMinimumZoomFactor =
                    self.currentLensNativeZoomFactor * minimumDeviceFactor
                self.activeLensMaximumZoomFactor = min(
                    self.maximumZoomFactor,
                    self.currentLensNativeZoomFactor * maximumDeviceFactor
                )
            }
        } catch {
            publishStatus(L10n.format("ズームを変更できませんでした: %@", error.localizedDescription))
        }
    }

    private static func formatZoomFactor(_ factor: Double) -> String {
        if abs(factor.rounded() - factor) < 0.04 {
            return "\(Int(factor.rounded()))×"
        }
        return String(format: "%.1f×", factor)
    }

    private static let representativeZoomFactors: [Double] = [
        0.5, 1, 2, 3, 5, 10, 15
    ]

    private func reconfigureForCaptureMode() {
        guard isConfigured, !isRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.livePreviewProcessor.beginCaptureReconfiguration()
            self.applyCaptureFormatOnSessionQueue()
            self.updateOutputOrientation()
            self.livePreviewProcessor.endCaptureReconfiguration()
        }
    }

    private func reconfigureVideoFormat() {
        guard isConfigured, captureMode == .video, !isRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.livePreviewProcessor.beginCaptureReconfiguration()
            self.applyVideoFormatOnSessionQueue()
            self.applyCorrectionPreferencesOnSessionQueue()
            self.applyExposurePreferencesOnSessionQueue()
            self.applyWhiteBalancePreferencesOnSessionQueue()
            self.updateOutputOrientation()
            self.livePreviewProcessor.endCaptureReconfiguration()
        }
    }

    private func applyCaptureFormatOnSessionQueue() {
        switch captureMode {
        case .photo:
            applyPhotoFormatOnSessionQueue()
        case .video:
            applyVideoFormatOnSessionQueue()
        }
        applyCorrectionPreferencesOnSessionQueue()
        applyExposurePreferencesOnSessionQueue()
        applyWhiteBalancePreferencesOnSessionQueue()
    }

    private func applyPhotoFormatOnSessionQueue() {
        guard let device = videoDevice else { return }

        let ranked = device.formats.compactMap { format -> (AVCaptureDevice.Format, CMVideoDimensions)? in
            guard let dimensions = format.supportedMaxPhotoDimensions.max(by: { $0.pixelCount < $1.pixelCount }) else {
                return nil
            }
            return (format, dimensions)
        }
        guard let selection = ranked.max(by: { $0.1.pixelCount < $1.1.pixelCount }) else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if photoOutput.isContentAwareDistortionCorrectionEnabled {
            photoOutput.isContentAwareDistortionCorrectionEnabled = false
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = selection.0
            device.unlockForConfiguration()
            photoOutput.maxPhotoDimensions = selection.1
            livePreviewProcessor.updatePhotoNativeDimensions(selection.1)
            publishActualFormat(
                L10n.format("写真 最大 %d×%d", selection.1.width, selection.1.height)
            )
            publishDeviceRanges(device)
            applyZoomToCurrentLensOnSessionQueue(zoomFactor, smoothly: false)
        } catch {
            publishStatus(L10n.format("写真形式の設定に失敗しました: %@", error.localizedDescription))
        }
    }

    private func applyVideoFormatOnSessionQueue() {
        guard let device = videoDevice else { return }
        let desired = videoResolution.dimensions
        let requestedFPS = Double(videoFrameRate.rawValue)

        let candidates = device.formats.compactMap { format -> (AVCaptureDevice.Format, CMVideoDimensions, Double)? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width > 0, dimensions.height > 0 else { return nil }
            let supportsFPS = format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= requestedFPS && requestedFPS <= $0.maxFrameRate
            }
            let areaDelta = abs(log(Double(dimensions.pixelCount) / Double(desired.pixelCount)))
            let desiredAspect = Double(desired.width) / Double(desired.height)
            let actualAspect = Double(dimensions.width) / Double(dimensions.height)
            let aspectPenalty = abs(actualAspect - desiredAspect) * 3
            let frameRatePenalty: Double = supportsFPS ? 0 : 100
            return (format, dimensions, areaDelta + aspectPenalty + frameRatePenalty)
        }

        guard let selection = candidates.min(by: { $0.2 < $1.2 }) else {
            publishStatus(L10n.string("対応する動画形式が見つかりません。"))
            return
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if photoOutput.isContentAwareDistortionCorrectionEnabled {
            photoOutput.isContentAwareDistortionCorrectionEnabled = false
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = selection.0
            if selection.0.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= requestedFPS && requestedFPS <= $0.maxFrameRate
            }) {
                let duration = CMTime(value: 1, timescale: CMTimeScale(videoFrameRate.rawValue))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
            if let supportedPhotoDimensions = selection.0.supportedMaxPhotoDimensions.max(by: {
                $0.pixelCount < $1.pixelCount
            }) {
                photoOutput.maxPhotoDimensions = supportedPhotoDimensions
            }
            let logical = videoResolution.dimensions
            let output = logical.scaled(by: pixelUpscaleFactor.rawValue)
            publishActualFormat(L10n.format(
                "入力 %d×%d / 論理 %d×%d / 保存 %d×%d / %d fps",
                selection.1.width,
                selection.1.height,
                logical.width,
                logical.height,
                output.width,
                output.height,
                videoFrameRate.rawValue
            ))
            publishDeviceRanges(device)
            applyZoomToCurrentLensOnSessionQueue(zoomFactor, smoothly: false)
        } catch {
            publishStatus(L10n.format("動画形式の設定に失敗しました: %@", error.localizedDescription))
        }
    }

    private func applyCorrectionPreferences() {
        guard isConfigured else { return }
        sessionQueue.async { [weak self] in
            self?.applyCorrectionPreferencesOnSessionQueue()
        }
    }

    private func applyCorrectionPreferencesOnSessionQueue() {
        guard let device = videoDevice else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        do {
            try device.lockForConfiguration()

            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = lensCorrectionEnabled
            }

            device.automaticallyAdjustsVideoHDREnabled = false
            if device.activeFormat.isVideoHDRSupported {
                device.isVideoHDREnabled = hdrEnabled
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = lowLightBoostEnabled
            }
            device.unlockForConfiguration()
        } catch {
            publishStatus(L10n.format("補正設定を変更できませんでした: %@", error.localizedDescription))
        }

        if photoOutput.isContentAwareDistortionCorrectionSupported {
            photoOutput.isContentAwareDistortionCorrectionEnabled = lensCorrectionEnabled
        }

        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
            guard let connection, connection.isVideoStabilizationSupported else { continue }
            if stabilizationEnabled,
               device.activeFormat.isVideoStabilizationModeSupported(.standard) {
                connection.preferredVideoStabilizationMode = .standard
            } else {
                connection.preferredVideoStabilizationMode = .off
            }
        }
    }

    private func applyExposurePreferences() {
        guard isConfigured else { return }
        pendingExposureWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyExposurePreferencesOnSessionQueue()
        }
        pendingExposureWorkItem = workItem
        sessionQueue.asyncAfter(deadline: .now() + .milliseconds(33), execute: workItem)
    }

    private func applyExposurePreferencesOnSessionQueue() {
        guard let device = videoDevice else { return }
        let ranges = deviceExposureRanges(for: device)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let bias = Float(min(max(exposureBias, ranges.minimumBias), ranges.maximumBias))
            switch (isShutterLocked, isISOLocked) {
            case (false, false):
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.setExposureTargetBias(bias, completionHandler: nil)

            case (true, false):
                guard device.isExposureModeSupported(.custom) else {
                    publishStatus(L10n.string("このカメラはシャッター固定に対応していません。"))
                    return
                }
                device.setExposureTargetBias(bias, completionHandler: nil)
                let shutter = min(
                    max(shutterSeconds, ranges.minimumShutter),
                    ranges.maximumShutter
                )
                let currentDuration = max(device.exposureDuration.seconds, 0.000_001)
                let exposurePreservingISO = Double(device.iso) * currentDuration / shutter
                let seededISO = Float(
                    min(max(exposurePreservingISO, ranges.minimumISO), ranges.maximumISO)
                )
                let duration = CMTime(seconds: shutter, preferredTimescale: 1_000_000_000)
                device.setExposureModeCustom(
                    duration: duration,
                    iso: seededISO,
                    completionHandler: nil
                )

            case (false, true):
                guard device.isExposureModeSupported(.custom) else {
                    publishStatus(L10n.string("このカメラはISO固定に対応していません。"))
                    return
                }
                device.setExposureTargetBias(bias, completionHandler: nil)
                let fixedISO = min(max(iso, ranges.minimumISO), ranges.maximumISO)
                let currentDuration = max(device.exposureDuration.seconds, 0.000_001)
                let currentISO = max(Double(device.iso), 1)
                let exposurePreservingDuration = currentDuration * currentISO / max(fixedISO, 1)
                let seededDuration = min(
                    max(exposurePreservingDuration, ranges.minimumShutter),
                    ranges.maximumShutter
                )
                device.setExposureModeCustom(
                    duration: CMTime(seconds: seededDuration, preferredTimescale: 1_000_000_000),
                    iso: Float(fixedISO),
                    completionHandler: nil
                )

            case (true, true):
                guard device.isExposureModeSupported(.custom) else {
                    publishStatus(L10n.string("このカメラは手動露出に対応していません。"))
                    return
                }
                device.setExposureTargetBias(0, completionHandler: nil)
                let shutter = min(
                    max(shutterSeconds, ranges.minimumShutter),
                    ranges.maximumShutter
                )
                let clampedISO = Float(min(max(iso, ranges.minimumISO), ranges.maximumISO))
                let duration = CMTime(seconds: shutter, preferredTimescale: 1_000_000_000)
                device.setExposureModeCustom(duration: duration, iso: clampedISO, completionHandler: nil)
            }
        } catch {
            publishStatus(L10n.format("露出設定を変更できませんでした: %@", error.localizedDescription))
        }
    }

    private func startExposureMonitoringOnSessionQueue() {
        guard exposureMonitorTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(
            deadline: .now(),
            repeating: .milliseconds(200),
            leeway: .milliseconds(40)
        )
        timer.setEventHandler { [weak self] in
            self?.monitorExposureOnSessionQueue()
        }
        exposureMonitorTimer = timer
        timer.resume()
    }

    private func monitorExposureOnSessionQueue() {
        guard session.isRunning,
              let device = videoDevice,
              device.isConnected
        else { return }
        let ranges = deviceExposureRanges(for: device)

        let rawOffset = Double(device.exposureTargetOffset)
        smoothedExposureOffset = smoothedExposureOffset * 0.7 + rawOffset * 0.3
        var automationStatus: String
        switch (isShutterLocked, isISOLocked) {
        case (false, false): automationStatus = L10n.string("露出自動")
        case (true, false): automationStatus = L10n.string("ISO自動")
        case (false, true): automationStatus = L10n.string("シャッター自動")
        case (true, true): automationStatus = L10n.string("手動")
        }

        if isShutterLocked, !isISOLocked {
            let currentISO = Double(device.iso)
            let atMinimum = currentISO <= ranges.minimumISO * 1.01
            let atMaximum = currentISO >= ranges.maximumISO * 0.99

            if atMaximum, smoothedExposureOffset < -0.1 {
                automationStatus = L10n.string("ISO上限")
            } else if atMinimum, smoothedExposureOffset > 0.1 {
                automationStatus = L10n.string("ISO下限")
            } else if abs(smoothedExposureOffset) > 0.08,
                      !exposureAutomationUpdateInFlight {
                let correctionEV = min(
                    max(-smoothedExposureOffset * 0.35, -1.0 / 3.0),
                    1.0 / 3.0
                )
                let proposedISO = currentISO * pow(2, correctionEV)
                let nextISO = min(
                    max(proposedISO, ranges.minimumISO),
                    ranges.maximumISO
                )

                if abs(log2(max(nextISO, 1) / max(currentISO, 1))) > 0.015 {
                    do {
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        exposureAutomationUpdateInFlight = true
                        let shutter = min(
                            max(shutterSeconds, ranges.minimumShutter),
                            ranges.maximumShutter
                        )
                        device.setExposureModeCustom(
                            duration: CMTime(
                                seconds: shutter,
                                preferredTimescale: 1_000_000_000
                            ),
                            iso: Float(nextISO)
                        ) { [weak self] _ in
                            self?.sessionQueue.async {
                                self?.exposureAutomationUpdateInFlight = false
                            }
                        }
                    } catch {
                        exposureAutomationUpdateInFlight = false
                        publishStatus(L10n.format("ISO自動調整に失敗しました: %@", error.localizedDescription))
                    }
                }
            }
        } else if isISOLocked, !isShutterLocked {
            let currentDuration = max(device.exposureDuration.seconds, 0.000_001)
            let atMinimum = currentDuration <= ranges.minimumShutter * 1.01
            let atMaximum = currentDuration >= ranges.maximumShutter * 0.99

            if atMaximum, smoothedExposureOffset < -0.1 {
                automationStatus = L10n.string("シャッター上限")
            } else if atMinimum, smoothedExposureOffset > 0.1 {
                automationStatus = L10n.string("シャッター下限")
            } else if abs(smoothedExposureOffset) > 0.08,
                      !exposureAutomationUpdateInFlight {
                let correctionEV = min(
                    max(-smoothedExposureOffset * 0.35, -1.0 / 3.0),
                    1.0 / 3.0
                )
                let proposedDuration = currentDuration * pow(2, correctionEV)
                let nextDuration = min(
                    max(proposedDuration, ranges.minimumShutter),
                    ranges.maximumShutter
                )

                if abs(log2(max(nextDuration, 0.000_001) / currentDuration)) > 0.015 {
                    do {
                        try device.lockForConfiguration()
                        defer { device.unlockForConfiguration() }
                        exposureAutomationUpdateInFlight = true
                        let fixedISO = Float(min(max(iso, ranges.minimumISO), ranges.maximumISO))
                        device.setExposureModeCustom(
                            duration: CMTime(
                                seconds: nextDuration,
                                preferredTimescale: 1_000_000_000
                            ),
                            iso: fixedISO
                        ) { [weak self] _ in
                            self?.sessionQueue.async {
                                self?.exposureAutomationUpdateInFlight = false
                            }
                        }
                    } catch {
                        exposureAutomationUpdateInFlight = false
                        publishStatus(L10n.format("シャッター自動調整に失敗しました: %@", error.localizedDescription))
                    }
                }
            }
        }

        let whiteBalance = safeWhiteBalanceValues(for: device)
        let currentShutter = max(device.exposureDuration.seconds, 0.000_001)
        let currentISO = Double(device.iso)
        let currentOffset = smoothedExposureOffset

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measuredShutterSeconds = currentShutter
            self.measuredISO = currentISO
            self.measuredExposureOffset = currentOffset
            self.exposureAutomationStatus = automationStatus
            if let whiteBalance {
                self.measuredWhiteBalanceTemperature = Double(whiteBalance.temperature)
                self.measuredWhiteBalanceTint = Double(whiteBalance.tint)
            }
        }
    }

    private func safeWhiteBalanceValues(
        for device: AVCaptureDevice
    ) -> AVCaptureDevice.WhiteBalanceTemperatureAndTintValues? {
        let maximumGain = device.maxWhiteBalanceGain
        guard maximumGain.isFinite, maximumGain >= 1 else { return nil }

        var gains = device.deviceWhiteBalanceGains
        guard gains.redGain.isFinite,
              gains.greenGain.isFinite,
              gains.blueGain.isFinite
        else { return nil }

        // AVFoundation raises an Objective-C exception (which Swift can't catch)
        // when conversion receives a gain outside the device-supported range.
        // A camera can briefly report sentinel/out-of-range values while its
        // session or active format is changing, so sanitize every channel first.
        gains.redGain = min(max(1, gains.redGain), maximumGain)
        gains.greenGain = min(max(1, gains.greenGain), maximumGain)
        gains.blueGain = min(max(1, gains.blueGain), maximumGain)

        let values = device.temperatureAndTintValues(for: gains)
        guard values.temperature.isFinite, values.tint.isFinite else { return nil }
        return values
    }

    private func resetExposureAutomationTrackingOnSessionQueue() {
        smoothedExposureOffset = 0
        exposureAutomationUpdateInFlight = false
    }

    private func applyWhiteBalanceSelection(seedFromAutomatic: Bool) {
        isApplyingWhiteBalanceSelection = true
        switch whiteBalanceAdjustmentMode {
        case .preset:
            if let temperature = whiteBalancePreset.temperature {
                whiteBalanceTemperature = temperature
                whiteBalanceTint = whiteBalancePreset.tint
                whiteBalanceControlMode = .manual
            } else {
                whiteBalanceControlMode = .automatic
            }

        case .temperature:
            if seedFromAutomatic, whiteBalanceControlMode == .automatic {
                if cameraControlAdjustmentStyle == .stepped {
                    whiteBalanceTemperature = (measuredWhiteBalanceTemperature / 100).rounded() * 100
                    whiteBalanceTint = (measuredWhiteBalanceTint / 5).rounded() * 5
                } else {
                    whiteBalanceTemperature = measuredWhiteBalanceTemperature
                    whiteBalanceTint = measuredWhiteBalanceTint
                }
            }
            whiteBalanceControlMode = .manual
        }
        isApplyingWhiteBalanceSelection = false
        applyWhiteBalancePreferences()
    }

    private func applyWhiteBalancePreferences() {
        guard isConfigured else { return }
        pendingWhiteBalanceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyWhiteBalancePreferencesOnSessionQueue()
        }
        pendingWhiteBalanceWorkItem = workItem
        sessionQueue.asyncAfter(deadline: .now() + .milliseconds(33), execute: workItem)
    }

    private func applyWhiteBalancePreferencesOnSessionQueue() {
        guard let device = videoDevice, device.isConnected else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            switch whiteBalanceControlMode {
            case .automatic:
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            case .manual:
                guard device.isWhiteBalanceModeSupported(.locked) else {
                    publishStatus(L10n.string("このカメラは手動ホワイトバランスに対応していません。"))
                    return
                }
                let temperature = whiteBalanceTemperature.isFinite
                    ? min(
                        max(whiteBalanceTemperature, Self.whiteBalanceTemperatureRange.lowerBound),
                        Self.whiteBalanceTemperatureRange.upperBound
                    )
                    : 5_000
                let tint = whiteBalanceTint.isFinite
                    ? min(
                        max(whiteBalanceTint, Self.whiteBalanceTintRange.lowerBound),
                        Self.whiteBalanceTintRange.upperBound
                    )
                    : 0
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: Float(temperature),
                    tint: Float(tint)
                )
                var gains = device.deviceWhiteBalanceGains(for: values)
                guard gains.redGain.isFinite,
                      gains.greenGain.isFinite,
                      gains.blueGain.isFinite,
                      device.maxWhiteBalanceGain.isFinite,
                      device.maxWhiteBalanceGain >= 1
                else {
                    publishStatus(L10n.string("ホワイトバランス値を変換できませんでした。"))
                    return
                }
                gains.redGain = min(max(1, gains.redGain), device.maxWhiteBalanceGain)
                gains.greenGain = min(max(1, gains.greenGain), device.maxWhiteBalanceGain)
                gains.blueGain = min(max(1, gains.blueGain), device.maxWhiteBalanceGain)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
        } catch {
            publishStatus(L10n.format("ホワイトバランスを変更できませんでした: %@", error.localizedDescription))
        }
    }

    private func publishDeviceRanges(_ device: AVCaptureDevice) {
        let ranges = deviceExposureRanges(for: device)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.minimumShutterSeconds = ranges.minimumShutter
            self.maximumShutterSeconds = ranges.maximumShutter
            self.minimumISO = ranges.minimumISO
            self.maximumISO = ranges.maximumISO
            self.minimumExposureBias = ranges.minimumBias
            self.maximumExposureBias = ranges.maximumBias
            self.shutterSeconds = min(
                max(self.shutterSeconds, ranges.minimumShutter),
                ranges.maximumShutter
            )
            self.iso = min(max(self.iso, ranges.minimumISO), ranges.maximumISO)
            self.exposureBias = min(
                max(self.exposureBias, ranges.minimumBias),
                ranges.maximumBias
            )
        }
    }

    private func deviceExposureRanges(for device: AVCaptureDevice) -> DeviceExposureRanges {
        let minimumShutter = max(
            device.activeFormat.minExposureDuration.seconds,
            1.0 / 100_000.0
        )
        var maximumShutter = max(
            minimumShutter,
            device.activeFormat.maxExposureDuration.seconds
        )
        if captureMode == .video {
            maximumShutter = min(maximumShutter, 1.0 / Double(videoFrameRate.rawValue))
        }
        return DeviceExposureRanges(
            minimumShutter: minimumShutter,
            maximumShutter: maximumShutter,
            minimumISO: Double(device.activeFormat.minISO),
            maximumISO: Double(device.activeFormat.maxISO),
            minimumBias: Double(device.minExposureTargetBias),
            maximumBias: Double(device.maxExposureTargetBias)
        )
    }

    private struct DeviceExposureRanges {
        let minimumShutter: Double
        let maximumShutter: Double
        let minimumISO: Double
        let maximumISO: Double
        let minimumBias: Double
        let maximumBias: Double
    }

    private func capturePhoto() {
        guard isConfigured, !isBusy else { return }
        isBusy = true
        statusMessage = L10n.string("撮影中…")
        pendingPhotoConfiguration = currentPhotoConfiguration
        let rotationAngle = captureRotationAngle

        let settings: AVCapturePhotoSettings
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        }
        settings.flashMode = .off
        let requiresFixedExposure = isShutterLocked || isISOLocked
        settings.photoQualityPrioritization = (minimizeTextureProcessing || requiresFixedExposure)
            ? .speed
            : .balanced
        settings.isAutoVirtualDeviceFusionEnabled = !minimizeTextureProcessing
        settings.isAutoRedEyeReductionEnabled = false
        if let captureDimensions = requestedPhotoCaptureDimensions(for: pendingPhotoConfiguration) {
            settings.maxPhotoDimensions = captureDimensions
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func requestedPhotoCaptureDimensions(
        for configuration: PhotoEncodingConfiguration?
    ) -> CMVideoDimensions? {
        guard let configuration, let device = videoDevice else { return nil }
        let maximumOutputPixels = photoOutput.maxPhotoDimensions.pixelCount
        let supported = device.activeFormat.supportedMaxPhotoDimensions.filter {
            $0.pixelCount <= maximumOutputPixels
        }
        guard !supported.isEmpty else {
            return photoOutput.maxPhotoDimensions.width > 0 ? photoOutput.maxPhotoDimensions : nil
        }
        guard let targetPixels = configuration.resolution.maximumPixelCount else {
            return supported.max(by: { $0.pixelCount < $1.pixelCount })
        }
        return supported.min {
            let left = abs(log(Double($0.pixelCount) / Double(targetPixels)))
            let right = abs(log(Double($1.pixelCount) / Double(targetPixels)))
            return left < right
        }
    }

    private func toggleRecording() {
        guard isConfigured, !isBusy else { return }

        if isRecording {
            isRecording = false
            isBusy = true
            statusMessage = L10n.string("動画を仕上げています…")
            outputQueue.async { [weak self] in
                guard let self else { return }
                self.videoRecorder.stop()
                DispatchQueue.main.async { [weak self] in
                    self?.playRecordingEndCue()
                }
            }
            return
        }

        isBusy = true
        isWaitingForRecordingStartCue = true
        statusMessage = L10n.string("録画開始音を再生しています…")
        recordingCuePlayer.play(.start) { [weak self] playedSuccessfully in
            guard let self, self.isWaitingForRecordingStartCue else { return }
            guard playedSuccessfully else {
                self.isWaitingForRecordingStartCue = false
                self.isBusy = false
                self.statusMessage = L10n.string(
                    "録画開始音を再生できないため、録画を開始しませんでした。"
                )
                return
            }

            let workItem = DispatchWorkItem { [weak self] in
                self?.beginVideoRecordingAfterCue()
            }
            self.pendingRecordingStartWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(60),
                execute: workItem
            )
        }
    }

    private func beginVideoRecordingAfterCue() {
        pendingRecordingStartWorkItem = nil
        guard isWaitingForRecordingStartCue, isConfigured, captureMode == .video else {
            cancelPendingRecordingStartCue()
            return
        }

        isWaitingForRecordingStartCue = false
        let configuration = currentVideoConfiguration
        let rotationAngle = captureRotationAngle
        let sourceRotationAngle = videoOutput.connection(with: .video)?.videoRotationAngle ?? 0
        isRecording = true
        isBusy = false
        statusMessage = L10n.string("録画中")
        outputQueue.async { [weak self] in
            guard let self else { return }
            self.videoRecorder.start(
                configuration: configuration,
                sourceRotationAngle: sourceRotationAngle,
                captureRotationAngle: rotationAngle
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(recordedVideo):
                    self.saveVideo(recordedVideo)
                case let .failure(error):
                    DispatchQueue.main.async {
                        self.isRecording = false
                        self.isBusy = false
                        self.statusMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func cancelPendingRecordingStartCue() {
        guard isWaitingForRecordingStartCue else { return }
        pendingRecordingStartWorkItem?.cancel()
        pendingRecordingStartWorkItem = nil
        recordingCuePlayer.cancel()
        isWaitingForRecordingStartCue = false
        isBusy = false
        statusMessage = microphoneAvailable
            ? L10n.string("撮影できます。")
            : L10n.string("撮影できます（動画は音声なし）。")
    }

    private func playRecordingEndCue() {
        recordingCuePlayer.play(.end) { _ in }
    }

    private func savePhoto(_ encoded: EncodedPhoto) {
        do {
            let item = try AppMediaStore.savePhoto(
                data: encoded.data,
                fileExtension: encoded.fileExtension
            )
            finishLocalMediaSave(item, mediaName: L10n.string("写真"))
        } catch {
            DispatchQueue.main.async {
                self.isBusy = false
                self.statusMessage = L10n.format(
                    "写真をアプリ内へ保存できませんでした：%@",
                    error.localizedDescription
                )
            }
        }
    }

    private func saveVideo(_ recordedVideo: RecordedVideo) {
        do {
            let item = try AppMediaStore.saveVideo(
                from: recordedVideo.url,
                pixelWidth: recordedVideo.pixelWidth,
                pixelHeight: recordedVideo.pixelHeight,
                duration: recordedVideo.duration
            )
            DispatchQueue.main.async {
                self.lastCapturedPhotoPreview = nil
            }
            finishLocalMediaSave(item, mediaName: L10n.string("動画"))
        } catch {
            try? FileManager.default.removeItem(at: recordedVideo.url)
            DispatchQueue.main.async {
                self.isBusy = false
                self.isRecording = false
                self.statusMessage = L10n.format(
                    "動画をアプリ内へ保存できませんでした：%@",
                    error.localizedDescription
                )
            }
        }
    }

    private func finishLocalMediaSave(_ item: AppMediaItem, mediaName: String) {
        if saveToPhotoLibraryEnabled {
            exportToPhotoLibrary(item, mediaName: mediaName)
        } else {
            DispatchQueue.main.async {
                self.isBusy = false
                self.isRecording = false
                self.lastSavedFileSizeText = Self.byteCountFormatter.string(
                    fromByteCount: item.fileSizeBytes
                )
                self.statusMessage = L10n.format("%@をアプリ内に保存しました。", mediaName)
            }
        }
    }

    private func exportToPhotoLibrary(_ item: AppMediaItem, mediaName: String) {
        PhotoLibraryExporter.export(item) { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isBusy = false
                self.isRecording = false
                self.lastSavedFileSizeText = Self.byteCountFormatter.string(
                    fromByteCount: item.fileSizeBytes
                )
                switch result {
                case .success:
                    try? AppMediaStore.markPhotoLibraryExported(item)
                    self.statusMessage = L10n.format(
                        "%@をアプリ内と写真アプリに保存しました。",
                        mediaName
                    )
                case let .failure(error):
                    if let exportError = error as? PhotoLibraryExportError,
                       case .accessDenied = exportError {
                        self.saveToPhotoLibraryEnabled = false
                    }
                    self.statusMessage = L10n.format(
                        "%@はアプリ内に保存しました。%@",
                        mediaName,
                        error.localizedDescription
                    )
                }
            }
        }
    }

    private func publishAuthorization(_ state: CameraAuthorizationState, message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.permissionRequestInFlight = false
            self?.authorizationState = state
            self?.statusMessage = message
        }
    }

    private func publishStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = message
        }
    }

    private func publishActualFormat(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.actualVideoFormatText = text
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private static func compactEstimatedSize(megabytes: Double) -> String {
        let safeMegabytes = max(megabytes, 0)
        if safeMegabytes >= 1_000 {
            return String(format: "≈%.1fGB", safeMegabytes / 1_000)
        }
        if safeMegabytes >= 10 {
            return String(format: "≈%.0fMB", safeMegabytes)
        }
        if safeMegabytes >= 1 {
            return String(format: "≈%.1fMB", safeMegabytes)
        }
        return String(format: "≈%.0fKB", max(safeMegabytes * 1_000, 1))
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Recording remains on the capture output queue. Preview conversion only
        // submits a retained frame to its own throttled queue, so it cannot stall recording.
        videoRecorder.captureOutput(output, didOutput: sampleBuffer, from: connection)
        if output is AVCaptureVideoDataOutput {
            livePreviewProcessor.submit(sampleBuffer)
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            DispatchQueue.main.async { [weak self] in
                self?.isBusy = false
                self?.statusMessage = error.localizedDescription
            }
            return
        }

        guard
            let data = photo.fileDataRepresentation(),
            let configuration = pendingPhotoConfiguration
        else {
            DispatchQueue.main.async { [weak self] in
                self?.isBusy = false
                self?.statusMessage = L10n.string("写真データを取得できませんでした。")
            }
            return
        }

        processingQueue.async { [weak self] in
            guard let self else { return }
            do {
                let encoded = try PhotoProcessor.encode(sourceData: data, configuration: configuration)
                if let preview = PhotoProcessor.makeReviewPreview(from: encoded.data) {
                    DispatchQueue.main.async {
                        let sizeText = Self.byteCountFormatter.string(
                            fromByteCount: Int64(encoded.data.count)
                        )
                        self.lastCapturedPhotoPreview = preview.image
                        self.lastCapturedPhotoInformation = L10n.format(
                            "%@・%d×%d・%@・コントラスト %@・%@",
                            configuration.format.rawValue,
                            preview.pixelWidth,
                            preview.pixelHeight,
                            configuration.colorLevels.title,
                            configuration.contrast.summaryTitle,
                            sizeText
                        )
                    }
                }
                self.savePhoto(encoded)
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.statusMessage = error.localizedDescription
                }
            }
        }
    }
}
