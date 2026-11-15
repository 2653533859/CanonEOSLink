import Foundation
import Security

final class AIConfigurationStore {
  private let defaults: UserDefaults
  private let service = "com.parado.canoneos.ai"
  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func snapshot() -> [String: Any] {
    let endpoint = defaults.string(forKey: "ai.endpoint") ?? ""
    return [
      "endpoint": endpoint, "model": defaults.string(forKey: "ai.model") ?? "",
      "hasKey": (try? readKey(endpoint: endpoint)) != nil,
    ]
  }

  func configuration() throws -> AIConfiguration {
    let endpoint = defaults.string(forKey: "ai.endpoint") ?? ""
    guard let key = try readKey(endpoint: endpoint) else {
      throw CameraError.unavailable("请先在 AI 设置中填写服务地址、模型和 API Key")
    }
    return try AIConfiguration(
      endpoint: endpoint, model: defaults.string(forKey: "ai.model") ?? "", apiKey: key)
  }

  func save(endpoint: String, model: String, key: String) throws {
    let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    let oldEndpoint = defaults.string(forKey: "ai.endpoint") ?? ""
    let existing = try readKey(endpoint: endpoint)
    let actualKey = key.isEmpty ? existing ?? "" : key
    _ = try AIConfiguration(endpoint: endpoint, model: model, apiKey: actualKey)
    if !key.isEmpty {
      let query = item(endpoint)
      let data = Data(key.utf8)
      let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
      if status == errSecItemNotFound {
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
          throw CameraError.unavailable("无法将 API Key 保存到钥匙串")
        }
      } else if status != errSecSuccess {
        throw CameraError.unavailable("无法更新钥匙串中的 API Key")
      }
    }
    if oldEndpoint != endpoint && !oldEndpoint.isEmpty {
      let status = SecItemDelete(item(oldEndpoint) as CFDictionary)
      if status != errSecSuccess && status != errSecItemNotFound {
        if existing == nil && !key.isEmpty { SecItemDelete(item(endpoint) as CFDictionary) }
        throw CameraError.unavailable("无法清除旧地址的 API Key；原配置仍保留")
      }
    }
    defaults.set(endpoint, forKey: "ai.endpoint")
    defaults.set(model.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "ai.model")
  }

  func clear() throws {
    let endpoint = defaults.string(forKey: "ai.endpoint") ?? ""
    if !endpoint.isEmpty {
      let status = SecItemDelete(item(endpoint) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw CameraError.unavailable("无法清除钥匙串中的 API Key")
      }
    }
    defaults.removeObject(forKey: "ai.endpoint")
    defaults.removeObject(forKey: "ai.model")
  }

  private func item(_ endpoint: String) -> [CFString: Any] {
    [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: endpoint]
  }
  private func readKey(endpoint: String) throws -> String? {
    guard !endpoint.isEmpty else { return nil }
    var query = item(endpoint)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
      let key = String(data: data, encoding: .utf8)
    else {
      throw CameraError.unavailable("无法读取钥匙串中的 API Key（状态 \(status)）")
    }
    return key
  }
}
