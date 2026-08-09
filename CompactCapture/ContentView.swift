import AVFoundation
import Foundation
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var showMediaGallery = false
    @State private var zoomAtPinchStart: Double?

    var body: some View {
        ZStack {
            captureScreen

            if showSettings {
                CaptureSettingsView(
                    camera: camera,
                    previewImage: camera.livePreviewImage
                ) {
                    camera.saveSettingsNow()
                    camera.leaveSettings()
                    withAnimation(.easeOut(duration: 0.18)) {
                        showSettings = false
                    }
                }
                .transition(.opacity)
                .zIndex(10)
            }

            if showMediaGallery {
                AppMediaGalleryView {
                    showMediaGallery = false
                    if scenePhase == .active {
                        camera.start()
                    }
                }
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .onAppear {
            if !showSettings, !showMediaGallery {
                camera.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if !showSettings, !showMediaGallery {
                    camera.start()
                }
            case .background:
                camera.saveSettingsNow()
                camera.stopSession()
            default:
                break
            }
        }
    }

    private var captureScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.authorizationState == .ready {
                ZStack {
                    CameraPreview(
                        session: camera.session,
                        onRotationAngleChanged: camera.setLivePreviewRotationAngle
                    )

                    if let image = camera.livePreviewImage {
                        ResultCameraPreview(image: image)
                    }
                }
                .contentShape(Rectangle())
                .gesture(cameraZoomGesture)
                .ignoresSafeArea()
            }

            VStack {
                Spacer()
                capturePanel
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if camera.authorizationState == .denied || camera.authorizationState == .unavailable {
                permissionOverlay
            }
        }
    }

    private var capturePanel: some View {
        VStack(spacing: 8) {
            if camera.zoomIsAvailable {
                CameraZoomControl(camera: camera)
            }

            Picker("撮影", selection: $camera.captureMode) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(camera.isRecording || camera.isBusy)

            captureStatusSummary

            ZStack {
                HStack {
                    Button {
                        camera.stopSession()
                        showMediaGallery = true
                    } label: {
                        if let image = camera.lastCapturedPhotoPreview {
                            Image(uiImage: image)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFill()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(.white.opacity(0.8), lineWidth: 1)
                                }
                        } else {
                            VStack(spacing: 1) {
                                Image(systemName: "photo.stack")
                                    .font(.title3)
                                Text("一覧")
                                    .font(.caption2)
                            }
                            .frame(width: 48, height: 48)
                            .background(
                                Color.black.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .tint(.white)
                    .disabled(camera.isRecording || camera.isBusy)
                    .accessibilityLabel("このアプリで撮影した写真と動画を開く")

                    Spacer()

                    Button {
                        camera.enterSettings()
                        withAnimation(.easeOut(duration: 0.18)) {
                            showSettings = true
                        }
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.title3)
                            Text("設定")
                                .font(.caption2)
                        }
                        .frame(width: 48, height: 48)
                        .background(
                            Color.black.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
                        }
                    }
                    .buttonStyle(.plain)
                    .tint(.white)
                    .disabled(camera.isRecording || camera.isBusy || !camera.isConfigured)
                    .accessibilityLabel("撮影設定を開く")
                }

                captureButton
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.12))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
        }
        .frame(maxWidth: 720)
    }

    private var captureStatusSummary: some View {
        HStack(spacing: 6) {
            if camera.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)

                Text("録画中")
                    .font(.caption.weight(.bold))
            } else if camera.isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)

                Text("処理中")
                    .font(.caption.weight(.bold))
            } else {
                Text(summaryText)
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .settingsTextOutline()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cameraZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { magnification in
                guard camera.isConfigured, !camera.isBusy else { return }
                if zoomAtPinchStart == nil {
                    zoomAtPinchStart = camera.zoomFactor
                }
                guard let zoomAtPinchStart else { return }
                camera.setZoomFactor(zoomAtPinchStart * Double(magnification))
            }
            .onEnded { _ in
                zoomAtPinchStart = nil
            }
    }

    private var captureButton: some View {
        Button {
            camera.performCapture()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)

                if camera.captureMode == .video {
                    RoundedRectangle(cornerRadius: camera.isRecording ? 5 : 28, style: .continuous)
                        .fill(.red)
                        .frame(
                            width: camera.isRecording ? 28 : 58,
                            height: camera.isRecording ? 28 : 58
                        )
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 58, height: 58)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!camera.isConfigured || camera.isBusy)
        .opacity((!camera.isConfigured || camera.isBusy) ? 0.5 : 1)
        .accessibilityLabel(
            camera.isRecording
                ? "録画を停止"
                : camera.captureMode == .photo ? "写真を撮影" : "録画を開始"
        )
    }

    private var summaryText: String {
        let scale = camera.pixelUpscaleFactor == .one
            ? ""
            : "・\(camera.pixelUpscaleFactor.title)保存"
        let contrast = camera.contrast == .standard
            ? ""
            : "・コントラスト \(camera.contrast.summaryTitle)"
        switch camera.captureMode {
        case .photo:
            let appliedScale = camera.photoFormat == .png ? scale : ""
            return "\(camera.photoFormat.rawValue)・\(camera.photoResolution.rawValue)\(appliedScale)・色 \(camera.colorLevels.title)\(contrast)・\(exposureSummary)・\(whiteBalanceSummary)"
        case .video:
            let rate = camera.videoCodec.supportsBitRateSelection
                ? "・\(camera.videoBitRate.title)"
                : ""
            return "\(camera.videoResolution.rawValue)\(scale)・\(camera.videoFrameRate.title)・\(camera.videoCodec.shortTitle)\(rate)・色 \(camera.colorLevels.shortTitle)\(contrast)・\(exposureSummary)"
        }
    }

    private var exposureSummary: String {
        switch (camera.isShutterLocked, camera.isISOLocked) {
        case (false, false):
            return "露出自動"
        case (true, false):
            return "SS \(camera.formatShutter(camera.shutterSeconds))・ISO自動"
        case (false, true):
            return "ISO \(Int(camera.iso.rounded()))・SS自動"
        case (true, true):
            return "\(camera.formatShutter(camera.shutterSeconds))・ISO \(Int(camera.iso.rounded()))"
        }
    }

    private var whiteBalanceSummary: String {
        switch camera.whiteBalanceAdjustmentMode {
        case .preset:
            return "WB \(camera.whiteBalancePreset.shortTitle)"
        case .temperature:
            return "WB \(Int(camera.whiteBalanceTemperature.rounded()))K"
        }
    }

    private var permissionOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 42))
            Text(camera.statusMessage)
                .multilineTextAlignment(.center)
            if camera.authorizationState == .denied {
                Button("設定を開く") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(24)
    }
}

