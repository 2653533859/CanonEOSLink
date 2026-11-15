import Foundation

enum ExposureProperty: String, CaseIterable, Codable {
  case aperture, shutter, iso, compensation

  var code: UInt32 {
    switch self {
    case .aperture: return 0xD101
    case .shutter: return 0xD102
    case .iso: return 0xD103
    case .compensation: return 0xD104
    }
  }
  var title: String {
    switch self {
    case .aperture: return "光圈"
    case .shutter: return "快门"
    case .iso: return "ISO"
    case .compensation: return "曝光补偿"
    }
  }
  static func from(code: UInt32) -> Self? { allCases.first { $0.code == code } }
}

struct ExposureOption: Equatable {
  let raw: UInt32
  let label: String
  let value: Double?
  var dictionary: [String: Any] {
    ["raw": Int(raw), "label": label, "value": value.map { $0 as Any } ?? NSNull()]
  }
}

struct EOSPropertyEvent {
  let property: UInt32
  let value: UInt32?
  let available: [UInt32]?
}

enum EOSPropertyCodec {
  static let mode: UInt32 = 0xD105
  static let flash: UInt32 = 0xD120
  static let properties: Set<UInt32> = [
    0xD101, 0xD102, 0xD103, 0xD104, mode, flash, 0xD1B0, 0xD1B1,
  ]

  static func parse(_ data: Data) throws -> [EOSPropertyEvent] {
    var reader = PTPReader(data: data)
    var events: [EOSPropertyEvent] = []
    while reader.remaining > 0 {
      let length = Int(try reader.u32())
      let kind = try reader.u32()
      guard length >= 8, length - 8 <= reader.remaining else {
        throw CameraError.invalidData("EOS 属性事件长度无效")
      }
      var payload = PTPReader(data: try reader.bytes(length - 8))
      guard kind == 0xC189 || kind == 0xC18A else { continue }
      let code = try payload.u32()
      guard properties.contains(code) else { continue }
      if kind == 0xC189 {
        let value: UInt32
        if code == 0xD1B0 {
          value = try payload.u32()
        } else if code == 0xD104 {
          value = UInt32(try payload.bytes(1)[0])
        } else {
          value = UInt32(try payload.u16())
        }
        events.append(EOSPropertyEvent(property: code, value: value, available: nil))
      } else {
        let format = try payload.u32()
        let count = Int(try payload.u32())
        guard count <= 1024, count <= payload.remaining / 4 else {
          throw CameraError.invalidData("EOS 可用档位数组长度无效")
        }
        // EOS list format 3 uses four-byte slots regardless of property type.
        // Unknown forms invalidate the old list instead of keeping stale choices.
        let values = try (0..<count).map { _ -> UInt32 in
          let value = try payload.u32()
          return code == 0xD104 ? value & 0xff : value & 0xffff
        }
        events.append(
          EOSPropertyEvent(property: code, value: nil, available: format == 3 ? values : []))
      }
    }
    return events
  }
}

struct ExposureSettings {
  private(set) var values: [UInt32: UInt32] = [:]
  private(set) var available: [UInt32: [UInt32]] = [:]
  private(set) var revision = 0
  var verified = false
  var mode: UInt32? { values[EOSPropertyCodec.mode] }
  var flashEnabled: Bool? { values[EOSPropertyCodec.flash].map { $0 != 0 } }
  var modeLabel: String {
    guard let mode else { return "未读取" }
    return [
      UInt32(0): "P", 1: "Tv", 2: "Av", 3: "M", 4: "Bulb",
      0x07: "C1", 0x09: "A+", 0x10: "C2", 0x16: "SCN", 0x37: "Fv",
    ][mode] ?? "其他模式"
  }

  mutating func ingest(_ events: [EOSPropertyEvent]) {
    for event in events {
      if let value = event.value {
        if event.property == EOSPropertyCodec.mode, let previous = mode, previous != value {
          available.removeAll()
          verified = false
        }
        if values[event.property] != value { revision += 1 }
        values[event.property] = value
      }
      if let list = event.available {
        if available[event.property] != list { revision += 1 }
        available[event.property] = list
      }
    }
  }

