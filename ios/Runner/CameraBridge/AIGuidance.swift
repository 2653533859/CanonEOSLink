import CoreFoundation
import Foundation

struct AIConfiguration {
  let endpoint: URL
  let model: String
  let apiKey: String

  init(endpoint: String, model: String, apiKey: String) throws {
    guard let parts = URLComponents(string: endpoint), parts.scheme?.lowercased() == "https",
      parts.host != nil, parts.user == nil, parts.password == nil, parts.fragment == nil,
      parts.query == nil, parts.path.hasSuffix("/chat/completions"), let url = parts.url,
      !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      model.count <= 200, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !apiKey.contains("\n"), !apiKey.contains("\r")
    else {
      throw CameraError.invalidData("请填写 HTTPS 的 /chat/completions 地址、模型和 API Key")
    }
    self.endpoint = url
    self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    self.apiKey = apiKey
  }
}

struct GuidanceSuggestion {
  let property: ExposureProperty
  let value: Double
  let reason: String
  let option: ExposureOption?
  let revision: Int

  var dictionary: [String: Any] {
    [
      "property": property.rawValue, "title": property.title, "value": value,
      "reason": reason, "label": option?.label ?? String(value),
      "raw": option.map { Int($0.raw) as Any } ?? NSNull(), "revision": revision,
      "applicable": option != nil,
    ]
  }
}

struct GuidanceResult {
  let summary: String
  let composition: [String]
  let suggestions: [GuidanceSuggestion]
  let confidence: Double
  let poseRecommendations: [[String: String]]
  var dictionary: [String: Any] {
    [
      "summary": summary, "composition": composition,
      "suggestions": suggestions.map(\.dictionary), "confidence": confidence,
      "poseRecommendations": poseRecommendations,
    ]
  }

  static func parse(_ content: String, exposure: ExposureSettings, poseIDs: Set<String> = []) throws -> GuidanceResult {
    guard content.utf8.count <= 65_536, let bytes = content.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      let summary = object["summary"] as? String,
      !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let notes = object["composition"] as? [String], notes.count <= 8,
      let confidenceNumber = object["confidence"] as? NSNumber,
      CFGetTypeID(confidenceNumber) != CFBooleanGetTypeID(),
      confidenceNumber.doubleValue.isFinite, (0...1).contains(confidenceNumber.doubleValue),
      let rawSuggestions = object["recommendations"] as? [[String: Any]], rawSuggestions.count <= 4
    else {
      throw CameraError.invalidData("AI 响应格式无效")
    }
    let confidence = confidenceNumber.doubleValue
    var seen: Set<ExposureProperty> = []
    var suggestions: [GuidanceSuggestion] = []
    for item in rawSuggestions {
      guard let name = item["property"] as? String, let property = ExposureProperty(rawValue: name),
        seen.insert(property).inserted, let number = item["value"] as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
        let reason = item["reason"] as? String
      else {
        throw CameraError.invalidData("AI 参数建议格式无效")
      }
      let value = number.doubleValue
      // Shutter advice is applicable when flash is confirmed off or within sync speed.
      let option =
        (property != .shutter || exposure.allowsShutterRecommendation(seconds: value))
          && exposure.verified && exposure.values[property.code] != nil
          && exposure.allowsMode(property) && confidence >= 0.65
        ? exposure.options(property).first(where: { candidate in
          guard let allowed = candidate.value else { return false }
          return abs(allowed - value) <= max(1e-8, abs(allowed) * 1e-5)
        }) : nil
      suggestions.append(
        GuidanceSuggestion(
          property: property, value: value,
          reason: String(reason.prefix(300)), option: option, revision: exposure.revision))
    }
    var seenPoses: Set<String> = []
    let poses = ((object["pose_recommendations"] as? [[String: Any]]) ?? []).prefix(20).compactMap { item -> [String: String]? in
      guard let id = item["id"] as? String, poseIDs.contains(id), seenPoses.insert(id).inserted,
        let reason = item["reason"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      return ["id": id, "reason": String(reason.prefix(200))]
    }
    return GuidanceResult(
      summary: String(summary.prefix(1000)),
      composition: notes.map { String($0.prefix(300)) }, suggestions: suggestions,
      confidence: confidence, poseRecommendations: Array(poses.prefix(3)))
  }
}

struct PhotoGuidanceResult {
  let summary: String
  let composition: [String]
  let confidence: Double
  let recipe: PhotoRecipe?
  var dictionary: [String: Any] {
    [
      "summary": summary, "composition": composition, "confidence": confidence,
      "recipe": recipe.map { $0.dictionary as Any } ?? NSNull(),
      "applicable": recipe != nil && confidence >= 0.65,
    ]
  }
  static func parse(_ content: String, currentRecipe: PhotoRecipe) throws -> PhotoGuidanceResult {
    guard content.utf8.count <= 65_536, let bytes = content.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      let summary = object["summary"] as? String,
      !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let notes = object["composition"] as? [String], notes.count <= 8,
      let confidence = object["confidence"] as? NSNumber,
      CFGetTypeID(confidence) != CFBooleanGetTypeID(), confidence.doubleValue.isFinite,
      (0...1).contains(confidence.doubleValue), object.keys.contains("recipe")
    else {
      throw CameraError.invalidData("AI 照片分析格式无效")
    }
    var recipe: PhotoRecipe?
    if !(object["recipe"] is NSNull) {
      guard var values = object["recipe"] as? [String: Any],
        ["exposure", "contrast", "saturation", "warmth"].allSatisfy({ values[$0] != nil })
      else {
        throw CameraError.invalidData("AI 调色参数不完整")
      }
      // The model suggests only four fields; retain unmentioned adjustments even if it
      // unexpectedly returns extra keys that the confirmation dialog does not show.
      values["highlights"] = currentRecipe.highlights
      values["shadows"] = currentRecipe.shadows
      recipe = try PhotoRecipe(dictionary: values)
    }
    return PhotoGuidanceResult(
      summary: String(summary.prefix(1000)),
      composition: notes.map { String($0.prefix(300)) }, confidence: confidence.doubleValue,
      recipe: recipe)
  }
}

/// Never follow a redirect carrying a provider credential or camera image.
final class AINoRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

final class AIGuidanceService {
  private let session: URLSession
  private let redirectDelegate: AINoRedirectDelegate?