private struct CameraZoomControl: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        HStack(spacing: 5) {
            GeometryReader { proxy in
                let factors = camera.zoomQuickFactors
                let spacing: CGFloat = 4
                let factorCount = CGFloat(max(factors.count, 1))
                let totalSpacing = spacing * CGFloat(max(factors.count - 1, 0))
                let buttonSize = min(
                    33,
                    max(23, (proxy.size.width - totalSpacing) / factorCount)
                )

                HStack(spacing: spacing) {
                    ForEach(factors, id: \.self) { factor in
                        let selected = camera.zoomButtonIsSelected(factor)
                        let selectable = camera.zoomFactorIsSelectable(factor)
                        Button {
                            camera.setZoomFactor(factor, smoothly: false)
                        } label: {
                            Text(factorLabel(factor))
                                .font(.system(size: 10.2, weight: selected ? .bold : .semibold))
                                .monospacedDigit()
                                .minimumScaleFactor(0.72)
                                .foregroundStyle(selected ? Color.black : Color.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .background(
                                    selected
                                        ? Color.yellow
                                        : Color.black.opacity(0.38),
                                    in: Circle()
                                )
                                .overlay {
                                    Circle()
                                        .stroke(
                                            .white.opacity(selected ? 0 : 0.24),
                                            lineWidth: 0.7
                                        )
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(camera.isBusy || !selectable)
                        .opacity(selectable ? 1 : 0.28)
                        .accessibilityLabel("ズーム \(factorLabel(factor))")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 33)

            Text(camera.zoomFactorText)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(camera.zoomFactorText)
        .accessibilityHint("倍率をタップして切替。画面のピンチ操作で微調整できます。")
    }

    private func factorLabel(_ factor: Double) -> String {
        if abs(factor.rounded() - factor) < 0.04 {
            return "\(Int(factor.rounded()))×"
        }
        return String(format: "%.1f×", factor)
    }
}

private struct FullWidthCaptureReturnButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("撮影へ", systemImage: "camera.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityHint("撮影画面へ戻ります")
    }
}

private struct CaptureSettingsView: View {
    @ObservedObject var camera: CameraController
    let previewImage: CGImage?
    let onDone: () -> Void

    @State private var showShutterDetail = false
    @State private var showISODetail = false
    @State private var showTemperatureDetail = false
    @State private var showPresets = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()

            SettingsSnapshotPreview(image: previewImage)
                .ignoresSafeArea()

            VStack(spacing: 2) {
                Spacer(minLength: 0)

                header

                CompactChoiceRow(
                    title: "撮影",
                    selection: $camera.captureMode,
                    options: CaptureMode.allCases,
                    label: { $0.rawValue },
                    icon: { $0 == .photo ? "camera.fill" : "video.fill" }
                )

                if camera.captureMode == .photo {
                    photoSettings
                } else {
                    videoSettings
                }

                commonCameraSettings
                footer
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 780)
        }
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showShutterDetail) {
            ShutterDetailView(camera: camera)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showISODetail) {
            ISODetailView(camera: camera)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showTemperatureDetail) {
            WhiteBalanceTemperatureDetailView(camera: camera)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPresets) {
            CameraPresetSheet(camera: camera)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("撮影設定")
                    .font(.headline)
                Label("ライブ表示中・設定は自動保存", systemImage: "camera.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                showPresets = true
            } label: {
                Label("プリセット", systemImage: "bookmark.fill")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .tint(.white)
        }
        .foregroundStyle(.white)
        .settingsTextOutline()
        .frame(height: 32)
        .padding(.horizontal, 7)
        .background(
            Color.black.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.6)
        }
    }

    private var footer: some View {
        FullWidthCaptureReturnButton(action: onDone)
    }

    @ViewBuilder
    private var photoSettings: some View {
        CompactChoiceRow(
            title: "保存形式",
            selection: $camera.photoFormat,
            options: PhotoFileFormat.allCases,
            label: { $0.shortTitle },
            icon: { photoFormatIcon($0) },
            detail: { camera.estimatedPhotoChoiceSizeText(format: $0) }
        )

        CompactGridChoiceRow(
            title: "画像サイズ",
            selection: $camera.photoResolution,
            options: PhotoResolution.allCases,
            columnCount: 6,
            label: { $0.shortTitle },
            detail: { camera.estimatedPhotoChoiceSizeText(resolution: $0) }
        )

        if camera.photoFormat == .png {
            CompactReadOnlyRow(title: "圧縮品質", value: "可逆圧縮（劣化なし）")
        } else {
            CompactChoiceRow(
                title: "圧縮品質",
                selection: $camera.photoLossyQuality,
                options: [0.50, 0.65, 0.78, 0.90, 1.00],
                label: { "\(Int(($0 * 100).rounded()))%" },
                detail: { camera.estimatedPhotoChoiceSizeText(lossyQuality: $0) }
            )
        }
    }

    @ViewBuilder
    private var videoSettings: some View {
        CompactGridChoiceRow(
            title: "画像サイズ",
            selection: $camera.videoResolution,
            options: VideoResolution.allCases,
            columnCount: 5,
            label: { $0.shortTitle }
        )

        CompactChoiceRow(
            title: "FPS",
            selection: $camera.videoFrameRate,
            options: VideoFrameRate.allCases,
            label: { "\($0.rawValue)" },
            icon: { _ in "speedometer" }
        )

        CompactChoiceRow(
            title: "圧縮方式",
            selection: $camera.videoCodec,
            options: camera.availableVideoCodecs,
            label: { $0.shortTitle },
            icon: { videoCodecIcon($0) }
        )

        if camera.videoCodec.supportsBitRateSelection {
            CompactChoiceRow(
                title: "ビットレート",
                selection: $camera.videoBitRate,
                options: VideoBitRate.allCases,
                label: { $0.shortTitle },
                icon: { _ in "waveform" },
                detail: { camera.estimatedVideoChoiceSizeText(bitRate: $0) }
            )
        } else {
            CompactReadOnlyRow(
                title: "ビットレート",
                value: "自動・\(camera.estimatedVideoSizeText)"
            )
        }

        CompactChoiceRow(
            title: "色差",
            selection: $camera.videoChromaMode,
            options: VideoChromaMode.allCases,
            label: { $0.compactTitle },
            icon: { videoChromaIcon($0) }
        )

        CompactChoiceRow(
            title: "音声",
            selection: $camera.includeAudio,
            options: [true, false],
            label: { $0 ? "あり" : "なし" },
            icon: { $0 ? "speaker.wave.2.fill" : "speaker.slash.fill" },
            detail: { camera.estimatedVideoChoiceSizeText(includeAudio: $0) }
        )
        .disabled(!camera.microphoneAvailable)
    }

