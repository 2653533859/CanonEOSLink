import Foundation

@MainActor
final class CanonEOS {
  private let transport: PTPTransport
  private(set) var info: PTPDeviceInfo?
  private(set) var remoteEnabled = false
  private var viewfinderEnabled = false
  private var properties: [UInt32: UInt32] = [:]
  private var originalProperties: [UInt32: UInt32] = [:]
  private(set) var exposure = ExposureSettings()
  private(set) var pendingObjectHandles: [UInt32] = []
  private var undo: (property: ExposureProperty, before: UInt32, after: UInt32, mode: UInt32)?
  var canUndoExposure: Bool { undo != nil }
  var viewfinderParameter: UInt32 = 0x0020_0000

  init(transport: PTPTransport) { self.transport = transport }

  func drainPendingObjectHandles() -> [UInt32] {
    let drained = pendingObjectHandles
    pendingObjectHandles.removeAll()
    return drained
  }

  private func recordObjectEvents(in data: Data) throws {
    for handle in try PTPCodec.addedObjectHandles(data)
    where !pendingObjectHandles.contains(handle) {
      pendingObjectHandles.append(handle)
    }
  }

  @discardableResult
  private func command(_ operation: UInt16, _ parameters: [UInt32] = [], data: Data? = nil)
    async throws -> PTPResponse
  {
    let result = try await transport.send(operation, parameters: parameters, data: data)
    guard result.code == 0x2001 else { throw CameraError.response(operation, result.code) }
    return result
  }

  func readDeviceInfo() async throws -> PTPDeviceInfo {
    let response = try await command(0x1001)
    let result = try PTPDeviceInfo(data: response.data)
    info = result
    return result
  }

