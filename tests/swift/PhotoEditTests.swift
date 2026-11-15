import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest

@testable import CanonPTPCore

final class PhotoEditTests: XCTestCase {
  func fixture(width: Int = 24, height: Int = 16, gray: CGFloat = 0.25) throws -> Data {
    let source = CIImage(color: CIColor(red: gray, green: gray, blue: gray)).cropped(
      to: CGRect(x: 0, y: 0, width: width, height: height))
    return try PhotoEditCore.render(source, recipe: PhotoRecipe())
  }
  func size(_ data: Data) throws -> (Int, Int) {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return (
      try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
      try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
    )
  }
  func average(_ image: CIImage) -> UInt8 {
    let source = image.applyingFilter(
      "CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
    var pixel = [UInt8](repeating: 0, count: 4)
    CIContext().render(
      source, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return pixel[0]
  }
  func testRecipeRejectsInvalidRangesAndBooleans() throws {
    XCTAssertThrowsError(try PhotoRecipe(dictionary: ["exposure": true]))
    XCTAssertThrowsError(try PhotoRecipe(exposure: 3))
    XCTAssertThrowsError(try PhotoRecipe(saturation: .nan))
    XCTAssertEqual(try PhotoRecipe(dictionary: [:]), try PhotoRecipe())
  }
  func testAIPhotoRecipeMustBeCompleteAndWithinBounds() throws {
    let current = try PhotoRecipe(highlights: -0.6, shadows: 0.7)
    let valid =
      #"{"summary":"自然光","composition":["背景简洁"],"confidence":0.8,"recipe":{"exposure":0.3,"contrast":1.1,"saturation":1.0,"warmth":0.2,"highlights":0,"shadows":0}}"#
    let result = try PhotoGuidanceResult.parse(valid, currentRecipe: current)
    XCTAssertEqual(result.recipe?.exposure, 0.3)
    XCTAssertEqual(result.recipe?.highlights, current.highlights)
    XCTAssertEqual(result.recipe?.shadows, current.shadows)
    XCTAssertEqual(result.dictionary["applicable"] as? Bool, true)
    let low =
      #"{"summary":"x","composition":[],"confidence":0.2,"recipe":{"exposure":0,"contrast":1,"saturation":1,"warmth":0}}"#
    XCTAssertEqual(try PhotoGuidanceResult.parse(low, currentRecipe: current).dictionary["applicable"] as? Bool, false)
    let missing = #"{"summary":"x","composition":[],"confidence":0.9,"recipe":{"exposure":0}}"#
    let invalid =
      #"{"summary":"x","composition":[],"confidence":0.9,"recipe":{"exposure":99,"contrast":1,"saturation":1,"warmth":0}}"#
    let boolean =
      #"{"summary":"x","composition":[],"confidence":0.9,"recipe":{"exposure":true,"contrast":1,"saturation":1,"warmth":0}}"#
    for content in [missing, invalid, boolean] {
      XCTAssertThrowsError(try PhotoGuidanceResult.parse(content, currentRecipe: current))
    }
  }
  func testJPEGValidationPreviewSizeAndExposure() throws {
    XCTAssertThrowsError(try PhotoEditCore.image(Data([0, 1, 2])))
    let original = try fixture(width: 1600, height: 800)
    let image = try PhotoEditCore.image(original)
    let preview = try PhotoEditCore.render(
      image, recipe: PhotoRecipe(exposure: 1), maxDimension: 1280)
    let dimensions = try size(preview)
    XCTAssertEqual(dimensions.0, 1280)
    XCTAssertEqual(dimensions.1, 640)
    XCTAssertGreaterThan(average(try PhotoEditCore.image(preview)), average(image))
    let full = try PhotoEditCore.render(image, recipe: PhotoRecipe(exposure: 1))
    let fullSize = try size(full)
    XCTAssertEqual(fullSize.0, 1600)
    XCTAssertEqual(fullSize.1, 800)
  }
  func testAutomaticRecipeUsesLuminanceAndIsBounded() throws {
    let dark = try PhotoEditCore.image(fixture(gray: 0.05))
    let bright = try PhotoEditCore.image(fixture(gray: 0.9))
    let a = try PhotoEditCore.automaticRecipe(dark)
    let b = try PhotoEditCore.automaticRecipe(bright)
    XCTAssertGreaterThan(a.exposure, 0)
    XCTAssertLessThan(b.exposure, 0)
    XCTAssertLessThanOrEqual(a.exposure, 0.7)
    XCTAssertGreaterThanOrEqual(b.exposure, -0.7)
  }
  func testWarmthSliderChangesGrayTowardWarmColor() throws {
    let image = try PhotoEditCore.image(fixture(gray: 0.5))
    func redMinusBlue(_ recipe: PhotoRecipe) throws -> Int {
      let rendered = try PhotoEditCore.image(PhotoEditCore.render(image, recipe: recipe))
      let average = rendered.applyingFilter(
        "CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rendered.extent)])
      var pixel = [UInt8](repeating: 0, count: 4)
      CIContext().render(
        average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
      return Int(pixel[0]) - Int(pixel[2])
    }
    XCTAssertGreaterThan(
      try redMinusBlue(PhotoRecipe(warmth: 1)), try redMinusBlue(PhotoRecipe(warmth: -1)))
  }
  func testOrientationAppliedAndExportStripsGPS() throws {
    let image = try PhotoEditCore.image(fixture(width: 24, height: 16))
    let cgImage = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
    let bytes = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, cgImage,
      [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyExifDictionary: [
          kCGImagePropertyExifDateTimeOriginal: "2026:11:12 12:30:00"
        ],
        kCGImagePropertyGPSDictionary: [
          kCGImagePropertyGPSLatitude: 20, kCGImagePropertyGPSLatitudeRef: "N",
        ],
      ] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let inputSource = try XCTUnwrap(CGImageSourceCreateWithData(bytes, nil))
    let inputProperties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(inputSource, 0, nil) as? [CFString: Any])
    XCTAssertNotNil(inputProperties[kCGImagePropertyGPSDictionary])
    let inputExif = try XCTUnwrap(
      inputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])
    XCTAssertNotNil(inputExif[kCGImagePropertyExifDateTimeOriginal])
    let rotated = try PhotoEditCore.image(bytes as Data)
    XCTAssertEqual(rotated.extent.width, 16)
    XCTAssertEqual(rotated.extent.height, 24)
    let output = try PhotoEditCore.render(rotated, recipe: PhotoRecipe())
    let outputSource = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [CFString: Any])
    XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
    let actual = try size(output)
    XCTAssertEqual(actual.0, 16)
    XCTAssertEqual(actual.1, 24)
  }
  func testCaptureCatalogPaginatesBeyondOneHundredAndSurvivesInsertions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let catalog = CaptureCatalog(directory: root)
    XCTAssertTrue(try catalog.list().isEmpty)
    for number in 0..<125 {
      try Data([1]).write(to: root.appendingPathComponent(String(format: "%04d.jpg", number)))
    }
    try Data([1]).write(to: root.appendingPathComponent("ignored.txt"))
    let initial = try catalog.list()
    XCTAssertEqual(initial.count, 125)
    let first = CaptureCatalog.page(initial, before: nil)
    XCTAssertEqual(first.items.count, 30)
    try Data([1]).write(to: root.appendingPathComponent("9999.jpg"))
    let afterInsert = try catalog.list()
    var cursor = first.next
    var all = first.items
    while let before = cursor {
      let page = CaptureCatalog.page(afterInsert, before: before)
      all += page.items
      cursor = page.next
    }
    XCTAssertEqual(all.count, 125)
    XCTAssertEqual(Set(all).count, 125)
    XCTAssertEqual(all.last?.lastPathComponent, "0000.jpg")
    XCTAssertNil(CaptureCatalog.page(Array(initial.prefix(30)), before: nil).next)
  }