    @ViewBuilder
    private var commonCameraSettings: some View {
        CompactChoiceRow(
            title: "色の細かさ",
            selection: $camera.colorLevels,
            options: ColorLevels.allCases,
            label: { $0.shortTitle },
            detail: { option in
                camera.captureMode == .photo
                    ? camera.estimatedPhotoChoiceSizeText(colorLevels: option)
                    : nil
            }
        )

        CompactChoiceRow(
            title: "コントラスト",
            selection: $camera.contrast,
            options: ImageContrast.allCases,
            label: { $0.shortTitle }
        )

        PixelUpscaleSettingRow(camera: camera)

        CompactSwitchValueRow(
            title: "写真アプリ",
            isOn: $camera.saveToPhotoLibraryEnabled,
            value: camera.saveToPhotoLibraryEnabled ? "同時保存" : "アプリ内のみ"
        )

        ISOControlRow(camera: camera) {
            showISODetail = true
        }

        ExposureBiasSettingRow(camera: camera)

        ShutterControlRow(camera: camera) {
            showShutterDetail = true
        }

        CompactChoiceRow(
            title: "WB方式",
            selection: $camera.whiteBalanceAdjustmentMode,
            options: WhiteBalanceAdjustmentMode.allCases,
            label: { $0.rawValue },
            icon: { $0 == .preset ? "camera.fill" : "thermometer.sun.fill" }
        )

        if camera.whiteBalanceAdjustmentMode == .preset {
            CompactChoiceRow(
                title: "WB",
                selection: $camera.whiteBalancePreset,
                options: WhiteBalancePreset.allCases,
                label: { $0.shortTitle },
                icon: { whiteBalanceIcon($0) }
            )
        } else {
            CompactActionRow(
                title: "色温度",
                value: "\(Int(camera.whiteBalanceTemperature.rounded())) K・色かぶり \(String(format: "%+.0f", camera.whiteBalanceTint))",
                buttonTitle: "変更"
            ) {
                showTemperatureDetail = true
            }
        }

        CorrectionsSettingRow(camera: camera)
    }
}

