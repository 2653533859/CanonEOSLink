import XCTest

@testable import CanonPTPCore

final class PTPTests: XCTestCase {
  func testCommandUsesLittleEndianAndFiveParameterLimit() throws {
    XCTAssertEqual(
      try PTPCodec.command(0x9153, transaction: 7, parameters: [0x0020_0000, 0, 0]),
      Data([24, 0, 0, 0, 1, 0, 0x53, 0x91, 7, 0, 0, 0, 0, 0, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
    XCTAssertThrowsError(
      try PTPCodec.command(0x1001, transaction: 1, parameters: [0, 0, 0, 0, 0, 0]))
  }
  func testResponseRejectsTruncatedAndWrongContainers() throws {
    let valid = Data([12, 0, 0, 0, 3, 0, 1, 0x20, 8, 0, 0, 0])
    XCTAssertEqual(try PTPCodec.response(valid).code, 0x2001)
    for count in 0..<valid.count {
      XCTAssertThrowsError(try PTPCodec.response(valid.prefix(count)))
    }
    var wrongType = valid
    wrongType[4] = 1
    XCTAssertThrowsError(try PTPCodec.response(wrongType))
  }
  func testEVFRecordsSkipMetadataAndRejectRAWAndCorruption() throws {
    let jpeg = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
    func record(_ type: UInt32, _ payload: Data) -> Data {
      var data = Data()
      data.appendLE(UInt32(payload.count + 8))
      data.appendLE(type)
      data.append(payload)
      return data
    }
    XCTAssertEqual(try PTPCodec.liveViewJPEG(record(8, Data([0])) + record(1, jpeg)), jpeg)
    XCTAssertEqual(try PTPCodec.liveViewJPEG(record(11, jpeg)), jpeg)
    XCTAssertThrowsError(try PTPCodec.liveViewJPEG(record(9, jpeg)))
    XCTAssertThrowsError(try PTPCodec.liveViewJPEG(Data(repeating: 0, count: 8)))
    XCTAssertThrowsError(try PTPCodec.liveViewJPEG(record(1, jpeg).dropLast()))
  }
  func testEOSPropertiesAndEvents() throws {
    XCTAssertEqual(
      PTPCodec.eosProperty(0xD1B0, value: 3), Data([12, 0, 0, 0, 0xb0, 0xd1, 0, 0, 3, 0, 0, 0]))
    var data = Data()
    for word: UInt32 in [16, 0xC189, 0xD1B0, 1, 16, 0xC189, 0xD1B1, 1, 8, 0] { data.appendLE(word) }
    XCTAssertEqual(try PTPCodec.liveViewProperties(data), [0xD1B0: 1, 0xD1B1: 1])
    var mode16 = Data()
    for word: UInt32 in [14, 0xC189, 0xD1B1] { mode16.appendLE(word) }
    mode16.appendLE(UInt16(1))
    XCTAssertEqual(try PTPCodec.liveViewProperties(mode16), [0xD1B1: 1])
    XCTAssertThrowsError(try PTPCodec.liveViewProperties(data.dropLast()))
  }
  func testDeviceInfoRejectsUnboundedArrays() {
    let corrupt = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff])
    XCTAssertThrowsError(try PTPDeviceInfo(data: corrupt))
  }
  func testAddedObjectHandlesFromGetEventAndPTPEventContainer() throws {
    var getEvent = Data()
    for word: UInt32 in [
      12, 0xC181, 0x0000_1234,
      12, 0xC186, 0x0000_5678,
      12, 0xC1A9, 0x0000_1234,
      12, 0xC181, 0,
      8, 0,
    ] {
      getEvent.appendLE(word)
    }
    XCTAssertEqual(try PTPCodec.addedObjectHandles(getEvent), [0x1234, 0x5678])

    var ptpEvent = Data()
    ptpEvent.appendLE(UInt32(16))
    ptpEvent.appendLE(UInt16(4))
    ptpEvent.appendLE(UInt16(0x4002))
    ptpEvent.appendLE(UInt32(9))
    ptpEvent.appendLE(UInt32(0xABCD_0001))
    XCTAssertEqual(PTPCodec.ptpEventObjectHandle(ptpEvent), 0xABCD_0001)

    var wrongType = ptpEvent
    wrongType[4] = 3
    XCTAssertNil(PTPCodec.ptpEventObjectHandle(wrongType))
    XCTAssertNil(PTPCodec.ptpEventObjectHandle(ptpEvent.dropLast()))
  }
}

@MainActor
final class CanonEOSTests: XCTestCase {
  func testShutdownRestoresEVFBeforeResettingRemoteAndEventModes() async throws {
    let transport = FakeTransport()
    let camera = CanonEOS(transport: transport)
    _ = try await camera.readDeviceInfo()
    try await camera.startLiveView()
    try await camera.shutdown()
    let tail = Array(transport.calls.suffix(5))
    XCTAssertEqual(tail.map(\.operation), [0x9110, 0x9110, 0x9114, 0x9114, 0x9115])
    XCTAssertEqual(tail.suffix(3).map(\.parameters), [[0], [1], [0]])
  }
  func testLiveViewRestoresOriginalValuesAndNeverSends9151() async throws {
    let transport = FakeTransport()
    let camera = CanonEOS(transport: transport)
    _ = try await camera.readDeviceInfo()
    try await camera.startLiveView()
    try await camera.stopLiveView()
    let writes = transport.calls.filter { $0.operation == 0x9110 }.map(\.data)
    XCTAssertEqual(
      writes,
      [
        PTPCodec.eosProperty(0xD1B0, value: 3), PTPCodec.eosProperty(0xD1B0, value: 1),
        PTPCodec.eosProperty(0xD1B1, value: 1),
      ])
    XCTAssertFalse(transport.calls.contains { $0.operation == 0x9151 })
  }
  func testFailedShutterIsReleasedWithoutRetry() async throws {
    let transport = FakeTransport()
    transport.failShutter = true
    let camera = CanonEOS(transport: transport)
    _ = try await camera.readDeviceInfo()
    do {
      try await camera.capture()
      XCTFail("Expected failure")
    } catch {}
    XCTAssertEqual(transport.calls.filter { $0.operation == 0x9128 }.count, 1)
    XCTAssertEqual(transport.calls.last?.operation, 0x9129)
    XCTAssertEqual(transport.calls.last?.parameters, [3])
  }
  func testMissingOriginalEVFPropertiesBlocksWrites() async throws {
    let transport = FakeTransport()
    transport.hasEVF = false
    let camera = CanonEOS(transport: transport)
    _ = try await camera.readDeviceInfo()
    do {
      try await camera.startLiveView()
      XCTFail("Expected failure")
    } catch {}
    XCTAssertFalse(transport.calls.contains { $0.operation == 0x9110 })
  }
  func testNonCanonDeviceCannotReceiveVendorCommands() async throws {
    let transport = FakeTransport()
    transport.manufacturer = "Other"
    let camera = CanonEOS(transport: transport)
    _ = try await camera.readDeviceInfo()
    do {
      try await camera.capture()
      XCTFail("Expected failure")
    } catch {}
    XCTAssertEqual(transport.calls.map(\.operation), [0x1001])
  }
  func testExposureRefreshPreservesObjectEventsAndAcknowledgeTransfer() async throws {
    let transport = FakeTransport()
    var eventBytes = Data()
    for word: UInt32 in [
      16, 0xC189, 0xD105, 3,
      16, 0xC189, 0xD101, 0x30,
      16, 0xC189, 0xD102, 0x78,
      16, 0xC189, 0xD103, 0x58,
      16, 0xC189, 0xD104, 0,
      12, 0xC186, 0x0001_0002,
    ] {
      eventBytes.appendLE(word)
    }
    transport.extraGetEvent = eventBytes
    let camera = CanonEOS(transport: transport)
    _ = try await camera.readDeviceInfo()
    try await camera.refreshExposure()
    XCTAssertEqual(camera.drainPendingObjectHandles(), [0x0001_0002])
    XCTAssertEqual(camera.drainPendingObjectHandles(), [])
    try await camera.acknowledgeObjectTransfer(0x0001_0002)
    XCTAssertEqual(transport.calls.last?.operation, 0x9117)
    XCTAssertEqual(transport.calls.last?.parameters, [0x0001_0002])
  }
  func testAutofocusHalfPressesAndReleasesEvenOnFailure() async throws {
    let transport = FakeTransport()
    let camera = CanonEOS(transport: transport)
    _ = try await camera.readDeviceInfo()
    try await camera.autofocus()
    let afCalls = transport.calls.suffix(2)
    XCTAssertEqual(afCalls.map(\.operation), [0x9128, 0x9129])
    XCTAssertEqual(afCalls.map(\.parameters), [[1, 0], [1]])

    transport.failShutter = true
    do {
      try await camera.autofocus()
      XCTFail("Expected failure")
    } catch {}
    XCTAssertEqual(transport.calls.last?.operation, 0x9129)
    XCTAssertEqual(transport.calls.last?.parameters, [1])
  }
}

@MainActor
private final class FakeTransport: PTPTransport {
  struct Call {
    let operation: UInt16
    let parameters: [UInt32]
    let data: Data?
  }
  var calls: [Call] = []
  var failShutter = false
  var hasEVF = true
  var manufacturer = "Canon Inc."
  var extraGetEvent = Data()
  func send(_ operation: UInt16, parameters: [UInt32], data: Data?) async throws -> PTPResponse {
    calls.append(Call(operation: operation, parameters: parameters, data: data))
    var payload = Data()
    if operation == 0x1001 {
      payload.appendLE(UInt16(100))
      payload.appendLE(UInt32(11))
      payload.appendLE(UInt16(100))
      appendString("", to: &payload)
      payload.appendLE(UInt16(0))
      let operations: [UInt16] = [
        0x1001, 0x9110, 0x9114, 0x9115, 0x9116, 0x9117, 0x9127, 0x9128, 0x9129, 0x9153,
      ]
      payload.appendLE(UInt32(operations.count))
      operations.forEach { payload.appendLE($0) }
      for _ in 0..<4 { payload.appendLE(UInt32(0)) }
      for string in [manufacturer, "EOS R10", "1.0", "serial"] {
        appendString(string, to: &payload)
      }
    }
    if operation == 0x9116 {
      if hasEVF {
        for word: UInt32 in [16, 0xC189, 0xD1B0, 1, 16, 0xC189, 0xD1B1, 1] {
          payload.appendLE(word)
        }
      }
      if !extraGetEvent.isEmpty { payload.append(extraGetEvent) }
      for word: UInt32 in [8, 0] { payload.appendLE(word) }
    }
    return PTPResponse(
      code: operation == 0x9128 && failShutter ? 0x2019 : 0x2001, transaction: 1, parameters: [],
      data: payload)
  }
  private func appendString(_ value: String, to data: inout Data) {
    data.append(UInt8(value.utf16.count + 1))
    value.utf16.forEach { data.appendLE($0) }
    data.appendLE(UInt16(0))
  }
}
