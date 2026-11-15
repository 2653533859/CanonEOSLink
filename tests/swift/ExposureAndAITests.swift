import Foundation
import XCTest

@testable import CanonPTPCore

private func event(_ type: UInt32, _ words: [UInt32]) -> Data {
  var data = Data()
  data.appendLE(UInt32(8 + words.count * 4))
  data.appendLE(type)
  words.forEach { data.appendLE($0) }
  return data
}
private func valueEvent(_ property: UInt32, _ value: UInt32) -> Data {
  event(0xC189, [property, value])
}
private func listEvent(_ property: UInt32, _ values: [UInt32]) -> Data {
  event(0xC18A, [property, 3, UInt32(values.count)] + values)
}
private func makeExposure() throws -> ExposureSettings {
  let data =
    valueEvent(0xD105, 3) + valueEvent(0xD101, 0x30) + valueEvent(0xD102, 0x78)
    + valueEvent(0xD103, 0x58) + valueEvent(0xD104, 0) + listEvent(0xD101, [0x28, 0x30])
    + listEvent(0xD102, [0x70, 0x78]) + listEvent(0xD103, [0x58, 0x60])
    + listEvent(0xD104, [0, 3, 0xfd])
  let events = try EOSPropertyCodec.parse(data)
  var result = ExposureSettings()
  result.ingest(events)
  result.discardUnconfirmed(Set(events.filter { $0.value != nil }.map(\.property)))
  return result
}

final class ExposureCodecTests: XCTestCase {
  func testParsesPropertyWidthAndFourByteSlots() throws {
    let data = valueEvent(0xD104, 0xffff_fffd) + listEvent(0xD104, [0, 3, 0xffff_fffd])
    let events = try EOSPropertyCodec.parse(data)
    XCTAssertEqual(events[0].value, 0xfd)
    XCTAssertEqual(events[1].available, [0, 3, 0xfd])
    XCTAssertEqual(
      ExposureCatalog.option(.compensation, raw: 0xfd)?.value ?? 1, -1.0 / 3, accuracy: 0.0001)
  }
  func testRejectsMalformedListAndUnknownFormatClearsOldOptions() throws {
    XCTAssertThrowsError(try EOSPropertyCodec.parse(event(0xC18A, [0xD103, 3, 9999])))
    var settings = try makeExposure()
    settings.ingest(try EOSPropertyCodec.parse(event(0xC18A, [0xD103, 7, 1, 0x58])))
    XCTAssertTrue(settings.options(.iso).isEmpty)
    XCTAssertThrowsError(try settings.validate([.iso: 0x58], expectedRevision: settings.revision))
  }
  func testModeChangeInvalidatesOptionsAndOldRevision() throws {
    var settings = try makeExposure()
    let revision = settings.revision
    try settings.validate([.aperture: 0x28], expectedRevision: revision)
    settings.ingest(try EOSPropertyCodec.parse(valueEvent(0xD105, 0)))
    XCTAssertFalse(settings.verified)
    XCTAssertTrue(settings.options(.aperture).isEmpty)
    XCTAssertThrowsError(try settings.validate([.aperture: 0x28], expectedRevision: revision))
  }
  func testUnknownAndOutOfModeValuesCannotBeApplied() throws {
    var settings = try makeExposure()
    settings.ingest(try EOSPropertyCodec.parse(listEvent(0xD101, [0x0f00, 0x30])))
    XCTAssertEqual(settings.options(.aperture).map(\.raw), [0x30])
    XCTAssertThrowsError(
      try settings.validate([.aperture: 0x0f00], expectedRevision: settings.revision))
    XCTAssertThrowsError(
      try settings.validate([.compensation: 3], expectedRevision: settings.revision))
  }
  func testMissingReadbackDisablesThatField() throws {
    var settings = try makeExposure()
    settings.discardUnconfirmed([0xD105, 0xD103])
    XCTAssertNil(settings.values[0xD101])
    XCTAssertThrowsError(
      try settings.validate([.aperture: 0x28], expectedRevision: settings.revision))
    try settings.validate([.iso: 0x60], expectedRevision: settings.revision)
  }
  func testR10FvModeAndExtendedCatalogCodes() throws {
    let data =
      valueEvent(0xD105, 0x37) + valueEvent(0xD101, 0x68) + valueEvent(0xD102, 0xA8)
      + valueEvent(0xD103, 0x90) + valueEvent(0xD104, 0)
      + listEvent(0xD101, [0x58, 0x68]) + listEvent(0xD102, [0xA0, 0xA8])
      + listEvent(0xD103, [0x88, 0x90]) + listEvent(0xD104, [0, 3])
    let events = try EOSPropertyCodec.parse(data)
    var settings = ExposureSettings()
    settings.ingest(events)
    settings.discardUnconfirmed(Set(events.filter { $0.value != nil }.map(\.property)))
    XCTAssertEqual(settings.modeLabel, "Fv")
    XCTAssertEqual(ExposureCatalog.option(.aperture, raw: 0x68)?.label, "f/64")
    XCTAssertEqual(ExposureCatalog.option(.shutter, raw: 0xA8)?.label, "1/16000")
    XCTAssertEqual(ExposureCatalog.option(.iso, raw: 0x90)?.label, "51200")
    try settings.validate(
      [.aperture: 0x58, .shutter: 0xA0, .iso: 0x88, .compensation: 3],
      expectedRevision: settings.revision)
  }
}

