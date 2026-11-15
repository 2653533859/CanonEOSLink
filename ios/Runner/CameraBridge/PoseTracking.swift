import CoreGraphics
import Foundation
import ImageIO
import Vision

struct BodyPoint: Equatable, Sendable {
  let name: String
  let x: Double
  let y: Double
  let confidence: Double
  var dictionary: [String: Any] { ["name": name, "x": x, "y": y, "confidence": confidence] }

  static func fromVision(name: String, x: Double, y: Double, confidence: Double) -> BodyPoint? {
    guard x.isFinite, y.isFinite, confidence.isFinite, (0...1).contains(x), (0...1).contains(y),
      (0.35...1).contains(confidence)
    else { return nil }
    // Vision's origin is bottom-left; Flutter's Texture origin is top-left.
    return BodyPoint(name: name, x: x, y: 1 - y, confidence: confidence)
  }
}

struct BodyDetection: Sendable {
  let status: String
  let points: [BodyPoint]
  static let none = BodyDetection(status: "noPerson", points: [])
}

protocol BodyPoseDetecting: Sendable {
  func detect(_ jpeg: Data) throws -> BodyDetection
}

final class VisionBodyPoseDetector: BodyPoseDetecting, @unchecked Sendable {
  private let keys: [(String, VNHumanBodyPoseObservation.JointName)] = [
    ("neck", .neck), ("leftShoulder", .leftShoulder), ("rightShoulder", .rightShoulder),
    ("leftElbow", .leftElbow), ("rightElbow", .rightElbow),
    ("leftWrist", .leftWrist), ("rightWrist", .rightWrist),
    ("leftHip", .leftHip), ("rightHip", .rightHip),
    ("leftKnee", .leftKnee), ("rightKnee", .rightKnee),
    ("leftAnkle", .leftAnkle), ("rightAnkle", .rightAnkle),
  ]

  func detect(_ jpeg: Data) throws -> BodyDetection {
    guard PTPCodec.isJPEG(jpeg), jpeg.count <= 5_000_000,
      let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 960,
          // Vision applies the orientation below; JPEGTexture applies it to the preview.
          kCGImageSourceCreateThumbnailWithTransform: false,
        ] as CFDictionary)
    else { throw CameraError.invalidData("无法读取取景帧") }
    let rawOrientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[
      kCGImagePropertyOrientation
    ] as? UInt32
    let orientation = rawOrientation.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
    let request = VNDetectHumanBodyPoseRequest()
    try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
    let observations = request.results ?? []
    guard !observations.isEmpty else { return .none }
    // No identity tracking: decline to select a subject in a multi-person scene.
    guard observations.count == 1 else { return BodyDetection(status: "multiple", points: []) }
    let recognized = try observations[0].recognizedPoints(.all)
    let points = keys.compactMap { label, key -> BodyPoint? in
      guard let point = recognized[key] else { return nil }
      return BodyPoint.fromVision(
        name: label, x: Double(point.location.x), y: Double(point.location.y),
        confidence: Double(point.confidence))
    }
    guard points.count >= 4 else { return BodyDetection(status: "partial", points: []) }
    let ys = points.map(\.y)
    guard let low = ys.min(), let high = ys.max(), high - low >= 0.20 else {
      return BodyDetection(status: "tooFar", points: [])
    }
    return BodyDetection(status: "detected", points: points)
  }
}

/// Only one frame at a time, at most one new Vision request per second.
/// Invalidation makes late completions from a stopped or replaced session inert.
@MainActor
final class PoseTracker {
  private let detector: BodyPoseDetecting
  private let queue = DispatchQueue(label: "com.parado.canoneos.pose", qos: .utility)
  private let clock: () -> TimeInterval
  private let expirationNanoseconds: UInt64
  private var lastRequest: TimeInterval?
  private var inFlight = false
  private var epoch = 0
  private var expiration: Task<Void, Never>?
  private(set) var enabled = false
  private(set) var status = "off"
  private(set) var points: [BodyPoint] = []
  var onChange: (() -> Void)?

  init(
    detector: BodyPoseDetecting = VisionBodyPoseDetector(),
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    expirationNanoseconds: UInt64 = 2_500_000_000
  ) {
    self.detector = detector
    self.clock = clock
    self.expirationNanoseconds = expirationNanoseconds
  }

  var dictionary: [String: Any] {
    ["enabled": enabled, "status": status, "points": points.map(\.dictionary)]
  }

  func setEnabled(_ value: Bool) {
    enabled = value
    invalidate(status: value ? "waiting" : "off")
  }
  func suspend() { if enabled { invalidate(status: "waiting") } }
  private func invalidate(status: String) {
    epoch &+= 1
    lastRequest = nil
    expiration?.cancel()
    expiration = nil
    self.status = status
    points.removeAll()
    onChange?()
  }

  func submit(_ jpeg: Data) {
    guard enabled, !inFlight else { return }
    let now = clock()
    if let lastRequest, now - lastRequest < 1 { return }
    lastRequest = now
    inFlight = true
    let requestEpoch = epoch
    let detector = self.detector
    queue.async { [weak self] in
      let outcome = Result { try detector.detect(jpeg) }
      DispatchQueue.main.async { [weak self] in self?.finish(outcome, epoch: requestEpoch) }
    }
  }

  private func finish(_ outcome: Result<BodyDetection, Error>, epoch requestEpoch: Int) {
    inFlight = false
    guard enabled, requestEpoch == epoch else { return }
    switch outcome {
    case .success(let detection):
      status = detection.status
      points = detection.points
    case .failure:
      status = "error"
      points.removeAll()
    }
    onChange?()
    expiration?.cancel()
    let delay = expirationNanoseconds
    expiration = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: delay) } catch { return }
      guard let self, self.enabled, self.epoch == requestEpoch else { return }
      self.status = "waiting"
      self.points.removeAll()
      self.onChange?()
    }
  }
}
