import Foundation

struct CaptureCatalog {
  let directory: URL

  func list() throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
  }

  static func page(_ entries: [URL], before: String?, limit: Int = 30) -> (items: [URL], next: String?) {
    let eligible = entries.lazy.filter { before == nil || $0.lastPathComponent < before! }
    let selected = Array(eligible.prefix(limit + 1))
    let items = Array(selected.prefix(limit))
    return (items, selected.count > limit ? items.last?.lastPathComponent : nil)
  }
}

/// All recipes and exports live beside, never over, the downloaded originals.
struct PhotoEditStorage {
  let documents: URL
  private let fm = FileManager.default

  func sourceURL(_ path: String) throws -> URL {
    let root = documents.appendingPathComponent("Captures", isDirectory: true).standardizedFileURL
      .resolvingSymlinksInPath()
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard url.deletingLastPathComponent() == root,
      ["jpg", "jpeg"].contains(url.pathExtension.lowercased()),
      fm.fileExists(atPath: url.path)
    else { throw CameraError.unavailable("只能编辑本应用已下载的 JPEG") }
    let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0, size <= PhotoEditCore.maximumFileSize else {
      throw CameraError.invalidData("照片文件为空或过大")
    }
    return url
  }

  func exportedURL(_ path: String) throws -> URL {
    let root = documents.appendingPathComponent("Exports", isDirectory: true).standardizedFileURL
      .resolvingSymlinksInPath()
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard url.deletingLastPathComponent() == root,
      ["jpg", "jpeg"].contains(url.pathExtension.lowercased()),
      fm.fileExists(atPath: url.path)
    else { throw CameraError.unavailable("只能保存本应用已导出的 JPEG") }
    return url
  }

  private func recipeURL(for source: URL) -> URL {
    documents.appendingPathComponent("EditRecipes", isDirectory: true).appendingPathComponent(
      source.lastPathComponent + ".json")
  }

  func loadRecipe(source: URL) throws -> PhotoRecipe {
    let url = recipeURL(for: source)
    guard fm.fileExists(atPath: url.path) else { return try PhotoRecipe() }
    let bytes = try Data(contentsOf: url)
    guard bytes.count <= 4096,
      let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    else {
      throw CameraError.invalidData("保存的调整记录无效")
    }
    return try PhotoRecipe(dictionary: json)
  }

  func saveRecipe(source: URL, recipe: PhotoRecipe) throws {
    let url = recipeURL(for: source)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: recipe.dictionary, options: [.sortedKeys]).write(
      to: url, options: .atomic)
  }

  func export(_ data: Data) throws -> URL {
    let directory = documents.appendingPathComponent("Exports", isDirectory: true)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(
      "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).jpg")
    let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
    defer { try? fm.removeItem(at: temporary) }
    try data.write(to: temporary, options: .atomic)
    try fm.moveItem(at: temporary, to: url)
    return url
  }
}