@MainActor
final class ExposureWriteTests: XCTestCase {
  func testWriteAndUndoRequireFreshMatchingReadback() async throws {
    let transport = ExposureTransport()
    let camera = CanonEOS(transport: transport)
    _ = try await camera.readDeviceInfo()
    try await camera.refreshExposure()
    let revision = camera.exposure.revision
    try await camera.setExposure(.iso, value: 0x60, revision: revision)
    XCTAssertEqual(transport.values[0xD103], 0x60)
    XCTAssertTrue(camera.canUndoExposure)
    XCTAssertFalse(camera.exposure.verified)
    try await camera.undoExposure()
    XCTAssertEqual(transport.values[0xD103], 0x58)
    XCTAssertFalse(camera.canUndoExposure)
  }
  func testExternalChangeBlocksStaleWriteAndUndo() async throws {
    let transport = ExposureTransport()
    let camera = CanonEOS(transport: transport)
    _ = try await camera.readDeviceInfo()
    try await camera.refreshExposure()
    let revision = camera.exposure.revision
    transport.values[0xD105] = 0
    do {
      try await camera.setExposure(.iso, value: 0x60, revision: revision)
      XCTFail("stale write")
    } catch {}
    XCTAssertEqual(transport.writes.count, 0)

    transport.values[0xD105] = 3
    try await camera.refreshExposure()
    // Mode changes invalidate old lists, so the camera must provide fresh lists.
    transport.includeLists = true
    try await camera.refreshExposure()
    try await camera.setExposure(.iso, value: 0x60, revision: camera.exposure.revision)
    transport.values[0xD103] = 0x58
    do {
      try await camera.undoExposure()
      XCTFail("external value changed")
    } catch {}
    XCTAssertEqual(transport.writes.count, 1)
  }
  func testAcceptedWriteWithoutReadbackIsNotClaimedSuccessful() async throws {
    let transport = ExposureTransport()
    let camera = CanonEOS(transport: transport)
    _ = try await camera.readDeviceInfo()
    try await camera.refreshExposure()
    transport.noConfirmation = true
    do {
      try await camera.setExposure(.iso, value: 0x60, revision: camera.exposure.revision)
      XCTFail("unconfirmed")
    } catch {}
    XCTAssertFalse(camera.exposure.verified)
    XCTAssertTrue(camera.canUndoExposure)
    XCTAssertEqual(transport.writes.count, 1)
  }
  func testModeChangeDuringWriteCannotBeConfirmed() async throws {
    let transport = ExposureTransport()
    let camera = CanonEOS(transport: transport)
    _ = try await camera.readDeviceInfo()
    try await camera.refreshExposure()
    transport.modeAfterWrite = 0
    do {
      try await camera.setExposure(.iso, value: 0x60, revision: camera.exposure.revision)
      XCTFail("mode changed during write")
    } catch {}
    XCTAssertFalse(camera.exposure.verified)
    XCTAssertEqual(transport.writes.count, 1)
  }
}

