import Foundation
import ImageIO
import UIKit

/// Small copies of profile photos friends shared through Amidst. Contact photos use separate local storage.
enum BackupAvatar {
    static let maxDimension = 128
    static let maxBytes = 12 * 1024
    static let totalBytes = 128 * 1024

    static func make(from data: Data?) -> Data? {
        guard let data, !data.isEmpty, data.count <= 1024 * 1024 else { return nil }
        if validated(data) != nil { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              fits(source, limit: 4096) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let thumbnail = UIImage(cgImage: image)
        for quality in [0.72, 0.5] as [CGFloat] {
            if let jpeg = thumbnail.jpegData(compressionQuality: quality), jpeg.count <= maxBytes { return jpeg }
        }
        return nil
    }

    static func validated(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty, data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil), fits(source, limit: maxDimension),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        return data
    }

    private static func fits(_ source: CGImageSource, limit: Int) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return (1...limit).contains(width) && (1...limit).contains(height)
    }
}
