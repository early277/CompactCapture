import AVFoundation
import Foundation
import ImageIO
import Photos
import SwiftUI
import UIKit

enum AppMediaKind: String, Codable, Hashable {
    case image
    case video

    var symbolName: String {
        self == .video ? "video.fill" : "photo.fill"
    }
}

struct AppMediaItem: Identifiable, Codable, Hashable {
    let id: UUID
    let fileName: String
    let kind: AppMediaKind
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let fileSizeBytes: Int64
    var photoLibraryExported: Bool?

    var fileURL: URL {
        AppMediaStore.fileURL(for: fileName)
    }
}

enum AppMediaStore {
    private static let manifestFileName = "media-index-v1.json"
    private static let lock = NSLock()

    private static var mediaDirectoryURL: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("CompactCaptureMedia", isDirectory: true)
    }

    private static var manifestURL: URL {
        mediaDirectoryURL.appendingPathComponent(manifestFileName)
    }

    static func fileURL(for fileName: String) -> URL {
        let safeFileName = (fileName as NSString).lastPathComponent
        return mediaDirectoryURL.appendingPathComponent(safeFileName, isDirectory: false)
    }

    static func savePhoto(
        data: Data,
        fileExtension: String
    ) throws -> AppMediaItem {
        try withLock {
            try prepareDirectory()
            let fileName = makeFileName(fileExtension: fileExtension)
            let destination = fileURL(for: fileName)
            try data.write(to: destination, options: .atomic)

            let dimensions = imageDimensions(from: data)
            let item = AppMediaItem(
                id: UUID(),
                fileName: fileName,
                kind: .image,
                createdAt: Date(),
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height,
                duration: 0,
                fileSizeBytes: Int64(data.count),
                photoLibraryExported: false
            )

            do {
                var items = try readManifest()
                items.insert(item, at: 0)
                try writeManifest(items)
                return item
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    static func saveVideo(
        from temporaryURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval
    ) throws -> AppMediaItem {
        try withLock {
            try prepareDirectory()
            let fileName = makeFileName(fileExtension: temporaryURL.pathExtension.isEmpty ? "mov" : temporaryURL.pathExtension)
            let destination = fileURL(for: fileName)
            try FileManager.default.copyItem(at: temporaryURL, to: destination)

            let storedSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init) ?? 0
            let item = AppMediaItem(
                id: UUID(),
                fileName: fileName,
                kind: .video,
                createdAt: Date(),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                duration: max(duration, 0),
                fileSizeBytes: storedSize,
                photoLibraryExported: false
            )

            do {
                var items = try readManifest()
                items.insert(item, at: 0)
                try writeManifest(items)
                try? FileManager.default.removeItem(at: temporaryURL)
                return item
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }

    static func loadItems() throws -> [AppMediaItem] {
        try withLock {
            try prepareDirectory()
            let stored = try readManifest()
            let existing = stored.filter {
                FileManager.default.fileExists(atPath: fileURL(for: $0.fileName).path)
            }
            if existing.count != stored.count {
                try writeManifest(existing)
            }
            return existing.sorted { $0.createdAt > $1.createdAt }
        }
    }

    static func delete(_ item: AppMediaItem) throws {
        try withLock {
            try prepareDirectory()
            let url = fileURL(for: item.fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let remaining = try readManifest().filter { $0.id != item.id }
            try writeManifest(remaining)
        }
    }

    static func markPhotoLibraryExported(_ item: AppMediaItem) throws {
        try withLock {
            try prepareDirectory()
            var items = try readManifest()
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[index].photoLibraryExported = true
            try writeManifest(items)
        }
    }

    private static func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: mediaDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    private static func readManifest() throws -> [AppMediaItem] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode([AppMediaItem].self, from: data)
    }

    private static func writeManifest(_ items: [AppMediaItem]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(items)
        try data.write(to: manifestURL, options: .atomic)
    }

    private static func imageDimensions(from data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { return (0, 0) }

        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return (width, height)
    }

    private static func makeFileName(fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let uniquePart = UUID().uuidString.prefix(8)
        return "CompactCapture-\(formatter.string(from: Date()))-\(uniquePart).\(fileExtension.lowercased())"
    }

    private static func withLock<T>(_ action: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try action()
    }
}

enum PhotoLibraryExportError: LocalizedError {
    case accessDenied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "写真アプリへの追加が許可されていません。"
        case let .saveFailed(reason):
            "写真アプリへ保存できませんでした：\(reason)"
        }
    }
}

enum PhotoLibraryExporter {
    static func export(
        _ item: AppMediaItem,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        requestAddOnlyAccess { allowed in
            guard allowed else {
                completion(.failure(PhotoLibraryExportError.accessDenied))
                return
            }

            let options = PHAssetResourceCreationOptions()
            options.originalFilename = item.fileName
            let resourceType: PHAssetResourceType = item.kind == .video ? .video : .photo
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: resourceType, fileURL: item.fileURL, options: options)
            } completionHandler: { success, error in
                if success {
                    completion(.success(()))
                } else {
                    completion(.failure(
                        PhotoLibraryExportError.saveFailed(
                            error?.localizedDescription ?? "不明なエラー"
                        )
                    ))
                }
            }
        }
    }

    private static func requestAddOnlyAccess(completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            completion(true)
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                completion(newStatus == .authorized || newStatus == .limited)
            }
        case .denied, .restricted:
            completion(false)
        @unknown default:
            completion(false)
        }
    }
}

