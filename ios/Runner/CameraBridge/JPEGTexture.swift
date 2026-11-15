import CoreVideo
import Flutter
import ImageIO
import UIKit

// frame, _histogram, and _highlightClipped are protected by lock; pool and poolSize belong only to decoder.
final class JPEGTexture: NSObject, FlutterTexture, @unchecked Sendable {
  private let lock = NSLock()
  private let decoder = DispatchQueue(label: "com.parado.canoneos.jpeg", qos: .userInitiated)
  private var frame: CVPixelBuffer?
  private var _histogram: [Double] = []
  private var _highlightClipped = false
  private var pool: CVPixelBufferPool?
  private var poolSize = CGSize.zero

  var histogram: [Double] {
    lock.lock()
    defer { lock.unlock() }
    return _histogram
  }

  var highlightClipped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _highlightClipped
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    return frame.map { Unmanaged.passRetained($0) }
  }

  func clear() {
    lock.lock()
    frame = nil
    _histogram = []
    _highlightClipped = false
    lock.unlock()
  }

  /// Awaiting decode provides backpressure: never accumulate stale frames.
  func update(_ jpeg: Data) async throws -> CGSize {
    try await withCheckedThrowingContinuation { continuation in
      decoder.async {
        do {
          guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 8192, height <= 8192,
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            ] as CFDictionary),
            image.width > 0, image.height > 0, image.width <= 8192, image.height <= 8192
          else {
            throw CameraError.invalidData("JPEG 解码失败")
          }
          let size = CGSize(width: image.width, height: image.height)
          if size != self.poolSize || self.pool == nil {
            let attributes: [String: Any] = [
              kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
              kCVPixelBufferWidthKey as String: image.width,
              kCVPixelBufferHeightKey as String: image.height,
              kCVPixelBufferIOSurfacePropertiesKey as String: [:],
              kCVPixelBufferCGImageCompatibilityKey as String: true,
              kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            guard
              CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &self.pool)
                == kCVReturnSuccess
            else {
              throw CameraError.invalidData("无法创建像素缓冲池")
            }
            self.poolSize = size
          }
          var buffer: CVPixelBuffer?
          guard let pool = self.pool,
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
            let buffer
          else { throw CameraError.invalidData("无法分配取景帧") }
          CVPixelBufferLockBaseAddress(buffer, [])
          defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
          guard
            let context = CGContext(
              data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
            )
          else { throw CameraError.invalidData("无法创建 JPEG 解码上下文") }
          context.draw(image, in: CGRect(origin: .zero, size: size))
          var bins = [Int](repeating: 0, count: 16)
          var totalSamples = 0
          var clippedSamples = 0
          if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let stepX = max(1, image.width / 64)
            let stepY = max(1, image.height / 64)
            for y in stride(from: 0, to: image.height, by: stepY) {
              let row = y * bytesPerRow
              for x in stride(from: 0, to: image.width, by: stepX) {
                let offset = row + x * 4
                let b = Int(bytes[offset])
                let g = Int(bytes[offset + 1])
                let r = Int(bytes[offset + 2])
                let luma = (2126 * r + 7152 * g + 722 * b) / 10000
                let bucket = min(15, max(0, luma >> 4))
                bins[bucket] += 1
                totalSamples += 1
                if r >= 250 && g >= 250 && b >= 250 { clippedSamples += 1 }
              }
            }
          }
          let maxBin = max(1, bins.max() ?? 1)
          let normalized = totalSamples > 0 ? bins.map { Double($0) / Double(maxBin) } : []
          let clipped = totalSamples > 0 && Double(clippedSamples) / Double(totalSamples) > 0.015
          self.lock.lock()
          self.frame = buffer
          self._histogram = normalized
          self._highlightClipped = clipped
          self.lock.unlock()
          continuation.resume(returning: size)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
}