@MainActor
private final class ExposureTransport: PTPTransport {
  var values: [UInt32: UInt32] = [0xD105: 3, 0xD101: 0x30, 0xD102: 0x78, 0xD103: 0x58, 0xD104: 0]
  var requested: [UInt32] = []
  var includeLists = true
  var noConfirmation = false
  var modeAfterWrite: UInt32?
  var writes: [(UInt32, UInt32)] = []
  func send(_ operation: UInt16, parameters: [UInt32], data: Data?) async throws -> PTPResponse {
    var result = Data()
    if operation == 0x1001 {
      result.appendLE(UInt16(100))
      result.appendLE(UInt32(11))
      result.appendLE(UInt16(100))
      appendString("", to: &result)
      result.appendLE(UInt16(0))
      let operations: [UInt16] = [0x1001, 0x9110, 0x9114, 0x9115, 0x9116, 0x9127]
      result.appendLE(UInt32(operations.count))
      operations.forEach { result.appendLE($0) }
      for _ in 0..<4 { result.appendLE(UInt32(0)) }
      ["Canon Inc.", "EOS R10", "1.0", "serial"].forEach { appendString($0, to: &result) }
    }
    if operation == 0x9110, let data {
      var r = PTPReader(data: data)
      _ = try r.u32()
      let property = try r.u32()
      let value = try r.u32()
      writes.append((property, value))
      values[property] = value
      if let modeAfterWrite { values[0xD105] = modeAfterWrite }
    }
    if operation == 0x9127 { requested.append(parameters[0]) }
    if operation == 0x9116 {
      result = valueEvent(0xD1B0, 1) + valueEvent(0xD1B1, 1)
      if includeLists {
        result +=
          listEvent(0xD101, [0x28, 0x30]) + listEvent(0xD102, [0x70, 0x78])
          + listEvent(0xD103, [0x58, 0x60]) + listEvent(0xD104, [0, 3, 0xfd])
        includeLists = false
      }
      for property in requested
      where !(noConfirmation && !writes.isEmpty && property == writes.last?.0) {
        if let value = values[property] { result += valueEvent(property, value) }
      }
      requested.removeAll()
    }
    return PTPResponse(code: 0x2001, transaction: 1, parameters: [], data: result)
  }
  private func appendString(_ value: String, to data: inout Data) {
    data.append(UInt8(value.utf16.count + 1))
    value.utf16.forEach { data.appendLE($0) }
    data.appendLE(UInt16(0))
  }
}