final class AppMediaLibraryModel: ObservableObject {
    @Published private(set) var items: [AppMediaItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    var totalSizeText: String {
        Self.byteCountFormatter.string(
            fromByteCount: items.reduce(Int64(0)) { $0 + $1.fileSizeBytes }
        )
    }

    func reload() {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try AppMediaStore.loadItems()
            errorMessage = nil
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ item: AppMediaItem) {
        do {
            try AppMediaStore.delete(item)
            items.removeAll { $0.id == item.id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markPhotoLibraryExported(_ item: AppMediaItem) {
        do {
            try AppMediaStore.markPhotoLibraryExported(item)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].photoLibraryExported = true
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}

final class LocalMediaImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var isLoading = false

    func loadThumbnail(item: AppMediaItem, side: CGFloat) {
        isLoading = true
        switch item.kind {
        case .image:
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let image = Self.downsampleImage(
                    at: item.fileURL,
                    maximumPixelSize: side
                )
                DispatchQueue.main.async {
                    self?.image = image
                    self?.isLoading = false
                }
            }
        case .video:
            Task { [weak self] in
                let image = await Self.videoThumbnail(
                    for: item,
                    maximumPixelSize: side
                )
                await MainActor.run {
                    self?.image = image
                    self?.isLoading = false
                }
            }
        }
    }

    func loadFullImage(item: AppMediaItem) {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = UIImage(contentsOfFile: item.fileURL.path)
            DispatchQueue.main.async {
                self?.image = image
                self?.isLoading = false
            }
        }
    }

    private static func downsampleImage(
        at url: URL,
        maximumPixelSize: CGFloat
    ) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maximumPixelSize.rounded()), 1)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func videoThumbnail(
        for item: AppMediaItem,
        maximumPixelSize: CGFloat
    ) async -> UIImage? {
        let asset = AVURLAsset(url: item.fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        let seconds = min(max(item.duration * 0.1, 0.03), 0.25)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image)
    }
}

final class VideoAssetPlayerLoader: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var timeObserver: Any?
    private var playbackStatusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?

    deinit {
        cancel()
    }

    func load(item: AppMediaItem) {
        cancel()
        isLoading = true
        errorMessage = nil
        duration = item.duration

        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            isLoading = false
            errorMessage = "動画ファイルが見つかりません。"
            return
        }

        let playerItem = AVPlayerItem(url: item.fileURL)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        observe(player, item: playerItem)
    }

    func pause() {
        player?.pause()
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, currentTime >= duration - 0.08 {
                player.seek(to: .zero)
            }
            player.play()
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(seconds, 0), max(duration, 0))
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = clamped
    }

    func cancel() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        playbackStatusObservation = nil
        itemStatusObservation = nil
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
    }

    private func observe(_ player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self, time.seconds.isFinite else { return }
            self.currentTime = max(0, time.seconds)
        }
        playbackStatusObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = item.status == .unknown
                if item.status == .failed {
                    self.errorMessage = item.error?.localizedDescription ?? "動画を読み込めませんでした。"
                }
            }
        }
    }
}

final class PlayerSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.magnificationFilter = .nearest
        view.playerLayer.minificationFilter = .nearest
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

struct AppMediaThumbnailView: View {
    let item: AppMediaItem
    @StateObject private var loader = LocalMediaImageLoader()

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.secondary.opacity(0.12)
                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                } else if loader.isLoading {
                    ProgressView()
                } else {
                    Image(systemName: item.kind == .video ? "video" : "photo")
                        .foregroundStyle(.secondary)
                }

                if item.kind == .video {
                    VStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                            Text(item.duration.compactDurationText)
                                .monospacedDigit()
                            Spacer(minLength: 0)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.62))
                    }
                }
            }
            .clipped()
            .onAppear {
                let side = max(proxy.size.width, 120) * UIScreen.main.scale
                loader.loadThumbnail(item: item, side: side)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

extension TimeInterval {
    var compactDurationText: String {
        let seconds = max(0, Int(rounded()))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct PixelZoomScrollView: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomScale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 16
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator
        scrollView.panGestureRecognizer.isEnabled = false

        let zoomContainer = UIView()
        zoomContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(zoomContainer)
        NSLayoutConstraint.activate([
            zoomContainer.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            zoomContainer.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            zoomContainer.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            zoomContainer.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            zoomContainer.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            zoomContainer.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        let imageView = UIImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.layer.magnificationFilter = .nearest
        imageView.layer.minificationFilter = .nearest
        zoomContainer.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: zoomContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: zoomContainer.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: zoomContainer.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: zoomContainer.bottomAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView
        context.coordinator.zoomContainer = zoomContainer
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            scrollView.setZoomScale(1, animated: false)
        }
        let clamped = min(max(zoomScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        if abs(scrollView.zoomScale - clamped) > 0.01,
           !context.coordinator.isUpdatingBinding {
            scrollView.setZoomScale(clamped, animated: true)
        }
        scrollView.panGestureRecognizer.isEnabled = clamped > 1.01
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let zoomScale: Binding<CGFloat>
        weak var scrollView: UIScrollView?
        weak var zoomContainer: UIView?
        weak var imageView: UIImageView?
        var isUpdatingBinding = false

        init(zoomScale: Binding<CGFloat>) {
            self.zoomScale = zoomScale
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            zoomContainer
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            isUpdatingBinding = true
            let value = scrollView.zoomScale
            scrollView.panGestureRecognizer.isEnabled = value > 1.01
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.zoomScale.wrappedValue = value
                self.isUpdatingBinding = false
            }
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            let target: CGFloat = scrollView.zoomScale < 3.5 ? 4 : 1
            scrollView.setZoomScale(target, animated: true)
        }
    }
}
