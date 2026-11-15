import CoreFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct PhotoRecipe: Equatable {
  var exposure: Double = 0
  var contrast: Double = 1
  var saturation: Double = 1
  var warmth: Double = 0
  var highlights: Double = 0
  var shadows: Double = 0

  init(
    exposure: Double = 0, contrast: Double = 1, saturation: Double = 1, warmth: Double = 0,
    highlights: Double = 0, shadows: Double = 0
  ) throws {
    guard exposure.isFinite, (-2...2).contains(exposure), contrast.isFinite,
      (0.5...1.5).contains(contrast),
      saturation.isFinite, (0...2).contains(saturation), warmth.isFinite, (-1...1).contains(warmth),
      highlights.isFinite, (-1...1).contains(highlights), shadows.isFinite, (-1...1).contains(shadows)
    else {
      throw CameraError.invalidData("调色参数超出范围")
    }
    self.exposure = exposure
    self.contrast = contrast
    self.saturation = saturation
    self.warmth = warmth
    self.highlights = highlights
    self.shadows = shadows
  }

  init(dictionary: [String: Any]) throws {
    func number(_ key: String, _ fallback: Double) throws -> Double {
      guard let raw = dictionary[key] else { return fallback }
      guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else {
        throw CameraError.invalidData("调色参数格式无效")
      }
      return value.doubleValue
    }
    try self.init(
      exposure: number("exposure", 0), contrast: number("contrast", 1),
      saturation: number("saturation", 1), warmth: number("warmth", 0),
      highlights: number("highlights", 0), shadows: number("shadows", 0))
  }
  var dictionary: [String: Double] {
    [
      "exposure": exposure, "contrast": contrast, "saturation": saturation, "warmth": warmth,
      "highlights": highlights, "shadows": shadows,
    ]
  }
}

enum PhotoEditCore {
  static let maximumFileSize = 100_000_000
  static func image(_ data: Data) throws -> CIImage {
    guard !data.isEmpty, data.count <= maximumFileSize,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetType(source) as String? == "public.jpeg",
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 12000, height <= 12000,
      Int64(width) * Int64(height) <= 80_000_000,
      let image = CIImage(data: data, options: [.applyOrientationProperty: true])
    else {
      throw CameraError.invalidData("照片不是可用的 JPEG，或尺寸过大")
    }
    return image
  }

  /// Extracts safe camera shooting parameters (EXIF/TIFF) while omitting GPS, serial numbers, and orientation.
  static func safeExifMetadata(from data: Data) -> [CFString: Any] {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    else { return [:] }
    var result: [CFString: Any] = [:]
    if let exif = raw[kCGImagePropertyExifDictionary as String] as? [String: Any] {
      let allowedExifKeys: [CFString] = [
        kCGImagePropertyExifDateTimeOriginal,
        kCGImagePropertyExifExposureTime,
        kCGImagePropertyExifFNumber,
        kCGImagePropertyExifISOSpeedRatings,
        kCGImagePropertyExifFocalLength,
        kCGImagePropertyExifLensModel,
      ]
      let filtered = allowedExifKeys.reduce(into: [CFString: Any]()) { out, key in
        if let value = exif[key as String] { out[key] = value }
      }
      if !filtered.isEmpty { result[kCGImagePropertyExifDictionary] = filtered }
    }
    if let tiff = raw[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
      let allowedTiffKeys: [CFString] = [
        kCGImagePropertyTIFFMake,
        kCGImagePropertyTIFFModel,
      ]
      let filtered = allowedTiffKeys.reduce(into: [CFString: Any]()) { out, key in
        if let value = tiff[key as String] { out[key] = value }
      }
      if !filtered.isEmpty { result[kCGImagePropertyTIFFDictionary] = filtered }
    }
    return result
  }

  static func render(
    _ source: CIImage, recipe: PhotoRecipe, maxDimension: Int? = nil,
    preserveMetadataFrom sourceData: Data? = nil
  ) throws -> Data {
    var image = source
    if let maxDimension {
      guard (128...4096).contains(maxDimension) else { throw CameraError.invalidData("预览尺寸无效") }
      let scale = min(1, CGFloat(maxDimension) / max(image.extent.width, image.extent.height))
      image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
    image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: recipe.exposure])
    image = image.applyingFilter(
      "CIColorControls",
      parameters: [
        kCIInputContrastKey: recipe.contrast, kCIInputSaturationKey: recipe.saturation,
      ])
    if recipe.warmth != 0 {
      image = image.applyingFilter(
        "CITemperatureAndTint",
        parameters: [
          "inputNeutral": CIVector(x: 6500, y: 0),
          "inputTargetNeutral": CIVector(x: 6500 - recipe.warmth * 1200, y: 0),
        ])
    }
    if recipe.highlights != 0 || recipe.shadows != 0 {
      let highlightAmount = recipe.highlights < 0 ? max(0.0, 1.0 + recipe.highlights * 0.75) : 1.0
      image = image.applyingFilter(
        "CIHighlightShadowAdjust",
        parameters: [
          "inputHighlightAmount": highlightAmount,
          "inputShadowAmount": recipe.shadows,
        ])
      if recipe.highlights > 0 {
        image = image.applyingFilter(
          "CIToneCurve",
          parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 0.25, y: 0.25),
            "inputPoint2": CIVector(x: 0.5, y: 0.5),
            "inputPoint3": CIVector(x: 0.75, y: min(0.95, 0.75 + recipe.highlights * 0.15)),
            "inputPoint4": CIVector(x: 1, y: 1),
          ])
      }
    }
    guard image.extent.width > 0, image.extent.height > 0,
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let rendered = CIContext().createCGImage(
        image, from: image.extent, format: .RGBA8, colorSpace: space)
    else {
      throw CameraError.invalidData("无法生成 JPEG")
    }
    // Start a new image destination with no source metadata unless explicitly whitelisted.
    // This also avoids sending original EXIF/GPS in an AI preview.
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
    else {
      throw CameraError.invalidData("无法创建 JPEG")
    }
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.94]
    if let sourceData {
      for (key, value) in safeExifMetadata(from: sourceData) {
        properties[key] = value
      }
    }
    CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw CameraError.invalidData("无法生成 JPEG")
    }
    return data as Data
  }

  /// Estimate only average luminance, not scene semantics or AI content.
  static func automaticRecipe(_ image: CIImage) throws -> PhotoRecipe {
    let filter = image.applyingFilter(
      "CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw CameraError.invalidData("无法分析照片")
    }
    context.render(
      filter, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8, colorSpace: space)
    let luminance = max(
      0.01,
      (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255)
    let adjustment = max(-0.7, min(0.7, log2(0.46 / luminance) * 0.5))
    return try PhotoRecipe(exposure: adjustment, contrast: 1.04, saturation: 1.03)
  }
}