  mutating func discardUnconfirmed(_ confirmed: Set<UInt32>) {
    for property in ExposureProperty.allCases where !confirmed.contains(property.code) {
      if values.removeValue(forKey: property.code) != nil { revision += 1 }
    }
    if !confirmed.contains(EOSPropertyCodec.flash) {
      if values.removeValue(forKey: EOSPropertyCodec.flash) != nil { revision += 1 }
    }
    verified =
      confirmed.contains(EOSPropertyCodec.mode)
      && ExposureProperty.allCases.contains { confirmed.contains($0.code) }
  }

  func allowsShutterRecommendation(seconds: Double) -> Bool {
    guard let flashEnabled else { return false }
    if !flashEnabled { return true }
    return seconds.isFinite && seconds >= 1.0 / 250.0 - 1e-6
  }

  func allowsMode(_ property: ExposureProperty) -> Bool {
    guard let mode else { return false }
    switch property {
    case .aperture: return mode == 2 || mode == 3 || mode == 0x37
    case .shutter: return mode == 1 || mode == 3 || mode == 0x37
    case .iso: return [UInt32(0), 1, 2, 3, 0x37].contains(mode)
    // M + Auto ISO compensation is model-dependent; leave it read-only.
    case .compensation: return [UInt32(0), 1, 2, 0x37].contains(mode)
    }
  }

  func options(_ property: ExposureProperty) -> [ExposureOption] {
    (available[property.code] ?? []).compactMap { ExposureCatalog.option(property, raw: $0) }
  }

  func validate(_ patch: [ExposureProperty: UInt32], expectedRevision: Int) throws {
    guard verified, revision == expectedRevision, !patch.isEmpty else {
      throw CameraError.unavailable("相机参数已变化或尚未确认，请刷新后重新选择")
    }
    for (property, value) in patch {
      guard allowsMode(property), values[property.code] != nil,
        options(property).contains(where: { $0.raw == value })
      else {
        throw CameraError.unavailable("当前相机模式或镜头不支持该\(property.title)档位")
      }
    }
  }

  var dictionary: [String: Any] {
    [
      "revision": revision, "verified": verified, "mode": modeLabel,
      "flash": flashEnabled.map { ($0 ? "开启" : "关闭") as Any } ?? NSNull(),
      "fields": ExposureProperty.allCases.map { property -> [String: Any] in
        let raw = values[property.code]
        let option = raw.flatMap { ExposureCatalog.option(property, raw: $0) }
        return [
          "id": property.rawValue, "title": property.title,
          "raw": raw.map { Int($0) as Any } ?? NSNull(),
          "label": option?.label ?? raw.map { String(format: "未知 0x%04X", $0) } ?? "—",
          "value": option?.value.map { $0 as Any } ?? NSNull(),
          "writable": verified && raw != nil && allowsMode(property) && !options(property).isEmpty,
          "options": options(property).map(\.dictionary),
        ]
      },
    ]
  }
}