final class GuidanceTests: XCTestCase {
  func testOnlyExactCurrentModeOptionsAreApplicable() throws {
    let exposure = try makeExposure()
    let content =
      #"{"summary":"人像","composition":["注意背景"],"confidence":0.8,"recommendations":[{"property":"iso","value":800,"reason":"防抖"},{"property":"aperture","value":1.4,"reason":"背景"},{"property":"compensation","value":0.3333333333,"reason":"提亮"}]}"#
    let result = try GuidanceResult.parse(content, exposure: exposure)
    XCTAssertEqual(result.suggestions.map { $0.option?.raw }, [0x60, nil, nil])
    XCTAssertEqual(result.suggestions[0].revision, exposure.revision)
  }
  func testRejectsInvalidOrDuplicateModelOutput() throws {
    let exposure = try makeExposure()
    for content in [
      "not json", #"{"summary":"x","composition":[],"confidence":true,"recommendations":[]}"#,
      #"{"summary":"x","composition":[],"confidence":0.9,"recommendations":[{"property":"iso","value":800,"reason":"x"},{"property":"iso","value":400,"reason":"x"}]}"#,
    ] {
      XCTAssertThrowsError(try GuidanceResult.parse(content, exposure: exposure))
    }
  }
  func testPoseRecommendationsOnlyReturnKnownUniqueIDs() throws {
    let content = #"{"summary":"x","composition":[],"confidence":0.8,"recommendations":[],"pose_recommendations":[{"id":"pose_a","reason":"构图合适"},{"id":"unknown","reason":"无效"},{"id":"pose_a","reason":"重复"},{"id":"pose_b","reason":"光线柔和"}]}"#
    let result = try GuidanceResult.parse(content, exposure: makeExposure(), poseIDs: ["pose_a", "pose_b"])
    XCTAssertEqual(result.poseRecommendations.compactMap { $0["id"] }, ["pose_a", "pose_b"])
  }
  func testLowConfidenceCannotApplyAndEndpointMustBeHTTPS() throws {
    let exposure = try makeExposure()
    let content =
      #"{"summary":"x","composition":[],"confidence":0.3,"recommendations":[{"property":"iso","value":800,"reason":"x"}]}"#
    XCTAssertNil(try GuidanceResult.parse(content, exposure: exposure).suggestions[0].option)
    XCTAssertThrowsError(
      try AIConfiguration(
        endpoint: "http://example.com/v1/chat/completions", model: "m", apiKey: "x"))
    XCTAssertThrowsError(
      try AIConfiguration(
        endpoint: "https://name:secret@example.com/v1/chat/completions", model: "m", apiKey: "x"))
  }
  func testShutterAdviceIsReadOnlyWhenFlashSyncIsUnknown() throws {
    let exposure = try makeExposure()
    let content =
      #"{"summary":"x","composition":[],"confidence":0.9,"recommendations":[{"property":"shutter","value":0.008,"reason":"防抖"}]}"#
    XCTAssertNil(try GuidanceResult.parse(content, exposure: exposure).suggestions[0].option)
  }
  func testShutterAdviceRespectsFlashStateAndSyncSpeed() throws {
    var exposure = try makeExposure()
    exposure.ingest(try EOSPropertyCodec.parse(listEvent(0xD102, [0x70, 0x78, 0x88])))
    exposure.ingest(try EOSPropertyCodec.parse(valueEvent(0xD120, 0)))
    let fastShutter =
      #"{"summary":"x","composition":[],"confidence":0.9,"recommendations":[{"property":"shutter","value":0.001,"reason":"高速"}]}"#
    XCTAssertEqual(
      try GuidanceResult.parse(fastShutter, exposure: exposure).suggestions[0].option?.raw, 0x88)

    exposure.ingest(try EOSPropertyCodec.parse(valueEvent(0xD120, 1)))
    XCTAssertNil(try GuidanceResult.parse(fastShutter, exposure: exposure).suggestions[0].option)

    let syncSafe =
      #"{"summary":"x","composition":[],"confidence":0.9,"recommendations":[{"property":"shutter","value":0.008,"reason":"同步"}]}"#
    XCTAssertEqual(
      try GuidanceResult.parse(syncSafe, exposure: exposure).suggestions[0].option?.raw, 0x70)
  }
}

private final class MockAIProtocol: URLProtocol {
  static var received: URLRequest?
  static var requestBody = Data()
  static var status = 200
  static var body = Data()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.received = request
    if let body = request.httpBody {
      Self.requestBody = body
    } else if let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
      }
      Self.requestBody = data
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: Self.status, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