  func testSaveReloadAndUniqueExportsPreserveOriginal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let captures = root.appendingPathComponent("Captures", isDirectory: true)
    try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
    let original = try fixture()
    let source = captures.appendingPathComponent("original.jpg")
    try original.write(to: source)
    let storage = PhotoEditStorage(documents: root)
    let resolved = try storage.sourceURL(source.path)
    let recipe = try PhotoRecipe(exposure: 0.5, contrast: 1.1, saturation: 0.8, warmth: 0.2)
    try storage.saveRecipe(source: resolved, recipe: recipe)
    XCTAssertEqual(try storage.loadRecipe(source: resolved), recipe)
    let rendered = try PhotoEditCore.render(PhotoEditCore.image(original), recipe: recipe)
    let first = try storage.export(rendered)
    let second = try storage.export(rendered)
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "Exports")
    XCTAssertEqual(try Data(contentsOf: first), rendered)
    XCTAssertEqual(try storage.exportedURL(first.path), first.resolvingSymlinksInPath())
    XCTAssertThrowsError(try storage.exportedURL(source.path))
    let link = first.deletingLastPathComponent().appendingPathComponent("escape.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    XCTAssertThrowsError(try storage.exportedURL(link.path))
  }
  func testRejectsOutsidePathAndEscapingSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let captures = root.appendingPathComponent("Captures", isDirectory: true)
    try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("outside.jpg")
    try fixture().write(to: outside)
    let link = captures.appendingPathComponent("link.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let storage = PhotoEditStorage(documents: root)
    XCTAssertThrowsError(try storage.sourceURL(outside.path))
    XCTAssertThrowsError(try storage.sourceURL(link.path))
  }

  func testHighlightsAndShadowsValidationAndRendering() throws {
    XCTAssertThrowsError(try PhotoRecipe(highlights: 1.2))
    XCTAssertThrowsError(try PhotoRecipe(highlights: -1.1))
    XCTAssertThrowsError(try PhotoRecipe(shadows: .nan))
    XCTAssertThrowsError(try PhotoRecipe(shadows: -1.2))

    let recipe = try PhotoRecipe(dictionary: ["exposure": 0.25, "highlights": -0.6, "shadows": 0.7])
    XCTAssertEqual(recipe.highlights, -0.6)
    XCTAssertEqual(recipe.shadows, 0.7)
    XCTAssertEqual(recipe.dictionary["highlights"], -0.6)
    XCTAssertEqual(recipe.dictionary["shadows"], 0.7)

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
      data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 32))
    ctx.setFillColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)
    ctx.fill(CGRect(x: 16, y: 0, width: 16, height: 32))
    let cgImage = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cgImage, nil)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    let source = try PhotoEditCore.image(data as Data)

    let neutral = try PhotoEditCore.render(source, recipe: PhotoRecipe())
    let adjusted = try PhotoEditCore.render(
      source, recipe: try PhotoRecipe(highlights: -0.8, shadows: 0.8))
    let boosted = try PhotoEditCore.render(source, recipe: try PhotoRecipe(highlights: 0.9))
    XCTAssertNotEqual(neutral, adjusted)
    XCTAssertNotEqual(neutral, boosted)
  }

  func testSafeExifPreservesShootingParamsAndStripsGPSAndSerial() throws {
    let sourceData = try fixture()
    let mutable = NSMutableData()
    let cgSource = CGImageSourceCreateWithData(sourceData as CFData, nil)!
    let cgImage = CGImageSourceCreateImageAtIndex(cgSource, 0, nil)!
    let props: [CFString: Any] = [
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitude: 31.23,
        kCGImagePropertyGPSLongitude: 121.47,
      ],
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "Canon",
        kCGImagePropertyTIFFModel: "Canon EOS R10",
        kCGImagePropertyTIFFOrientation: 6,
      ],
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:11:15 12:00:00",
        kCGImagePropertyExifExposureTime: 0.008,
        kCGImagePropertyExifFNumber: 2.8,
        kCGImagePropertyExifISOSpeedRatings: [400],
        kCGImagePropertyExifFocalLength: 50.0,
        kCGImagePropertyExifLensModel: "RF50mm F1.8 STM",
        kCGImagePropertyExifBodySerialNumber: "SECRET-BODY-123",
        kCGImagePropertyExifLensSerialNumber: "SECRET-LENS-456",
      ],
    ]
    let dest = CGImageDestinationCreateWithData(mutable, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    let richSource = mutable as Data

    let stripped = try PhotoEditCore.render(
      PhotoEditCore.image(richSource), recipe: PhotoRecipe(), preserveMetadataFrom: nil)
    let strippedProps =
      CGImageSourceCopyPropertiesAtIndex(
        CGImageSourceCreateWithData(stripped as CFData, nil)!, 0, nil) as? [String: Any] ?? [:]
    let strippedExif = strippedProps[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    XCTAssertNil(strippedProps[kCGImagePropertyGPSDictionary as String])
    XCTAssertNil(strippedExif[kCGImagePropertyExifDateTimeOriginal as String])
    XCTAssertNil(strippedExif[kCGImagePropertyExifFNumber as String])
    XCTAssertNil(strippedExif[kCGImagePropertyExifBodySerialNumber as String])

    let preserved = try PhotoEditCore.render(
      PhotoEditCore.image(richSource), recipe: PhotoRecipe(), preserveMetadataFrom: richSource)
    let outProps =
      CGImageSourceCopyPropertiesAtIndex(
        CGImageSourceCreateWithData(preserved as CFData, nil)!, 0, nil) as? [String: Any] ?? [:]
    XCTAssertNil(outProps[kCGImagePropertyGPSDictionary as String])
    let exif = outProps[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    let tiff = outProps[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
    XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:11:15 12:00:00")
    XCTAssertEqual(exif[kCGImagePropertyExifFNumber as String] as? Double, 2.8)
    XCTAssertEqual(exif[kCGImagePropertyExifFocalLength as String] as? Double, 50.0)
    XCTAssertEqual(exif[kCGImagePropertyExifLensModel as String] as? String, "RF50mm F1.8 STM")
    XCTAssertNil(exif[kCGImagePropertyExifBodySerialNumber as String])
    XCTAssertNil(exif[kCGImagePropertyExifLensSerialNumber as String])
    XCTAssertEqual(tiff[kCGImagePropertyTIFFMake as String] as? String, "Canon")
    XCTAssertEqual(tiff[kCGImagePropertyTIFFModel as String] as? String, "Canon EOS R10")
    XCTAssertNil(tiff[kCGImagePropertyTIFFOrientation as String])
  }
}
