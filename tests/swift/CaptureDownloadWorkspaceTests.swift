import Foundation
import XCTest

@testable import CanonPTPCore

final class CaptureDownloadWorkspaceTests: XCTestCase {
  func testCleanupIsIsolatedAndDoesNotRemoveSavedCapture() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = CaptureDownloadWorkspace(root: root.appendingPathComponent("IncomingDownloads"))
    let first = try workspace.create()
    let second = try workspace.create()
    let file = first.appendingPathComponent("first.jpg")
    let other = second.appendingPathComponent("second.jpg")
    try Data([1]).write(to: file)
    try Data([2]).write(to: other)
    let saved = root.appendingPathComponent("saved.jpg")
    try FileManager.default.moveItem(at: file, to: saved)
    CaptureDownloadWorkspace.remove(first)
    CaptureDownloadWorkspace.remove(first) // cancellation and a late callback may both clean up
    XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    CaptureDownloadWorkspace.remove(second)
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
  }
}
