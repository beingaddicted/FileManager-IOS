import UIKit
import AVFoundation
import PDFKit
import Photos
import QuickLookThumbnailing
import Kingfisher

// MARK: - Thumbnail Service
//
// Two-tier cache:
//   1. Kingfisher's in-memory cache (`MemoryStorage.Backend`) — instant hits.
//   2. Kingfisher's disk cache — persists across launches, LRU-evicted by
//      Kingfisher's own background sweeper.
//
// Cache keys include the file's mtime, so editing a file on the NAS produces
// a fresh thumbnail without us having to track invalidations manually.
//
// Disk cap: 256 MB. Expiration: 30 days unused.

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()
    private init() {
        let cache = ImageCache(name: "fileManagerThumbnails")
        cache.memoryStorage.config.totalCostLimit = 64 * 1024 * 1024     // 64 MB RAM
        cache.memoryStorage.config.expiration     = .seconds(60 * 30)   // 30 min
        cache.diskStorage.config.sizeLimit        = 256 * 1024 * 1024   // 256 MB disk
        cache.diskStorage.config.expiration       = .days(30)
        // Sweep on every cold start; cheap because Kingfisher only touches
        // expired entries.
        cache.cleanExpiredDiskCache()
        self.cache = cache
    }

    private let cache: ImageCache
    /// Coalesces concurrent requests for the same key so we never generate
    /// the same thumbnail twice in parallel (common in long grids).
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Caps how many heavyweight thumbnail generators run at once. iOS
    /// throttles us above ~6 concurrent CGImageSource/AVAssetImageGenerator
    /// workers anyway; pinning the cap on our side keeps a 5,000-photo grid
    /// from scheduling 5,000 cooperative-tasks that all want the same CPU.
    private let limiter = ConcurrencyLimiter(maxConcurrency: 4)

    // MARK: - Public

    func thumbnail(for item: FileItem, size: CGSize = CGSize(width: 80, height: 80)) async -> UIImage? {
        let key = cacheKey(item: item, size: size)

        // L1: memory hit (Kingfisher checks both memory and disk asynchronously)
        if let hit = cache.retrieveImageInMemoryCache(forKey: key) {
            return hit
        }

        // L2: disk hit. Kingfisher returns this asynchronously; we await it.
        if let onDisk = await retrieveFromDisk(key: key) {
            return onDisk
        }

        // Coalesce: another request for the same key already in flight?
        if let existing = inFlight[key] {
            return await existing.value
        }

        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            // Wait for a generator slot. If the originating cell scrolls off
            // before we get one, the awaiting cell's `.task` is cancelled,
            // its continuation throws, and `Task.isCancelled` becomes true
            // here so we bail without doing the expensive work.
            await self.limiter.acquire()
            defer { Task { await self.limiter.release() } }

            if Task.isCancelled {
                self.inFlight.removeValue(forKey: key)
                return nil
            }
            let generated = await self.generateThumbnail(item: item, size: size)
            if let image = generated, !Task.isCancelled {
                self.cache.store(image, forKey: key, toDisk: true)
            }
            self.inFlight.removeValue(forKey: key)
            return generated
        }
        inFlight[key] = task
        return await task.value
    }

    func clearCache() {
        cache.clearMemoryCache()
        cache.clearDiskCache()
    }

    /// Total bytes used by the on-disk thumbnail cache. Useful for the
    /// "Storage" row in Settings.
    func diskCacheSize() async -> UInt {
        await withCheckedContinuation { (cont: CheckedContinuation<UInt, Never>) in
            cache.calculateDiskStorageSize { result in
                switch result {
                case .success(let size): cont.resume(returning: size)
                case .failure:           cont.resume(returning: 0)
                }
            }
        }
    }

    // MARK: - Private

    private func retrieveFromDisk(key: String) async -> UIImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            cache.retrieveImage(forKey: key) { result in
                switch result {
                case .success(let value):
                    cont.resume(returning: value.image)
                case .failure:
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func generateThumbnail(item: FileItem, size: CGSize) async -> UIImage? {
        if item.providerType == .local,
           let localId = LocalFileService.photoAssetLocalIdentifier(for: item.path) {
            return await generatePhotoLibraryThumbnail(localIdentifier: localId, size: size)
        }
        let sourceURL: URL = item.providerType == .local
            ? LocalFileService.accessibleURL(for: item.path)
            : URL(fileURLWithPath: item.path)
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { sourceURL.stopAccessingSecurityScopedResource() }
        }
        switch item.itemType {
        case .image: return await generateImageThumbnail(url: sourceURL, size: size)
        case .video: return await generateVideoThumbnail(url: sourceURL, size: size)
        case .pdf:   return await generatePDFThumbnail(url: sourceURL, size: size)
        default:     return await generateQuickLookThumbnail(url: sourceURL, size: size)
        }
    }

    // MARK: - Photo library

    private func generatePhotoLibraryThumbnail(localIdentifier: String, size: CGSize) async -> UIImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let allowed: Bool
        switch status {
        case .authorized, .limited:
            allowed = true
        case .notDetermined:
            allowed = await withCheckedContinuation { cont in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                    cont.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
        default:
            allowed = false
        }
        guard allowed else { return nil }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return nil }

        let opts = PHImageRequestOptions()
        opts.deliveryMode = .fastFormat
        opts.isNetworkAccessAllowed = true
        opts.resizeMode = .fast

        let scale = UIScreen.main.scale
        let target = CGSize(
            width: max(size.width * scale, 1),
            height: max(size.height * scale, 1)
        )
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFill,
                options: opts
            ) { image, _ in
                cont.resume(returning: image)
            }
        }
    }

    // MARK: - Image / video / PDF

    private func generateImageThumbnail(url: URL, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { cont in
            Task.detached(priority: .utility) {
                let opts  = [
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height)) * 2
                ] as CFDictionary
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: UIImage(cgImage: cgImg))
            }
        }
    }

    private func generateVideoThumbnail(url: URL, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { cont in
            Task.detached(priority: .utility) {
                let asset   = AVURLAsset(url: url)
                let gen     = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = size
                let times = [
                    CMTime(seconds: 1, preferredTimescale: 600),
                    CMTime.zero
                ]
                for time in times {
                    if let cgImg = try? gen.copyCGImage(at: time, actualTime: nil) {
                        cont.resume(returning: UIImage(cgImage: cgImg))
                        return
                    }
                }
                cont.resume(returning: nil)
            }
        }
    }

    private func generatePDFThumbnail(url: URL, size: CGSize) async -> UIImage? {
        let screenScale = UIScreen.main.scale
        return await withCheckedContinuation { cont in
            Task.detached(priority: .utility) {
                guard let doc   = PDFDocument(url: url),
                      let page  = doc.page(at: 0) else {
                    cont.resume(returning: nil); return
                }
                let pageRect  = page.bounds(for: .mediaBox)
                let scale     = min(size.width / pageRect.width, size.height / pageRect.height)
                let imgSize   = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

                let renderer = UIGraphicsImageRenderer(size: imgSize, format: {
                    let f = UIGraphicsImageRendererFormat()
                    f.scale = screenScale
                    f.opaque = true
                    return f
                }())
                let img = renderer.image { ctx in
                    UIColor.white.setFill()
                    ctx.cgContext.fill(CGRect(origin: .zero, size: imgSize))
                    ctx.cgContext.translateBy(x: 0, y: imgSize.height)
                    ctx.cgContext.scaleBy(x: scale, y: -scale)
                    page.draw(with: .mediaBox, to: ctx.cgContext)
                }
                cont.resume(returning: img)
            }
        }
    }

    private func generateQuickLookThumbnail(url: URL, size: CGSize) async -> UIImage? {
        let req = QLThumbnailGenerator.Request(
            fileAt:          url,
            size:            size,
            scale:           UIScreen.main.scale,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).uiImage
    }

    // MARK: - Cache key

    private func cacheKey(item: FileItem, size: CGSize) -> String {
        // mtime in the key invalidates the cache whenever the file changes —
        // important for thumbnails of files that are edited on the NAS.
        let mtime = Int(item.modifiedDate.timeIntervalSince1970)
        let conn  = item.connectionId?.uuidString ?? "local"
        return "\(item.providerType.rawValue)|\(conn)|\(item.path)|\(mtime)|\(Int(size.width))x\(Int(size.height))"
    }
}

// MARK: - Concurrency limiter
//
// Swift Concurrency doesn't ship a semaphore primitive (DispatchSemaphore is
// not safe with structured concurrency — it can deadlock the cooperative
// thread pool). This actor models the simplest fair counting semaphore:
// permits go to the next waiter when released.

actor ConcurrencyLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrency: Int) {
        self.available = max(1, maxConcurrency)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}