  init(session: URLSession? = nil) {
    if let session {
      self.session = session
      redirectDelegate = nil
    } else {
      let delegate = AINoRedirectDelegate()
      redirectDelegate = delegate
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 30
      configuration.timeoutIntervalForResource = 45
      configuration.urlCache = nil
      self.session = URLSession(
        configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
  }

  func analyze(
    jpeg: Data, exposure: ExposureSettings, goal: String,
    configuration: AIConfiguration, poses: [[String: String]] = []
  ) async throws -> GuidanceResult {
    guard PTPCodec.isJPEG(jpeg), jpeg.count <= 5_000_000 else {
      throw CameraError.invalidData("当前取景帧无效或过大")
    }
    let fields: [[String: Any]] = ExposureProperty.allCases.map { property in
      [
        "property": property.rawValue,
        "current": exposure.values[property.code].flatMap {
          ExposureCatalog.option(property, raw: $0)
        }?.label ?? "unknown",
        "writable": exposure.verified && exposure.allowsMode(property),
        "allowed": exposure.options(property).compactMap(\.value),
      ]
    }
    let context: [String: Any] = [
      "goal": String(goal.prefix(300)), "mode": exposure.modeLabel,
      "settings_verified": exposure.verified, "settings": fields, "poses": poses,
    ]
    let contextData = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
    let contextText = String(decoding: contextData, as: UTF8.self)
    let system =
      "你是摄影助手。观察图片并给出简短摄影与构图建议。只返回 JSON：{\"summary\":\"...\",\"composition\":[\"...\"],\"confidence\":0.0,\"recommendations\":[{\"property\":\"aperture|shutter|iso|compensation\",\"value\":数字,\"reason\":\"...\"}],\"pose_recommendations\":[{\"id\":\"姿势ID\",\"reason\":\"推荐原因\"}]}。姿势只能选输入 poses 中的 ID，最多三项；注意人数与画面和目标一致，看不清或没有合适选择时留空，不要假装知道画面外的条件。快门使用秒，光圈使用 f 值。只能选择输入中对应 allowed 的精确数字；不确定时 recommendations 留空。绝不能声称已修改相机。"
    let content = try await request(
      jpeg: jpeg, context: contextText, system: system, configuration: configuration)
    return try GuidanceResult.parse(content, exposure: exposure, poseIDs: Set(poses.compactMap { $0["id"] }))
  }

  func analyzePhoto(
    jpeg: Data, recipe: PhotoRecipe, goal: String,
    configuration: AIConfiguration
  ) async throws -> PhotoGuidanceResult {
    let context: [String: Any] = [
      "goal": String(goal.prefix(300)), "current_recipe": recipe.dictionary,
    ]
    let contextData = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
    let system =
      "你是摄影修图助手。图片是按 current_recipe 调整后的预览。只返回 JSON：{\"summary\":\"...\",\"composition\":[\"...\"],\"confidence\":0.0,\"recipe\":{\"exposure\":0.0,\"contrast\":1.0,\"saturation\":1.0,\"warmth\":0.0}}。recipe 为相对原片的绝对参数而非增量；exposure 范围 -2 到 2 EV，contrast 0.5 到 1.5，saturation 0 到 2，warmth -1 到 1，正值偏暖。不确定时 recipe 为 null。不要声称已经修改或导出照片。"
    let content = try await request(
      jpeg: jpeg, context: String(decoding: contextData, as: UTF8.self),
      system: system, configuration: configuration)
    return try PhotoGuidanceResult.parse(content, currentRecipe: recipe)
  }

  private func request(
    jpeg: Data, context: String, system: String,
    configuration: AIConfiguration
  ) async throws -> String {
    guard PTPCodec.isJPEG(jpeg), jpeg.count <= 5_000_000 else {
      throw CameraError.invalidData("预览图无效或过大")
    }
    let payload: [String: Any] = [
      "model": configuration.model,
      "response_format": ["type": "json_object"],
      "messages": [
        ["role": "system", "content": system],
        [
          "role": "user",
          "content": [
            ["type": "text", "text": context],
            [
              "type": "image_url",
              "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
            ],
          ],
        ],
      ],
    ]
    var request = URLRequest(url: configuration.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CameraError.unavailable("模型服务没有返回 HTTP 响应")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw CameraError.unavailable("模型服务请求失败（HTTP \(http.statusCode)）")
    }
    var data = Data()
    for try await byte in bytes {
      guard data.count < 1_000_000 else { throw CameraError.invalidData("模型服务响应过大") }
      data.append(byte)
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = root["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String
    else {
      throw CameraError.invalidData("模型服务响应格式无效")
    }
    return content
  }
}
