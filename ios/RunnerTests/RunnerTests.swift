import CoreImage
import CoreVideo
import Flutter
import ImageIO
import UIKit
import XCTest

@testable import Runner

final class RunnerTests: XCTestCase {
  @MainActor
  func testVisionBlankFrameHasNoPeopleOnIOS() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format)
      .jpegData(withCompressionQuality: 0.9) { context in
        UIColor.gray.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
      }
    do {
      let detection = try VisionBodyPoseDetector().detect(jpeg)
      XCTAssertEqual(detection.status, "noPerson")
      XCTAssertTrue(detection.points.isEmpty)
    } catch {
      #if targetEnvironment(simulator)
        let failure = error as NSError
        if failure.domain == "com.apple.Vision" && failure.code == 9 {
          throw XCTSkip("模拟器的 Vision 人体姿态请求初始化失败；需要真实设备验证。")
        }
      #endif
      throw error
    }
  }
  @MainActor
  func testPhotoEditingRendersAndPreservesOriginalOnIOS() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let captures = root.appendingPathComponent("Captures", isDirectory: true)
    try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let jpeg = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format)
      .jpegData(withCompressionQuality: 1) { context in
        UIColor.gray.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
      }
    let original = captures.appendingPathComponent("original.jpg")
    try jpeg.write(to: original)
    let store = PhotoEditStorage(documents: root)
    let source = try store.sourceURL(original.path)
    let recipe = try PhotoRecipe(exposure: 0.5, contrast: 1.1, saturation: 0.8, warmth: 0.2)
    try store.saveRecipe(source: source, recipe: recipe)
    XCTAssertEqual(try store.loadRecipe(source: source), recipe)
    let result = try PhotoEditCore.render(PhotoEditCore.image(jpeg), recipe: recipe)
    let exported = try store.export(result)
    XCTAssertEqual(try Data(contentsOf: original), jpeg)
    XCTAssertEqual(try Data(contentsOf: exported), result)
    XCTAssertNotEqual(exported, original)
  }
  func testTextureRejectsInvalidJPEG() async {
    let texture = JPEGTexture()
    do {
      _ = try await texture.update(Data([0, 1, 2]))
      XCTFail("Invalid JPEG should not produce a frame")
    } catch {
      XCTAssertNil(texture.copyPixelBuffer())
    }
  }

  @MainActor
  func testTexturePreservesDimensionsAndVerticalOrientation() async throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 60), format: format)
    let jpeg = renderer.jpegData(withCompressionQuality: 1) { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 100, height: 30))
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 30, width: 100, height: 30))
    }
    let texture = JPEGTexture()
    let size = try await texture.update(jpeg)
    XCTAssertEqual(size, CGSize(width: 100, height: 60))
    let buffer = try XCTUnwrap(texture.copyPixelBuffer()?.takeRetainedValue())
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(
      to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let top = 5 * stride + 50 * 4
    let bottom = 55 * stride + 50 * 4
    XCTAssertGreaterThan(bytes[top + 2], 240, "Top of frame must remain red")
    XCTAssertGreaterThan(bytes[bottom], 240, "Bottom of frame must remain blue")
    texture.clear()
    XCTAssertNil(texture.copyPixelBuffer())
  }

  @MainActor
  func testTextureAppliesExifRotationAndMirroring() async throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 60), format: format)
      .image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 30))
        UIColor.blue.setFill()
        context.fill(CGRect(x: 0, y: 30, width: 100, height: 30))
      }
    let cgImage = try XCTUnwrap(image.cgImage)
    for orientation in [4, 6] {
      let data = NSMutableData()
      let destination = try XCTUnwrap(
        CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
      CGImageDestinationAddImage(
        destination, cgImage, [kCGImagePropertyOrientation: orientation] as CFDictionary)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
      let texture = JPEGTexture()
      let size = try await texture.update(data as Data)
      XCTAssertEqual(size, orientation == 6 ? CGSize(width: 60, height: 100) : CGSize(width: 100, height: 60))
      let buffer = try XCTUnwrap(texture.copyPixelBuffer()?.takeRetainedValue())
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      let blue = orientation == 6 ? 50 * stride + 15 * 4 : 15 * stride + 50 * 4
      let red = orientation == 6 ? 50 * stride + 45 * 4 : 45 * stride + 50 * 4
      XCTAssertGreaterThan(bytes[blue], 220, "Orientation \(orientation): blue position")
      XCTAssertGreaterThan(bytes[red + 2], 220, "Orientation \(orientation): red position")
    }
  }

  func testAIKeychainDoesNotExposeKeyAndBindsItToEndpoint() throws {
    let suite = "com.parado.canoneos.test.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let store = AIConfigurationStore(defaults: defaults)
    let endpoint = "https://example.test/\(UUID().uuidString)/chat/completions"
    defer {
      try? store.clear()
      defaults.removePersistentDomain(forName: suite)
    }
    try store.save(endpoint: endpoint, model: "model", key: "test-secret")
    XCTAssertEqual(try store.configuration().apiKey, "test-secret")
    XCTAssertEqual(store.snapshot()["hasKey"] as? Bool, true)
    XCTAssertFalse(String(describing: store.snapshot()).contains("test-secret"))
    try store.save(endpoint: endpoint, model: "another-model", key: "")
    XCTAssertEqual(try store.configuration().apiKey, "test-secret")
    XCTAssertThrowsError(
      try store.save(endpoint: "https://other.test/chat/completions", model: "m", key: ""))
    try store.clear()
    XCTAssertThrowsError(try store.configuration())
  }

}