private struct CameraPresetSheet: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss
    @State private var presetName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("現在の設定を保存") {
                    HStack {
                        TextField("プリセット名", text: $presetName)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .onSubmit(savePreset)

                        Button("保存", action: savePreset)
                            .disabled(trimmedName.isEmpty)
                    }

                    Text("同じ名前で保存すると、そのプリセットを現在の設定で更新します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("保存済みプリセット") {
                    if camera.savedPresets.isEmpty {
                        ContentUnavailableView(
                            "プリセットはありません",
                            systemImage: "bookmark",
                            description: Text("上の欄に名前を入力して保存できます。")
                        )
                    } else {
                        ForEach(camera.savedPresets) { preset in
                            Button {
                                camera.applyPreset(preset)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(preset.name)
                                            .font(.body.weight(.semibold))
                                        Text(preset.summary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.down.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    camera.deletePreset(id: preset.id)
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("設定プリセット")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private var trimmedName: String {
        presetName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func savePreset() {
        guard camera.savePreset(named: trimmedName) else { return }
        presetName = ""
    }
}

private struct SettingsSnapshotPreview: View {
    let image: CGImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black

                if let image {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 30, weight: .light))
                        Text("直前プレビューはありません")
                            .font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.12),
                        Color.clear,
                        Color.clear,
                        Color.black.opacity(0.10)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct CompactChoiceRow<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    let icon: ((Option) -> String?)?
    let detail: ((Option) -> String?)?

    init(
        title: String,
        selection: Binding<Option>,
        options: [Option],
        label: @escaping (Option) -> String,
        icon: ((Option) -> String?)? = nil,
        detail: ((Option) -> String?)? = nil
    ) {
        self.title = title
        _selection = selection
        self.options = options
        self.label = label
        self.icon = icon
        self.detail = detail
    }

    var body: some View {
        let style = settingVisualStyle(for: title)
        HStack(spacing: 5) {
            settingLabel(title)
            HStack(spacing: 3) {
                ForEach(options, id: \.self) { option in
                    let selected = selection == option
                    let detailText = detail?(option)
                    let iconName = icon?(option)
                    Button {
                        selection = option
                    } label: {
                        VStack(spacing: 0) {
                            HStack(spacing: 2) {
                                Image(systemName: iconName ?? (selected ? "checkmark.circle.fill" : "circle"))
                                    .font(.system(size: detailText == nil ? 9 : 7.8, weight: .semibold))
                                    .foregroundStyle(
                                        selected
                                            ? style.tint
                                            : Color.secondary.opacity(iconName == nil ? 0.48 : 0.82)
                                    )
                                Text(label(option))
                                    .font(.system(
                                        size: detailText == nil ? 10.2 : 9.0,
                                        weight: selected ? .semibold : .regular
                                    ))
                            }
                            if let detailText, !detailText.isEmpty {
                                Text(detailText)
                                    .font(.system(size: 6.8, weight: .medium).monospacedDigit())
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                            .lineLimit(1)
                            .minimumScaleFactor(0.48)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .background(
                                selected
                                    ? style.tint.opacity(0.24)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(
                                        selected ? style.tint.opacity(0.82) : Color.clear,
                                        lineWidth: 1.15
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .compactSettingContainer(title: title)
    }
}

private struct CompactGridChoiceRow<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let columnCount: Int
    let label: (Option) -> String
    let detail: ((Option) -> String?)?

    init(
        title: String,
        selection: Binding<Option>,
        options: [Option],
        columnCount: Int,
        label: @escaping (Option) -> String,
        detail: ((Option) -> String?)? = nil
    ) {
        self.title = title
        _selection = selection
        self.options = options
        self.columnCount = columnCount
        self.label = label
        self.detail = detail
    }

    var body: some View {
        let style = settingVisualStyle(for: title)
        HStack(alignment: .top, spacing: 5) {
            settingLabel(title)
                .padding(.top, 20)

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 3),
                    count: columnCount
                ),
                spacing: 3
            ) {
                ForEach(options, id: \.self) { option in
                    let selected = selection == option
                    let detailText = detail?(option)
                    Button {
                        selection = option
                    } label: {
                        VStack(spacing: 0) {
                            HStack(spacing: 1.5) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: detailText == nil ? 7.2 : 6.2, weight: .semibold))
                                    .foregroundStyle(
                                        selected ? style.tint : Color.secondary.opacity(0.48)
                                    )
                                Text(label(option))
                                    .font(.system(
                                        size: detailText == nil ? 9.4 : 8.1,
                                        weight: selected ? .semibold : .regular
                                    ))
                            }
                            if let detailText, !detailText.isEmpty {
                                Text(detailText)
                                    .font(.system(size: 6.0, weight: .medium).monospacedDigit())
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                            .lineLimit(1)
                            .minimumScaleFactor(0.42)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .background(
                                selected
                                    ? style.tint.opacity(0.24)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(
                                        selected ? style.tint.opacity(0.82) : Color.clear,
                                        lineWidth: 1.1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .compactSettingContainer(title: title, height: 70)
    }
}

private struct CompactReadOnlyRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            settingLabel(title)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            Spacer(minLength: 0)
        }
        .compactSettingContainer(title: title)
    }
}

private struct CompactActionRow: View {
    let title: String
    let value: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            settingLabel(title)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
            Spacer(minLength: 2)
            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(settingVisualStyle(for: title).tint)
        }
        .compactSettingContainer(title: title)
    }
}

private struct CompactSwitchValueRow: View {
    let title: String
    @Binding var isOn: Bool
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            settingLabel(title)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .scaleEffect(0.74)
                .frame(width: 42)
                .tint(settingVisualStyle(for: title).tint)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .compactSettingContainer(title: title)
    }
}

private struct PixelUpscaleSettingRow: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        let style = settingVisualStyle(for: "出力倍率")
        let applies = camera.captureMode == .video || camera.photoFormat == .png
        let showsSizeEstimate = camera.captureMode == .photo && camera.photoFormat == .png
        HStack(spacing: 5) {
            settingLabel("出力倍率")
            HStack(spacing: 3) {
                ForEach(PixelUpscaleFactor.allCases) { factor in
                    let selected = camera.pixelUpscaleFactor == factor
                    let supported = camera.isPixelUpscaleFactorSupported(factor)
                    Button {
                        camera.pixelUpscaleFactor = factor
                    } label: {
                        VStack(spacing: 0) {
                            HStack(spacing: 2) {
                                Image(systemName: selected ? "checkmark.circle.fill" : "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 7.5, weight: .semibold))
                                    .foregroundStyle(selected ? style.tint : Color.secondary.opacity(0.75))
                                Text(factor.title)
                                    .font(.system(size: showsSizeEstimate ? 8.8 : 10, weight: selected ? .semibold : .regular))
                            }
                            if showsSizeEstimate {
                                Text(camera.estimatedPhotoChoiceSizeText(upscaleFactor: factor))
                                .font(.system(size: 6.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(Color.secondary)
                            }
                        }
                            .lineLimit(1)
                            .minimumScaleFactor(0.46)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(
                                selected
                                    ? style.tint.opacity(0.24)
                                    : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(
                                        selected ? style.tint.opacity(0.82) : Color.clear,
                                        lineWidth: 1.1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!supported || !applies)
                    .opacity(supported && applies ? 1 : 0.3)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .compactSettingContainer(title: "出力倍率")
        .accessibilityHint(applies ? "最近傍法で整数倍保存" : "PNGのときだけ写真へ適用")
    }
}

private struct ExposureBiasSettingRow: View {
    @ObservedObject var camera: CameraController
    private let thirdStop = 1.0 / 3.0

    var body: some View {
        let style = settingVisualStyle(for: "露出補正")
        let enabled = camera.exposureBiasIsEnabled
        HStack(spacing: 5) {
            settingLabel("露出補正")
            HStack(spacing: 3) {
                adjustmentButton(title: "−1段", delta: -1, enabled: enabled)
                adjustmentButton(title: "−⅓", delta: -thirdStop, enabled: enabled)

                Button {
                    camera.exposureBias = 0
                } label: {
                    Text(String(format: "%+.1f", camera.exposureBias))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            style.tint.opacity(0.24),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!enabled)

                adjustmentButton(title: "+⅓", delta: thirdStop, enabled: enabled)
                adjustmentButton(title: "+1段", delta: 1, enabled: enabled)
            }
            .frame(maxWidth: .infinity)
            .opacity(enabled ? 1 : 0.32)
        }
        .compactSettingContainer(title: "露出補正")
    }

    private func adjustmentButton(title: String, delta: Double, enabled: Bool) -> some View {
        let withinRange = delta < 0
            ? camera.exposureBias > camera.minimumExposureBias + 0.001
            : camera.exposureBias < camera.maximumExposureBias - 0.001
        let active = enabled && withinRange
        return Button {
            let snapped = (camera.exposureBias / thirdStop).rounded() * thirdStop
            let adjusted = min(
                max(snapped + delta, camera.minimumExposureBias),
                camera.maximumExposureBias
            )
            camera.exposureBias = abs(adjusted) < 0.000_1 ? 0 : adjusted
        } label: {
            stopButtonLabel(title)
        }
        .buttonStyle(.plain)
        .disabled(!active)
        .opacity(active ? 1 : 0.3)
    }
}

private struct ISOControlRow: View {
    @ObservedObject var camera: CameraController
    let onDetail: () -> Void

    var body: some View {
        let style = settingVisualStyle(for: "ISO")
        HStack(spacing: 5) {
            settingLabel("ISO")
            lockButton(title: "固定", isLocked: camera.isISOLocked) {
                camera.toggleISOLock()
            }
            HStack(spacing: 3) {
                adjustmentButton(title: "−1段", indexDelta: -3)
                adjustmentButton(title: "−⅓", indexDelta: -1)
                Button(action: onDetail) {
                    Text("\(Int((camera.isISOLocked ? camera.iso : camera.measuredISO).rounded()))")
                        .font(.system(size: 9.7, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            style.tint.opacity(0.24),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!camera.isISOLocked)
                adjustmentButton(title: "+⅓", indexDelta: 1)
                adjustmentButton(title: "+1段", indexDelta: 3)
            }
            .frame(maxWidth: .infinity)
            .opacity(camera.isISOLocked ? 1 : 0.3)
        }
        .compactSettingContainer(title: "ISO")
    }

    private func adjustmentButton(title: String, indexDelta: Int) -> some View {
        let values = camera.isoStepValues
        let current = nearestIndex(to: camera.iso, in: values)
        let destination = current + indexDelta
        let enabled = camera.isISOLocked
            && !values.isEmpty
            && destination >= 0
            && destination < values.count
        return Button {
            guard enabled else { return }
            camera.iso = values[destination]
        } label: {
            stopButtonLabel(title)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct ShutterControlRow: View {
    @ObservedObject var camera: CameraController
    let onDetail: () -> Void

    var body: some View {
        let style = settingVisualStyle(for: "シャッター")
        HStack(spacing: 5) {
            settingLabel("シャッター")
            lockButton(title: "固定", isLocked: camera.isShutterLocked) {
                camera.toggleShutterLock()
            }
            HStack(spacing: 3) {
                adjustmentButton(title: "−1段", indexDelta: -3)
                adjustmentButton(title: "−⅓", indexDelta: -1)
                Button(action: onDetail) {
                    Text(camera.formatShutter(
                        camera.isShutterLocked
                            ? camera.shutterSeconds
                            : camera.measuredShutterSeconds
                    ))
                    .font(.system(size: 8.8, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        style.tint.opacity(0.24),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!camera.isShutterLocked)
                adjustmentButton(title: "+⅓", indexDelta: 1)
                adjustmentButton(title: "+1段", indexDelta: 3)
            }
            .frame(maxWidth: .infinity)
            .opacity(camera.isShutterLocked ? 1 : 0.3)
        }
        .compactSettingContainer(title: "シャッター")
    }

    private func adjustmentButton(title: String, indexDelta: Int) -> some View {
        let values = camera.shutterStepValues
        let current = nearestIndex(to: camera.shutterSeconds, in: values)
        let destination = current + indexDelta
        let enabled = camera.isShutterLocked
            && !values.isEmpty
            && destination >= 0
            && destination < values.count
        return Button {
            guard enabled else { return }
            camera.shutterSeconds = values[destination]
        } label: {
            stopButtonLabel(title)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct CorrectionsSettingRow: View {
    @ObservedObject var camera: CameraController

    var body: some View {
        HStack(spacing: 5) {
            settingLabel("補正")
            HStack(spacing: 3) {
                toggleChip("手ぶれ", isOn: $camera.stabilizationEnabled)
                toggleChip("レンズ", isOn: $camera.lensCorrectionEnabled)
                toggleChip("HDR", isOn: $camera.hdrEnabled)
                toggleChip("暗所", isOn: $camera.lowLightBoostEnabled)
                toggleChip("質感抑制", isOn: $camera.minimizeTextureProcessing)
            }
            .frame(maxWidth: .infinity)
        }
        .compactSettingContainer(title: "補正")
    }

    private func toggleChip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 8.8, weight: isOn.wrappedValue ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    isOn.wrappedValue
                        ? settingVisualStyle(for: "補正").tint.opacity(0.24)
                        : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SteppedStopControl: View {
    let values: [Double]
    @Binding var value: Double
    let valueText: (Double) -> String

    var body: some View {
        HStack(spacing: 6) {
            adjustmentButton(title: "−1段", indexDelta: -3)
            adjustmentButton(title: "−⅓", indexDelta: -1)
            Text(valueText(value))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.62)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(
                    Color.accentColor.opacity(0.20),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            adjustmentButton(title: "+⅓", indexDelta: 1)
            adjustmentButton(title: "+1段", indexDelta: 3)
        }
    }

    private var currentIndex: Int { nearestIndex(to: value, in: values) }

    private func adjustmentButton(title: String, indexDelta: Int) -> some View {
        let destination = currentIndex + indexDelta
        let enabled = !values.isEmpty && destination >= 0 && destination < values.count
        return Button {
            guard enabled else { return }
            value = values[destination]
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.66)
                .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!enabled)
    }
}

private struct ShutterDetailView: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                HStack {
                    Text(camera.isShutterLocked ? "シャッター固定中" : "シャッター自動")
                    Spacer()
                    Button(camera.isShutterLocked ? "固定解除" : "現在値で固定") {
                        camera.toggleShutterLock()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Picker("操作", selection: $camera.cameraControlAdjustmentStyle) {
                    ForEach(CameraControlAdjustmentStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                if camera.isShutterLocked {
                    HStack {
                        Text("シャッタースピード")
                        Spacer()
                        Text(camera.formatShutter(camera.shutterSeconds)).monospacedDigit()
                    }
                    if camera.cameraControlAdjustmentStyle == .stepped {
                        SteppedStopControl(
                            values: camera.shutterStepValues,
                            value: $camera.shutterSeconds,
                            valueText: { camera.formatShutter($0) }
                        )
                    } else {
                        Slider(value: shutterLogBinding, in: shutterLogRange)
                    }
                } else {
                    ContentUnavailableView(
                        "シャッターは自動",
                        systemImage: "camera.aperture",
                        description: Text("現在 \(camera.formatShutter(camera.measuredShutterSeconds))")
                    )
                }
                Spacer()
            }
            .padding()
            .navigationTitle("シャッター")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }

    private var shutterLogBinding: Binding<Double> {
        Binding(
            get: { log2(max(camera.shutterSeconds, camera.minimumShutterSeconds)) },
            set: {
                camera.shutterSeconds = min(
                    max(pow(2, $0), camera.minimumShutterSeconds),
                    camera.maximumShutterSeconds
                )
            }
        )
    }

    private var shutterLogRange: ClosedRange<Double> {
        let lower = log2(max(camera.minimumShutterSeconds, 0.000_001))
        let upper = log2(max(camera.maximumShutterSeconds, camera.minimumShutterSeconds))
        return lower...max(lower + 0.000_001, upper)
    }
}

private struct ISODetailView: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                HStack {
                    Text(camera.isISOLocked ? "ISO固定中" : "ISO自動")
                    Spacer()
                    Button(camera.isISOLocked ? "固定解除" : "現在値で固定") {
                        camera.toggleISOLock()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Picker("操作", selection: $camera.cameraControlAdjustmentStyle) {
                    ForEach(CameraControlAdjustmentStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                if camera.isISOLocked {
                    HStack {
                        Text("ISO感度")
                        Spacer()
                        Text("\(Int(camera.iso.rounded()))").monospacedDigit()
                    }
                    if camera.cameraControlAdjustmentStyle == .stepped {
                        SteppedStopControl(
                            values: camera.isoStepValues,
                            value: $camera.iso,
                            valueText: { "\(Int($0.rounded()))" }
                        )
                    } else {
                        Slider(value: isoLogBinding, in: isoLogRange)
                    }
                } else {
                    ContentUnavailableView(
                        "ISOは自動",
                        systemImage: "camera.metering.center.weighted",
                        description: Text("現在 ISO \(Int(camera.measuredISO.rounded()))")
                    )
                }
                Spacer()
            }
            .padding()
            .navigationTitle("ISO感度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }

    private var isoLogBinding: Binding<Double> {
        Binding(
            get: { log2(max(camera.iso, camera.minimumISO)) },
            set: {
                camera.iso = min(
                    max(pow(2, $0), camera.minimumISO),
                    camera.maximumISO
                )
            }
        )
    }

    private var isoLogRange: ClosedRange<Double> {
        let lower = log2(max(camera.minimumISO, 1))
        let upper = log2(max(camera.maximumISO, camera.minimumISO))
        return lower...max(lower + 0.000_001, upper)
    }
}

private struct WhiteBalanceTemperatureDetailView: View {
    @ObservedObject var camera: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Picker("操作", selection: $camera.cameraControlAdjustmentStyle) {
                    ForEach(CameraControlAdjustmentStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                valueHeader(title: "色温度", value: "\(Int(camera.whiteBalanceTemperature.rounded())) K")
                Slider(
                    value: temperatureBinding,
                    in: 2_500...10_000,
                    step: camera.cameraControlAdjustmentStyle == .stepped ? 100 : 1
                )

                valueHeader(title: "色かぶり", value: String(format: "%+.0f", camera.whiteBalanceTint))
                Slider(
                    value: tintBinding,
                    in: -150...150,
                    step: camera.cameraControlAdjustmentStyle == .stepped ? 5 : 1
                )
                Spacer()
            }
            .padding()
            .navigationTitle("色温度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
        .onAppear {
            camera.whiteBalanceAdjustmentMode = .temperature
        }
    }

    private func valueHeader(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { camera.whiteBalanceTemperature },
            set: { camera.whiteBalanceTemperature = $0 }
        )
    }

    private var tintBinding: Binding<Double> {
        Binding(
            get: { camera.whiteBalanceTint },
            set: { camera.whiteBalanceTint = $0 }
        )
    }
}

private struct AppMediaGalleryView: View {
    @StateObject private var library = AppMediaLibraryModel()
    @State private var selectedItemID: UUID?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("このアプリの写真・動画")
                            .font(.headline)
                        Text("アプリ内保存・写真ライブラリの読み取り不要")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if library.isLoading {
                        ProgressView()
                    }
                }
                .padding()
                .background(.bar)

                galleryContent

                VStack(spacing: 7) {
                    Text("使用量 \(library.totalSizeText)・削除は詳細画面から")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    FullWidthCaptureReturnButton(action: onClose)
                }
                .padding(12)
                .background(.bar)
            }

            if let selectedItemID {
                MediaAssetViewer(
                    items: library.items,
                    initialID: selectedItemID,
                    onClose: {
                        self.selectedItemID = nil
                    },
                    onCapture: onClose,
                    onDelete: { item in
                        library.delete(item)
                        self.selectedItemID = nil
                    },
                    onExported: { item in
                        library.markPhotoLibraryExported(item)
                    }
                )
                .transition(.opacity)
                .zIndex(5)
            }
        }
        .onAppear {
            library.reload()
        }
    }

    @ViewBuilder
    private var galleryContent: some View {
        if let errorMessage = library.errorMessage {
            ContentUnavailableView(
                "アプリ内データを読み込めません",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if library.items.isEmpty, !library.isLoading {
            ContentUnavailableView(
                "写真・動画はまだありません",
                systemImage: "photo.stack",
                description: Text("次に撮影した写真・動画からアプリ内へ保存されます。")
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 118, maximum: 220), spacing: 3)
                    ],
                    spacing: 3
                ) {
                    ForEach(library.items) { item in
                        Button {
                            selectedItemID = item.id
                        } label: {
                            AppMediaThumbnailView(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .frame(maxWidth: 1_200)
                .frame(maxWidth: .infinity)
            }
            .refreshable {
                library.reload()
            }
        }
    }
}

private let mediaViewerBottomControlsInset: CGFloat = 78

private struct MediaAssetViewer: View {
    let items: [AppMediaItem]
    let onClose: () -> Void
    let onCapture: () -> Void
    let onDelete: (AppMediaItem) -> Void
    let onExported: (AppMediaItem) -> Void
    @State private var selectedID: UUID
    @State private var showDeleteConfirmation = false
    @State private var isExporting = false
    @State private var exportMessage: String?
    @State private var exportedIDs: Set<UUID>

    init(
        items: [AppMediaItem],
        initialID: UUID,
        onClose: @escaping () -> Void,
        onCapture: @escaping () -> Void,
        onDelete: @escaping (AppMediaItem) -> Void,
        onExported: @escaping (AppMediaItem) -> Void
    ) {
        self.items = items
        self.onClose = onClose
        self.onCapture = onCapture
        self.onDelete = onDelete
        self.onExported = onExported
        _selectedID = State(initialValue: initialID)
        _exportedIDs = State(initialValue: Set(
            items.filter { $0.photoLibraryExported == true }.map(\.id)
        ))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedID) {
                ForEach(items) { item in
                    MediaAssetPage(
                        item: item,
                        isActive: selectedID == item.id,
                        bottomControlsInset: mediaViewerBottomControlsInset
                    )
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)

                    if let item = selectedItem {
                        VStack(alignment: .leading, spacing: 1) {
                            Label(
                                itemInformation(item),
                                systemImage: item.kind.symbolName
                            )
                            .font(.caption.monospacedDigit())
                            Text("容量 \(fileSizeText(item))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.82))
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )

                        Button(action: onClose) {
                            Image(systemName: "square.grid.3x3.fill")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.gray.opacity(0.72))
                        .accessibilityLabel("一覧へ戻る")

                        Button {
                            exportSelectedItem()
                        } label: {
                            if isExporting {
                                ProgressView()
                                    .tint(.white)
                                    .frame(width: 28, height: 28)
                            } else if exportedIDs.contains(item.id) {
                                Image(systemName: "checkmark")
                                    .frame(width: 28, height: 28)
                            } else {
                                Image(systemName: "photo.badge.plus")
                                    .frame(width: 28, height: 28)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isExporting || exportedIDs.contains(item.id))
                        .accessibilityLabel(
                            exportedIDs.contains(item.id)
                                ? "写真アプリへ保存済み"
                                : "写真アプリへ保存"
                        )

                        Button {
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red.opacity(0.78))
                        .accessibilityLabel("アプリ内から削除")
                    }
                }

                HStack {
                    navigationButton(systemImage: "chevron.left", offset: -1)
                    Spacer()
                    Text("\(selectedIndex + 1) / \(items.count)・左右スワイプ")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    navigationButton(systemImage: "chevron.right", offset: 1)
                }

                Spacer()

                FullWidthCaptureReturnButton(action: onCapture)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .confirmationDialog(
            "アプリ内から削除しますか？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                if let selectedItem {
                    onDelete(selectedItem)
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("写真アプリへ同時保存したコピーがある場合、そのコピーは削除されません。")
        }
        .alert(
            "写真アプリへの保存",
            isPresented: Binding(
                get: { exportMessage != nil },
                set: { if !$0 { exportMessage = nil } }
            )
        ) {
            Button("OK") { exportMessage = nil }
        } message: {
            Text(exportMessage ?? "")
        }
    }

    private var selectedIndex: Int {
        items.firstIndex { $0.id == selectedID } ?? 0
    }

    private var selectedItem: AppMediaItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    private func itemInformation(_ item: AppMediaItem) -> String {
        let dimensions = "\(item.pixelWidth)×\(item.pixelHeight)"
        if item.kind == .video {
            return "\(dimensions)・\(item.duration.compactDurationText)"
        }
        return dimensions
    }

    private func fileSizeText(_ item: AppMediaItem) -> String {
        Self.fileSizeFormatter.string(fromByteCount: item.fileSizeBytes)
    }

    private static let fileSizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()

    private func exportSelectedItem() {
        guard let selectedItem, !isExporting else { return }
        isExporting = true
        PhotoLibraryExporter.export(selectedItem) { result in
            DispatchQueue.main.async {
                self.isExporting = false
                switch result {
                case .success:
                    self.exportedIDs.insert(selectedItem.id)
                    self.onExported(selectedItem)
                    self.exportMessage = "写真アプリへ保存しました。"
                case let .failure(error):
                    self.exportMessage = error.localizedDescription
                }
            }
        }
    }

    private func navigationButton(systemImage: String, offset: Int) -> some View {
        let destination = selectedIndex + offset
        let enabled = items.indices.contains(destination)
        return Button {
            guard enabled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                selectedID = items[destination].id
            }
        } label: {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: 34, height: 28)
        }
        .buttonStyle(.borderedProminent)
        .tint(.gray.opacity(0.72))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.28)
    }
}

private struct MediaAssetPage: View {
    let item: AppMediaItem
    let isActive: Bool
    let bottomControlsInset: CGFloat

    @ViewBuilder
    var body: some View {
        if item.kind == .video {
            VideoAssetPage(
                item: item,
                isActive: isActive,
                bottomControlsInset: bottomControlsInset
            )
        } else {
            PhotoAssetPage(
                item: item,
                isActive: isActive,
                bottomControlsInset: bottomControlsInset
            )
        }
    }
}

private struct PhotoAssetPage: View {
    let item: AppMediaItem
    let isActive: Bool
    let bottomControlsInset: CGFloat
    @StateObject private var loader = LocalMediaImageLoader()
    @State private var zoomScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black
            if let image = loader.image {
                PixelZoomScrollView(image: image, zoomScale: $zoomScale)
                    .ignoresSafeArea()
            } else if loader.isLoading {
                ProgressView("写真を読み込み中…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }

            VStack {
                Spacer()
                MediaZoomControls(zoomScale: $zoomScale, maximumScale: 16)
                    .padding(.bottom, bottomControlsInset)
            }
        }
        .onAppear {
            loader.loadFullImage(item: item)
        }
        .onChange(of: isActive) { _, active in
            if !active {
                zoomScale = 1
            }
        }
    }
}

private struct VideoAssetPage: View {
    let item: AppMediaItem
    let isActive: Bool
    let bottomControlsInset: CGFloat
    @StateObject private var loader = VideoAssetPlayerLoader()
    @State private var zoomScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black
            if let player = loader.player {
                ZoomableVideoSurface(player: player, zoomScale: $zoomScale)
                    .ignoresSafeArea()

                if !loader.isPlaying {
                    Button {
                        loader.togglePlayback()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 76, height: 76)
                            .background(.black.opacity(0.52), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("動画を再生")
                }
            } else if loader.isLoading {
                ProgressView("動画を読み込み中…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else if let errorMessage = loader.errorMessage {
                ContentUnavailableView(
                    "動画を表示できません",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
                .foregroundStyle(.white)
            }

            VStack(spacing: 7) {
                Spacer()
                if loader.player != nil {
                    playbackControls
                }
                MediaZoomControls(zoomScale: $zoomScale, maximumScale: 8)
            }
            .padding(.bottom, bottomControlsInset)
        }
        .onAppear {
            loader.load(item: item)
        }
        .onDisappear {
            loader.pause()
        }
        .onChange(of: isActive) { _, active in
            if !active {
                loader.pause()
                zoomScale = 1
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 9) {
            Button {
                loader.togglePlayback()
            } label: {
                Image(systemName: loader.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            Slider(value: playbackPosition)
                .tint(.white)

            Text("\(loader.currentTime.compactDurationText) / \(loader.duration.compactDurationText)")
                .font(.caption2.monospacedDigit())
                .frame(minWidth: 72, alignment: .trailing)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 12)
    }

    private var playbackPosition: Binding<Double> {
        Binding(
            get: {
                guard loader.duration > 0 else { return 0 }
                return min(max(loader.currentTime / loader.duration, 0), 1)
            },
            set: { position in
                loader.seek(to: position * loader.duration)
            }
        )
    }
}

private struct ZoomableVideoSurface: View {
    let player: AVPlayer
    @Binding var zoomScale: CGFloat
    @State private var settledOffset: CGSize = .zero
    @GestureState private var pinchFactor: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let effectiveScale = min(max(zoomScale * pinchFactor, 1), 8)
            let proposedOffset = CGSize(
                width: settledOffset.width + dragTranslation.width,
                height: settledOffset.height + dragTranslation.height
            )
            let displayedOffset = clampedOffset(
                proposedOffset,
                scale: effectiveScale,
                size: proxy.size
            )

            PlayerSurface(player: player)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(effectiveScale)
                .offset(displayedOffset)
                .contentShape(Rectangle())
                .simultaneousGesture(magnificationGesture)
                .highPriorityGesture(
                    dragGesture(scale: effectiveScale, size: proxy.size),
                    including: zoomScale > 1.01 ? .all : .none
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        zoomScale = zoomScale > 1.01 ? 1 : 4
                    }
                )
        }
        .clipped()
        .onChange(of: zoomScale) { _, _ in
            settledOffset = .zero
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchFactor) { value, state, _ in
                state = value
            }
            .onEnded { value in
                zoomScale = min(max(zoomScale * value, 1), 8)
            }
    }

    private func dragGesture(scale: CGFloat, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($dragTranslation) { value, state, _ in
                if scale > 1.01 {
                    state = value.translation
                }
            }
            .onEnded { value in
                guard scale > 1.01 else { return }
                let proposed = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
                settledOffset = clampedOffset(proposed, scale: scale, size: size)
            }
    }

    private func clampedOffset(_ offset: CGSize, scale: CGFloat, size: CGSize) -> CGSize {
        let maximumX = max(0, size.width * (scale - 1) / 2)
        let maximumY = max(0, size.height * (scale - 1) / 2)
        return CGSize(
            width: min(max(offset.width, -maximumX), maximumX),
            height: min(max(offset.height, -maximumY), maximumY)
        )
    }
}

private struct MediaZoomControls: View {
    @Binding var zoomScale: CGFloat
    let maximumScale: CGFloat

    private var steps: [CGFloat] {
        [1, 2, 4, 8, 16].filter { $0 <= maximumScale }
    }

    var body: some View {
        HStack(spacing: 5) {
            Button(action: zoomOut) {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 30, height: 28)
            }
            .accessibilityLabel("縮小")

            ForEach(steps, id: \.self) { factor in
                let selected = abs(zoomScale - factor) < 0.08
                Button {
                    zoomScale = factor
                } label: {
                    Text("\(Int(factor))×")
                        .font(.caption.monospacedDigit().weight(selected ? .bold : .regular))
                        .frame(minWidth: 30, minHeight: 28)
                        .background(
                            selected ? Color.accentColor : Color.black.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
            }

            Button(action: zoomIn) {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 30, height: 28)
            }
            .accessibilityLabel("拡大")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func zoomOut() {
        zoomScale = steps.last(where: { $0 < zoomScale - 0.05 }) ?? 1
    }

    private func zoomIn() {
        zoomScale = steps.first(where: { $0 > zoomScale + 0.05 }) ?? maximumScale
    }
}

private struct SettingVisualStyle {
    let icon: String
    let tint: Color
}

private func photoFormatIcon(_ format: PhotoFileFormat) -> String {
    switch format {
    case .png: "square.grid.3x3.fill"
    case .jpeg: "photo.fill"
    case .heif: "photo.stack.fill"
    }
}

private func videoCodecIcon(_ codec: VideoCodec) -> String {
    switch codec {
    case .hevc: "video.fill"
    case .h264: "film.fill"
    case .proRes4444: "sparkles"
    }
}

private func videoChromaIcon(_ mode: VideoChromaMode) -> String {
    switch mode {
    case .standard: "paintpalette.fill"
    case .reduced: "circle.lefthalf.filled"
    case .strong: "circle.grid.3x3.fill"
    case .monochrome: "circle.righthalf.filled"
    }
}

private func whiteBalanceIcon(_ preset: WhiteBalancePreset) -> String {
    switch preset {
    case .automatic: "wand.and.stars"
    case .daylight: "sun.max.fill"
    case .cloudy: "cloud.sun.fill"
    case .shade: "cloud.fill"
    case .tungsten: "lightbulb.fill"
    case .fluorescent: "bolt.fill"
    }
}

private func settingVisualStyle(for title: String) -> SettingVisualStyle {
    switch title {
    case "撮影":
        SettingVisualStyle(icon: "camera.fill", tint: .blue)
    case "保存形式":
        SettingVisualStyle(icon: "doc.fill", tint: .teal)
    case "画像サイズ":
        SettingVisualStyle(icon: "aspectratio", tint: .indigo)
    case "圧縮品質":
        SettingVisualStyle(icon: "slider.horizontal.3", tint: .orange)
    case "FPS":
        SettingVisualStyle(icon: "speedometer", tint: .purple)
    case "圧縮方式":
        SettingVisualStyle(icon: "film.fill", tint: .pink)
    case "ビットレート":
        SettingVisualStyle(icon: "waveform", tint: .orange)
    case "容量目安":
        SettingVisualStyle(icon: "externaldrive.fill", tint: .brown)
    case "色差":
        SettingVisualStyle(icon: "circle.lefthalf.filled", tint: .pink)
    case "音声":
        SettingVisualStyle(icon: "mic.fill", tint: .green)
    case "色の細かさ":
        SettingVisualStyle(icon: "paintpalette.fill", tint: .pink)
    case "コントラスト":
        SettingVisualStyle(icon: "circle.lefthalf.filled", tint: .yellow)
    case "出力倍率":
        SettingVisualStyle(icon: "arrow.up.left.and.arrow.down.right", tint: .mint)
    case "写真アプリ":
        SettingVisualStyle(icon: "photo.badge.plus", tint: .blue)
    case "ISO":
        SettingVisualStyle(icon: "camera.aperture", tint: .yellow)
    case "露出補正":
        SettingVisualStyle(icon: "plusminus.circle.fill", tint: .orange)
    case "シャッター":
        SettingVisualStyle(icon: "timer", tint: .orange)
    case "WB方式", "WB":
        SettingVisualStyle(icon: "sun.max.fill", tint: .cyan)
    case "色温度":
        SettingVisualStyle(icon: "thermometer.sun.fill", tint: .cyan)
    case "補正":
        SettingVisualStyle(icon: "wand.and.stars", tint: .purple)
    default:
        SettingVisualStyle(icon: "slider.horizontal.3", tint: .gray)
    }
}

private func settingLabel(_ title: String) -> some View {
    let style = settingVisualStyle(for: title)
    return HStack(spacing: 4) {
        Image(systemName: style.icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(style.tint)
            .frame(width: 19, height: 19)
            .background(
                style.tint.opacity(0.15),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )

        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.52)
    }
    .frame(width: 91, alignment: .leading)
}

private func stopButtonLabel(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 8.8, weight: .medium))
        .lineLimit(1)
        .minimumScaleFactor(0.48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Color.secondary)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
}

private func lockButton(
    title: String,
    isLocked: Bool,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        Text(title)
            .font(.system(size: 8.8, weight: isLocked ? .bold : .regular))
            .lineLimit(1)
            .frame(width: 31)
            .frame(maxHeight: .infinity)
            .background(
                isLocked
                    ? Color.orange.opacity(0.34)
                    : Color.secondary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }
    .buttonStyle(.plain)
}

private extension View {
    func settingsTextOutline() -> some View {
        self
            .shadow(color: .black.opacity(0.96), radius: 0, x: -0.7, y: 0)
            .shadow(color: .black.opacity(0.96), radius: 0, x: 0.7, y: 0)
            .shadow(color: .black.opacity(0.96), radius: 0, x: 0, y: -0.7)
            .shadow(color: .black.opacity(0.96), radius: 0, x: 0, y: 0.7)
    }

    func compactSettingContainer(title: String, height: CGFloat = 31) -> some View {
        let style = settingVisualStyle(for: title)
        return self
            .settingsTextOutline()
            .padding(.horizontal, 7)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(style.tint.opacity(0.045))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    }
            )
    }
}

private func nearestIndex(to value: Double, in values: [Double]) -> Int {
    guard !values.isEmpty else { return 0 }
    return values.enumerated().min { left, right in
        let safeValue = max(value, 0.000_001)
        let leftDistance = abs(log2(max(left.element, 0.000_001) / safeValue))
        let rightDistance = abs(log2(max(right.element, 0.000_001) / safeValue))
        return leftDistance < rightDistance
    }?.offset ?? 0
}

#if DEBUG
private struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