final class GuidanceNetworkTests: XCTestCase {
  func testPhotoAnalysisUsesCurrentRecipeAndValidatesReturnedRecipe() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockAIProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let provider = try AIConfiguration(
      endpoint: "https://example.test/v1/chat/completions", model: "vision", apiKey: "key")
    let json =
      #"{"summary":"偏暗","composition":["注意背景"],"confidence":0.9,"recipe":{"exposure":0.4,"contrast":1.1,"saturation":1,"warmth":0.2}}"#
    MockAIProtocol.body = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": json]]]
    ])
    MockAIProtocol.status = 200
    let result = try await AIGuidanceService(session: session).analyzePhoto(
      jpeg: Data([0xff, 0xd8, 0xff, 0xd9]),
      recipe: PhotoRecipe(exposure: 0.2, highlights: -0.4, shadows: 0.6), goal: "人像",
      configuration: provider)
    XCTAssertEqual(result.recipe?.exposure, 0.4)
    XCTAssertEqual(result.recipe?.highlights, -0.4)
    XCTAssertEqual(result.recipe?.shadows, 0.6)
    XCTAssertEqual(result.dictionary["applicable"] as? Bool, true)
    let payload = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: MockAIProtocol.requestBody) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
    let context = try XCTUnwrap(parts.first?["text"] as? String)
    XCTAssertTrue(context.contains("current_recipe"))
    XCTAssertTrue(context.contains("0.2"))
  }
  func testImageAndSettingsAreSentOnlyToConfiguredEndpointAndResponseIsValidated() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockAIProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let service = AIGuidanceService(session: session)
    let provider = try AIConfiguration(
      endpoint: "https://example.test/v1/chat/completions", model: "vision-model",
      apiKey: "test-key")
    let json =
      #"{"summary":"自然光","composition":["注意背景"],"confidence":0.9,"recommendations":[{"property":"iso","value":800,"reason":"稳定曝光"}]}"#
    MockAIProtocol.body = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": json]]]
    ])
    MockAIProtocol.status = 200
    let result = try await service.analyze(
      jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), exposure: makeExposure(), goal: "人像",
      configuration: provider)
    XCTAssertEqual(result.suggestions.first?.option?.raw, 0x60)
    let request = try XCTUnwrap(MockAIProtocol.received)
    XCTAssertEqual(request.url?.absoluteString, "https://example.test/v1/chat/completions")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    let payload = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: MockAIProtocol.requestBody) as? [String: Any])
    XCTAssertEqual(payload["model"] as? String, "vision-model")
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
    let image = try XCTUnwrap(parts.last?["image_url"] as? [String: Any])
    XCTAssertTrue((image["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    let text = String(decoding: MockAIProtocol.requestBody, as: UTF8.self)
    XCTAssertFalse(text.contains("test-key"))
  }
  func testFrameRequestIncludesPoseCandidatesAndFiltersResponse() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockAIProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let service = AIGuidanceService(session: session)
    let provider = try AIConfiguration(endpoint: "https://example.test/v1/chat/completions", model: "vision-model", apiKey: "test-key")
    let json = #"{"summary":"室外","composition":[],"confidence":0.8,"recommendations":[],"pose_recommendations":[{"id":"valid","reason":"适合画面"},{"id":"invented","reason":"不存在"}]}"#
    MockAIProtocol.body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": json]]]])
    MockAIProtocol.status = 200
    let result = try await service.analyze(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), exposure: makeExposure(), goal: "人像", configuration: provider, poses: [["id": "valid", "title": "站姿"]])
    XCTAssertEqual(result.poseRecommendations.first?["id"], "valid")
    XCTAssertEqual(result.poseRecommendations.count, 1)
    let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: MockAIProtocol.requestBody) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
    XCTAssertTrue(try XCTUnwrap(parts.first?["text"] as? String).contains("valid"))
  }
  func testHTTPErrorDoesNotExposeServerResponseOrKey() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockAIProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let provider = try AIConfiguration(
      endpoint: "https://example.test/v1/chat/completions", model: "m", apiKey: "secret")
    MockAIProtocol.status = 401
    MockAIProtocol.body = Data("secret-sensitive-error".utf8)
    do {
      _ = try await AIGuidanceService(session: session).analyze(
        jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), exposure: makeExposure(), goal: "",
        configuration: provider)
      XCTFail("expected error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("401"))
      XCTAssertFalse(error.localizedDescription.contains("secret"))
    }
  }
}