enum ExposureCatalog {
  // Protocol codes are not physical numbers. Unknown codes remain read-only.
  // This intentionally conservative subset can be extended from verified tables.
  static let aperture: [UInt32: Double] = [
    0x08: 1, 0x0B: 1.1, 0x0C: 1.2, 0x0D: 1.2, 0x10: 1.4, 0x13: 1.6,
    0x14: 1.8, 0x15: 1.8, 0x18: 2, 0x1B: 2.2, 0x1C: 2.5, 0x1D: 2.5,
    0x20: 2.8, 0x23: 3.2, 0x24: 3.5, 0x25: 3.5, 0x28: 4, 0x2B: 4.5,
    0x2C: 4.5, 0x2D: 5, 0x30: 5.6, 0x33: 6.3, 0x34: 6.7, 0x35: 7.1,
    0x38: 8, 0x3B: 9, 0x3C: 9.5, 0x3D: 10, 0x40: 11, 0x43: 13,
    0x44: 13, 0x45: 14, 0x48: 16, 0x4B: 18, 0x4C: 19, 0x4D: 20,
    0x50: 22, 0x53: 25, 0x54: 27, 0x55: 29, 0x58: 32,
    0x5B: 36, 0x5C: 38, 0x5D: 40, 0x60: 45, 0x63: 51,
    0x64: 54, 0x65: 57, 0x68: 64,
  ]
  static let shutterDenominator: [UInt32: Double] = [
    0x40: 2, 0x43: 2.5, 0x44: 3, 0x45: 3, 0x48: 4, 0x4B: 5,
    0x4C: 6, 0x4D: 6, 0x50: 8, 0x53: 10, 0x54: 10, 0x55: 13,
    0x58: 15, 0x5B: 20, 0x5C: 20, 0x5D: 25, 0x60: 30, 0x63: 40,
    0x64: 45, 0x65: 50, 0x68: 60, 0x6B: 80, 0x6C: 90, 0x6D: 100,
    0x70: 125, 0x73: 160, 0x74: 180, 0x75: 200, 0x78: 250, 0x7B: 320,
    0x7C: 350, 0x7D: 400, 0x80: 500, 0x83: 640, 0x84: 750, 0x85: 800,
    0x88: 1000, 0x8B: 1250, 0x8C: 1500, 0x8D: 1600, 0x90: 2000,
    0x93: 2500, 0x94: 3000, 0x95: 3200, 0x98: 4000, 0x9B: 5000,
    0x9C: 6000, 0x9D: 6400, 0xA0: 8000, 0xA3: 10000, 0xA4: 12000,
    0xA5: 12800, 0xA8: 16000,
  ]
  static let slowShutter: [UInt32: Double] = [
    0x10: 30, 0x13: 25, 0x14: 20, 0x15: 20, 0x18: 15, 0x1B: 13,
    0x1C: 10, 0x1D: 10, 0x20: 8, 0x23: 6, 0x24: 6, 0x25: 5,
    0x28: 4, 0x2B: 3.2, 0x2C: 3, 0x2D: 2.5, 0x30: 2, 0x33: 1.6,
    0x34: 1.5, 0x35: 1.3, 0x38: 1, 0x3B: 0.8, 0x3C: 0.7, 0x3D: 0.6,
    0x3E: 0.5, 0x3F: 0.4,
  ]
  static func option(_ property: ExposureProperty, raw: UInt32) -> ExposureOption? {
    switch property {
    case .aperture:
      guard let value = aperture[raw] else { return nil }
      return ExposureOption(raw: raw, label: "f/\(number(value))", value: value)
    case .shutter:
      if let denominator = shutterDenominator[raw] {
        return ExposureOption(raw: raw, label: "1/\(number(denominator))", value: 1 / denominator)
      }
      guard let seconds = slowShutter[raw] else { return nil }
      return ExposureOption(raw: raw, label: "\(number(seconds))s", value: seconds)
    case .iso:
      if raw == 0 || raw == 1 { return ExposureOption(raw: raw, label: "Auto", value: nil) }
      let values: [UInt32: Int] = [
        0x40: 50, 0x48: 100, 0x4B: 125, 0x4D: 160, 0x50: 200, 0x53: 250,
        0x55: 320, 0x58: 400, 0x5B: 500, 0x5D: 640, 0x60: 800, 0x63: 1000,
        0x65: 1250, 0x68: 1600, 0x6B: 2000, 0x6D: 2500, 0x70: 3200,
        0x73: 4000, 0x75: 5000, 0x78: 6400, 0x7B: 8000, 0x7D: 10000,
        0x80: 12800, 0x83: 16000, 0x85: 20000, 0x88: 25600, 0x8B: 32000,
        0x8D: 40000, 0x90: 51200,
      ]
      guard let value = values[raw] else { return nil }
      return ExposureOption(raw: raw, label: String(value), value: Double(value))
    case .compensation:
      guard raw <= 255 else { return nil }
      let signed = Int(Int8(bitPattern: UInt8(raw)))
      let magnitude = abs(signed)
      guard magnitude <= 40, let fraction = [0: 0.0, 3: 1.0 / 3, 4: 0.5, 5: 2.0 / 3][magnitude % 8]
      else { return nil }
      let value = (Double(magnitude / 8) + fraction) * (signed < 0 ? -1 : 1)
      return ExposureOption(raw: raw, label: String(format: "%+.2f EV", value), value: value)
    }
  }
  private static func number(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
  }
}
