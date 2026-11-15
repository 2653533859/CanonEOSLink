import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest

@testable import CanonPTPCore

final class PosePointTests: XCTestCase {
  func testCoordinatesConvertToTopLeftAndRejectInvalidPoints() {
    let point = BodyPoint.fromVision(name: "leftShoulder", x: 0.2, y: 0.8, confidence: 0.9)
    XCTAssertEqual(point?.x ?? -1, 0.2, accuracy: 0.00001)
    XCTAssertEqual(point?.y ?? -1, 0.2, accuracy: 0.00001)
    XCTAssertNil(BodyPoint.fromVision(name: "x", x: 0.5, y: 0.5, confidence: 0.34))
    XCTAssertNil(BodyPoint.fromVision(name: "x", x: .nan, y: 0.5, confidence: 0.9))
    XCTAssertNil(BodyPoint.fromVision(name: "x", x: 1.1, y: 0.5, confidence: 0.9))
  }
  func testVisionRejectsInvalidImageAndDoesNotCreatePeopleFromBlankImage() throws {
    let detector = VisionBodyPoseDetector()
    XCTAssertThrowsError(try detector.detect(Data([0, 1, 2])))
    let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
      .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
    let jpeg = try PhotoEditCore.render(image, recipe: PhotoRecipe())
    let result = try detector.detect(jpeg)
    XCTAssertEqual(result.status, "noPerson")
    XCTAssertTrue(result.points.isEmpty)

    let cgImage = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
    let rotated = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(rotated, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, cgImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let rotatedResult = try detector.detect(rotated as Data)
    XCTAssertEqual(rotatedResult.status, "noPerson")
  }
}

private final class BlockingPoseDetector: BodyPoseDetecting, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  let release = DispatchSemaphore(value: 0)
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }
  func detect(_ jpeg: Data) throws -> BodyDetection {
    lock.lock()
    calls += 1
    lock.unlock()
    guard release.wait(timeout: .now() + 3) == .success else { throw CameraError.timeout }
    return BodyDetection(
      status: "detected", points: [BodyPoint(name: "neck", x: 0.5, y: 0.3, confidence: 0.9)])
  }
}

@MainActor
final class PoseTrackerTests: XCTestCase {
  private func waitFor(_ condition: @escaping () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for tracker")
  }

  func testSingleFlightThrottleAndDisabledLateResult() async throws {
    let detector = BlockingPoseDetector()
    var now = 10.0
    let tracker = PoseTracker(
      detector: detector, clock: { now }, expirationNanoseconds: 5_000_000_000)
    tracker.setEnabled(true)
    tracker.submit(Data([1]))
    try await waitFor { detector.count == 1 }
    tracker.submit(Data([2]))
    tracker.submit(Data([3]))
    XCTAssertEqual(detector.count, 1)
    tracker.setEnabled(false)
    detector.release.signal()
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertFalse(tracker.enabled)
    XCTAssertEqual(tracker.status, "off")
    XCTAssertTrue(tracker.points.isEmpty)
    tracker.setEnabled(true)
    tracker.submit(Data([4]))
    try await waitFor { detector.count == 2 }
    detector.release.signal()
    try await waitFor { tracker.status == "detected" }
    XCTAssertEqual(tracker.points.first?.name, "neck")
    now = 10.5
    tracker.submit(Data([5]))
    try await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(detector.count, 2)
    now = 11.1
    tracker.submit(Data([6]))
    try await waitFor { detector.count == 3 }
    detector.release.signal()
    tracker.setEnabled(false)
  }

  func testSuspendAndExpirationClearPoints() async throws {
    let detector = BlockingPoseDetector()
    let tracker = PoseTracker(detector: detector, expirationNanoseconds: 80_000_000)
    tracker.setEnabled(true)
    tracker.submit(Data([1]))
    try await waitFor { detector.count == 1 }
    detector.release.signal()
    try await waitFor { tracker.status == "detected" }
    try await waitFor { tracker.status == "waiting" }
    XCTAssertTrue(tracker.points.isEmpty)
    tracker.suspend()
    XCTAssertTrue(tracker.enabled)
    XCTAssertEqual(tracker.status, "waiting")
    tracker.setEnabled(false)
  }

  func testReenableWhileOldFrameIsRunningDoesNotLeakOldResult() async throws {
    let detector = BlockingPoseDetector()
    let tracker = PoseTracker(detector: detector, expirationNanoseconds: 5_000_000_000)
    tracker.setEnabled(true)
    tracker.submit(Data([1]))
    try await waitFor { detector.count == 1 }
    tracker.setEnabled(false)
    tracker.setEnabled(true)
    tracker.submit(Data([2]))
    XCTAssertEqual(detector.count, 1)
    detector.release.signal()
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(tracker.status, "waiting")
    XCTAssertTrue(tracker.points.isEmpty)
    tracker.submit(Data([3]))
    try await waitFor { detector.count == 2 }
    detector.release.signal()
    try await waitFor { tracker.status == "detected" }
    tracker.setEnabled(false)
  }
}