  func prepareRemote() async throws {
    guard !remoteEnabled else { return }
    guard let info, info.manufacturer.lowercased().contains("canon"),
      info.operations.contains(0x9114), info.operations.contains(0x9115)
    else {
      throw CameraError.unavailable("设备未声明 Canon EOS 远程控制能力")
    }
    try await command(0x9114, [1])
    remoteEnabled = true  // Ensure cleanup even if EventMode fails.
    do {
      try await command(0x9115, [1])
      // Initialization only: continuously consuming EOS GetEvent would
      // compete with ImageCaptureCore's content catalog handling.
      for _ in 0..<5 {
        let events = try await command(0x9116)
        try recordObjectEvents(in: events.data)
        properties.merge(try PTPCodec.liveViewProperties(events.data)) { _, new in new }
        exposure.ingest(try EOSPropertyCodec.parse(events.data))
        if properties[0xD1B0] != nil && properties[0xD1B1] != nil { break }
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    } catch {
      try? await shutdown()
      throw error
    }
  }

  /// Explicit refresh requests each property. A cached value is not proof that
  /// the camera still has that value after a physical dial or lens change.
  func refreshExposure() async throws {
    try await prepareRemote()
    guard info?.operations.contains(0x9127) == true else {
      exposure.verified = false
      throw CameraError.unavailable("相机未声明参数读取命令")
    }
    exposure.verified = false
    let requiredCodes = [EOSPropertyCodec.mode] + ExposureProperty.allCases.map(\.code)
    let requestCodes = [EOSPropertyCodec.flash] + requiredCodes
    var confirmed: Set<UInt32> = []
    for code in requestCodes {
      // Some cameras refuse properties in specific modes. Leave only that
      // field unavailable, but propagate transport and timeout failures.
      do { try await command(0x9127, [code]) } catch CameraError.response { continue }
    }
    for _ in 0..<5 {
      let response = try await command(0x9116)
      try recordObjectEvents(in: response.data)
      let events = try EOSPropertyCodec.parse(response.data)
      exposure.ingest(events)
      confirmed.formUnion(events.filter { $0.value != nil }.map(\.property))
      if Set(requiredCodes).isSubset(of: confirmed) { break }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    exposure.discardUnconfirmed(confirmed)
    guard exposure.verified else { throw CameraError.unavailable("未能确认相机曝光模式或参数，请重试") }
  }

  func setExposure(_ property: ExposureProperty, value: UInt32, revision: Int) async throws {
    try await refreshExposure()
    try exposure.validate([property: value], expectedRevision: revision)
    guard let previous = exposure.values[property.code], let mode = exposure.mode else {
      throw CameraError.unavailable("缺少原始参数，不能修改")
    }
    if previous == value { return }
    // Record intent before sending: a transport failure does not prove the
    // camera ignored the write. Undo will only run after a fresh readback.
    undo = (property, previous, value, mode)
    try await writeAndConfirm(property, value: value, expectedMode: mode)
  }

  func undoExposure() async throws {
    guard let entry = undo else { throw CameraError.unavailable("没有可撤销的参数修改") }
    try await refreshExposure()
    guard exposure.mode == entry.mode, exposure.values[entry.property.code] == entry.after,
      exposure.allowsMode(entry.property),
      exposure.options(entry.property).contains(where: { $0.raw == entry.before })
    else {
      throw CameraError.unavailable("相机模式或参数已变化，不能安全撤销；请手动检查")
    }
    try await writeAndConfirm(entry.property, value: entry.before, expectedMode: entry.mode)
    undo = nil
  }

  private func writeAndConfirm(_ property: ExposureProperty, value: UInt32, expectedMode: UInt32)
    async throws
  {
    exposure.verified = false
    try await command(0x9110, data: PTPCodec.eosProperty(property.code, value: value))
    // A successful setter response is not readback. Require a new value event.
    try await command(0x9127, [property.code])
    try await command(0x9127, [EOSPropertyCodec.mode])
    var confirmedValue: UInt32?
    var confirmedMode: UInt32?
    for _ in 0..<5 {
      let response = try await command(0x9116)
      try recordObjectEvents(in: response.data)
      let events = try EOSPropertyCodec.parse(response.data)
      exposure.ingest(events)
      if let reported = events.last(where: { $0.property == property.code && $0.value != nil })?
        .value
      {
        confirmedValue = reported
      }
      if let reported = events.last(where: {
        $0.property == EOSPropertyCodec.mode && $0.value != nil
      })?.value {
        confirmedMode = reported
      }
      if let confirmedValue, let confirmedMode {
        guard confirmedValue == value, confirmedMode == expectedMode else {
          throw CameraError.unavailable("相机返回的参数与请求不一致，请刷新检查")
        }
        // A fresh full read is still required before the next write.
        return
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw CameraError.unavailable("写入已发送，但相机未确认实际值；请刷新后检查")
  }

  func startLiveView() async throws {
    guard info?.operations.contains(0x9153) == true,
      info?.operations.contains(0x9110) == true
    else {
      throw CameraError.unavailable("设备未声明 EOS 实时取景能力")
    }
    try await prepareRemote()
    guard let output = properties[0xD1B0], let mode = properties[0xD1B1] else {
      throw CameraError.unavailable("未取得 EVF 原始属性，不能安全启动取景；请导出日志并重新连接")
    }
    originalProperties = [0xD1B0: output, 0xD1B1: mode]
    viewfinderEnabled = true
    do {
      if mode != 1 { try await command(0x9110, data: PTPCodec.eosProperty(0xD1B1, value: 1)) }
      try await command(0x9110, data: PTPCodec.eosProperty(0xD1B0, value: output | 2))
    } catch {
      try? await stopLiveView()
      throw error
    }
  }

  func frame() async throws -> Data {
    let response = try await command(0x9153, [viewfinderParameter, 0, 0])
    return try PTPCodec.liveViewJPEG(response.data)
  }

  func stopLiveView() async throws {
    guard viewfinderEnabled else { return }
    var firstError: Error?
    for property: UInt32 in [0xD1B0, 0xD1B1] {
      if let value = originalProperties[property] {
        do { try await command(0x9110, data: PTPCodec.eosProperty(property, value: value)) } catch {
          firstError = firstError ?? error
        }
      }
    }
    if let firstError { throw firstError }
    viewfinderEnabled = false
  }

  func autofocus() async throws {
    guard info?.operations.contains(0x9128) == true, info?.operations.contains(0x9129) == true
    else {
      throw CameraError.unavailable("设备未声明 EOS 遥控对焦能力")
    }
    try await prepareRemote()
    // Half press with autofocus enabled; always attempt release.
    do { try await command(0x9128, [1, 0]) } catch {
      _ = try? await command(0x9129, [1])
      throw error
    }
    try await command(0x9129, [1])
  }

  func capture() async throws {
    guard info?.operations.contains(0x9128) == true, info?.operations.contains(0x9129) == true
    else {
      throw CameraError.unavailable("设备未声明 EOS 遥控快门能力")
    }
    try await prepareRemote()
    // Full press, autofocus enabled; always attempt release, even after a
    // failed press. Never retry a shutter command automatically.
    do { try await command(0x9128, [3, 0]) } catch {
      _ = try? await command(0x9129, [3])
      throw error
    }
    try await command(0x9129, [3])
  }

  func acknowledgeObjectTransfer(_ handle: UInt32) async throws {
    guard handle != 0, info?.operations.contains(0x9117) == true else { return }
    try await command(0x9117, [handle])
  }

  func shutdown() async throws {
    var firstError: Error?
    do { try await stopLiveView() } catch { firstError = error }
    if remoteEnabled {
      do { try await command(0x9114, [0]) } catch { firstError = firstError ?? error }
      // EOS reset sequence used upstream to restore the camera screen.
      do { try await command(0x9114, [1]) } catch { firstError = firstError ?? error }
      do { try await command(0x9115, [0]) } catch { firstError = firstError ?? error }
      remoteEnabled = false
    }
    if let firstError { throw firstError }
  }
}
