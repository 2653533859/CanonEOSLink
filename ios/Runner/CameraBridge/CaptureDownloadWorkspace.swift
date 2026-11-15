import Foundation

/// Each transfer owns a directory so late callbacks cannot remove another transfer.
struct CaptureDownloadWorkspace {
  let root: URL

  func create() throws -> URL {
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  static func remove(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
  }
}
