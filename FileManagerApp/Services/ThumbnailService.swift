import UIKit
import AVFoundation
import PDFKit
import QuickLookThumbnailing

// MARK: - Thumbnail Service

@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()
    private init() {}

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight = Set<String>()

    // Max cache size: 100 MB
    private let maxCacheBytes = 100 * 1024 * 1024

    init(maxCacheMB: Int = 100) {
        cache.totalCostLimit = maxCacheMB * 1024 * 1024
    }

    // MARK: - Public

    func thumbnail(for item: FileItem, size: CGSize = CGSize(width: 80, height: 80)) async -> UIImage? {
        let key = cacheKey(item: item, size: size)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard !inFlight.contains(key) else { return nil }

        inFlight.insert(key)
        defer { inFlight.remove(key) }

        let sourceURL: URL = item.providerType == .local
            ? LocalFileService.accessibleURL(for: item.path)
            : URL(fileURLWithPath: item.path)
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let image: UIImage?
        switch item.itemType {
        case .image:
            image = await generateImageThumbnail(url: sourceURL, size: size)
        case .video:
            image = await generateVideoThumbnail(url: sourceURL, size: size)
        case .pdf:
            image = await generatePDFThumbnail(url: sourceURL, size: size)
        default:
            image = await generateQuickLookThumbnail(url: sourceURL, size: size)
        }

        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: key as NSString, cost: cost)
        }
        return image
    }

    func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - Image thumbnail

    private func generateImageThumbnail(url: URL, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { cont in
            Task.detached(priority: .utility) {
                let opts  = [kCGImageSourceShouldCacheImmediately: true,
                             kCGImageSourceCreateThumbnailFromImageAlways: true,
                             kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height)) * 2] as CFDictionary
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else {
                    cont.resume(returning: nil); return
                }
                cont.resume(returning: UIImage(cgImage: cgImg))
            }
        }
    }

    // MARK: - Video thumbnail

    private func generateVideoThumbnail(url: URL, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { cont in
            Task.detached(priority: .utility) {
                let asset   = AVURLAsset(url: url)
                let gen     = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = size
                let time    = CMTime(seconds: 1, preferredTimescale: 60)
                if let cgImg = try? gen.copyCGImage(at: time, actualTime: nil) {
                    cont.resume(returning: UIImage(cgImage: cgImg))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - PDF thumbnail

    private func generatePDFThumbnail(url: URL, size: CGSize) async -> UIImage? {
        await withCheckedContinuation { cont in
            Task.detached(priority: .utility) {
                guard let doc   = PDFDocument(url: url),
                      let page  = doc.page(at: 0) else {
                    cont.resume(returning: nil); return
                }
                let pageRect  = page.bounds(for: .mediaBox)
                let scale     = min(size.width / pageRect.width, size.height / pageRect.height)
                let imgSize   = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

                UIGraphicsBeginImageContextWithOptions(imgSize, true, UIScreen.main.scale)
                UIColor.white.setFill()
                UIRectFill(CGRect(origin: .zero, size: imgSize))

                guard let ctx = UIGraphicsGetCurrentContext() else {
                    UIGraphicsEndImageContext()
                    cont.resume(returning: nil); return
                }
                ctx.translateBy(x: 0, y: imgSize.height)
                ctx.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: ctx)

                let img = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()
                cont.resume(returning: img)
            }
        }
    }

    // MARK: - QuickLook fallback

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
        "\(item.id)_\(Int(size.width))x\(Int(size.height))"
    }
}
