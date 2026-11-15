import Foundation

@MainActor
protocol PTPTransport: AnyObject {
  func send(_ operation: UInt16, parameters: [UInt32], data: Data?) async throws -> PTPResponse
}

enum CameraError: LocalizedError {
  case invalidData(String)
  case response(UInt16, UInt16)
  case unavailable(String)
  case timeout
  case disconnected

  var errorDescription: String? {
    switch self {
    case .invalidData(let message), .unavailable(let message): return message
    case .response(let operation, let code):
      return String(format: "PTP 0x%04X 返回 0x%04X", operation, code)
    case .timeout: return "相机请求超时，请断开并重新连接"
    case .disconnected: return "相机已断开"
    }
  }
}

struct PTPResponse {
  let code: UInt16
  let transaction: UInt32
  let parameters: [UInt32]
  let data: Data
}

struct PTPDeviceInfo {
  let vendorExtension: UInt32
  let operations: Set<UInt16>
  let manufacturer: String
  let model: String
  let version: String

  init(data: Data) throws {
    var reader = PTPReader(data: data)
    _ = try reader.u16()  // StandardVersion
    vendorExtension = try reader.u32()
    _ = try reader.u16()
    _ = try reader.string()
    _ = try reader.u16()  // FunctionalMode
    operations = Set(try reader.array16())
    for _ in 0..<4 { _ = try reader.array16() }  // events, properties, capture/image formats
    manufacturer = try reader.string()
    model = try reader.string()
    version = try reader.string()
    _ = try reader.string()  // Do not export camera serial numbers to diagnostics.
  }
}

enum PTPCodec {
  /// GetEvent records: length, event code, property code, property value.
  /// Only these UInt32 EVF properties are interpreted; other EOS data types
  /// require the camera's property description and must not be guessed.
  static func liveViewProperties(_ data: Data) throws -> [UInt32: UInt32] {
    var reader = PTPReader(data: data)
    var values: [UInt32: UInt32] = [:]
    while reader.remaining > 0 {
      let length = Int(try reader.u32())
      let event = try reader.u32()
      guard length >= 8, length - 8 <= reader.remaining else {
        throw CameraError.invalidData("EOS 事件长度无效")
      }
      var payload = PTPReader(data: try reader.bytes(length - 8))
      if event == 0xC189, payload.remaining >= 4 {
        let property = try payload.u32()
        if property == 0xD1B0 {
          values[property] = try payload.u32()
        } else if property == 0xD1B1 {
          values[property] = UInt32(try payload.u16())
        }
      }
    }
    return values
  }

  /// Extract added or transfer-requested object handles from Canon GetEvent (0x9116).
  static func addedObjectHandles(_ data: Data) throws -> [UInt32] {
    var reader = PTPReader(data: data)
    var handles: [UInt32] = []
    var seen: Set<UInt32> = []
    while reader.remaining > 0 {
      let length = Int(try reader.u32())
      let event = try reader.u32()
      guard length >= 8, length - 8 <= reader.remaining else {
        throw CameraError.invalidData("EOS 事件长度无效")
      }
      var payload = PTPReader(data: try reader.bytes(length - 8))
      if [UInt32(0xC181), 0xC186, 0xC1A9].contains(event), payload.remaining >= 4 {
        let handle = try payload.u32()
        if handle != 0 && seen.insert(handle).inserted {
          handles.append(handle)
        }
      }
    }
    return handles
  }

  /// Parse standard PTP event containers (type == 4) delivered via ImageCaptureCore.
  static func ptpEventObjectHandle(_ data: Data) -> UInt32? {
    var reader = PTPReader(data: data)
    guard reader.remaining >= 16,
      let length = try? reader.u32(),
      let type = try? reader.u16(),
      let eventCode = try? reader.u16(),
      (try? reader.u32()) != nil,
      let handle = try? reader.u32(),
      length >= 16, Int(length) <= data.count, type == 4
    else { return nil }
    guard [UInt16(0x4002), 0xC181, 0xC186, 0xC1A9].contains(eventCode), handle != 0 else {
      return nil
    }
    return handle
  }

  static func command(_ code: UInt16, transaction: UInt32, parameters: [UInt32] = []) throws -> Data
  {
    guard parameters.count <= 5 else { throw CameraError.invalidData("PTP 参数超过 5 个") }
    var data = Data()
    data.appendLE(UInt32(12 + 4 * parameters.count))
    data.appendLE(UInt16(1))
    data.appendLE(code)
    data.appendLE(transaction)
    parameters.forEach { data.appendLE($0) }
    return data
  }

  static func response(_ bytes: Data, data: Data = Data()) throws -> PTPResponse {
    var reader = PTPReader(data: bytes)
    let length = try reader.u32()
    guard length == bytes.count, length >= 12, length <= 32, (length - 12) % 4 == 0,
      try reader.u16() == 3
    else {
      throw CameraError.invalidData("无效的 PTP 响应容器")
    }
    let code = try reader.u16()
    let transaction = try reader.u32()
    var parameters = [UInt32]()
    while reader.remaining > 0 { parameters.append(try reader.u32()) }
    return PTPResponse(code: code, transaction: transaction, parameters: parameters, data: data)
  }

  static func eosProperty(_ code: UInt32, value: UInt32) -> Data {
    var data = Data()
    [UInt32(12), code, value].forEach { data.appendLE($0) }
    return data
  }

  /// Canon EVF data consists of length/type records. Never scan arbitrary binary
  /// data for a thumbnail: only image records (1/11) or a bare JPEG are accepted.
  static func liveViewJPEG(_ data: Data) throws -> Data {
    if isJPEG(data) { return data }
    var reader = PTPReader(data: data)
    while reader.remaining >= 8 {
      let length = Int(try reader.u32())
      let type = try reader.u32()
      guard length >= 8, length - 8 <= reader.remaining else {
        throw CameraError.invalidData("取景记录长度无效")
      }
      let payload = try reader.bytes(length - 8)
      if type == 1 || type == 11, isJPEG(payload) { return payload }
    }
    throw CameraError.invalidData("取景响应中没有完整 JPEG")
  }

  static func isJPEG(_ data: Data) -> Bool {
    data.count >= 4 && data.prefix(2) == Data([0xff, 0xd8]) && data.suffix(2) == Data([0xff, 0xd9])
  }
}

struct PTPReader {
  let data: Data
  private var offset = 0
  init(data: Data) { self.data = data }
  var remaining: Int { data.count - offset }

  mutating func bytes(_ count: Int) throws -> Data {
    guard count >= 0, count <= remaining else { throw CameraError.invalidData("PTP 数据被截断") }
    defer { offset += count }
    return Data(data.dropFirst(offset).prefix(count))
  }
  mutating func u16() throws -> UInt16 {
    let value = try bytes(2)
    return UInt16(value[0]) | UInt16(value[1]) << 8
  }
  mutating func u32() throws -> UInt32 {
    let value = try bytes(4)
    return value.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
  }
  mutating func array16() throws -> [UInt16] {
    let count = Int(try u32())
    guard count <= remaining / 2 else { throw CameraError.invalidData("PTP 数组长度无效") }
    return try (0..<count).map { _ in try u16() }
  }
  mutating func string() throws -> String {
    let count = Int(try bytes(1)[0])
    if count == 0 { return "" }
    let value = try bytes(count * 2)
    guard value.suffix(2) == Data([0, 0]),
      let result = String(data: value.dropLast(2), encoding: .utf16LittleEndian)
    else {
      throw CameraError.invalidData("PTP 字符串无效")
    }
    return result
  }
}

extension Data {
  mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
