import Foundation
import ImageCaptureCore

/// Single in-flight PTP request. A timeout poisons this transport: sending the
/// next command while ImageCaptureCore still owns the old one would be unsafe.
@MainActor
final class ImageCaptureTransport: PTPTransport {
  private struct Request {
    let id: UInt32
    let operation: UInt16
    let command: Data
    let data: Data?
    let continuation: CheckedContinuation<PTPResponse, Error>
  }
  private let camera: ICCameraDevice
  private var sequence: UInt32 = 0
  private var pending: [Request] = []
  private var active: Request?
  private var timeout: Task<Void, Never>?
  private var invalid = false
  var log: ((String) -> Void)?
  var onFatalError: ((Error) -> Void)?

  init(camera: ICCameraDevice) { self.camera = camera }

  func send(_ operation: UInt16, parameters: [UInt32] = [], data: Data? = nil) async throws
    -> PTPResponse
  {
    guard !invalid else { throw CameraError.disconnected }
    try Task.checkCancellation()
    sequence &+= 1
    let id = sequence
    let command = try PTPCodec.command(operation, transaction: id, parameters: parameters)
    return try await withCheckedThrowingContinuation { continuation in
      pending.append(
        Request(
          id: id, operation: operation, command: command, data: data, continuation: continuation))
      pump()
    }
  }

  func invalidate(_ error: Error = CameraError.disconnected) {
    invalid = true
    timeout?.cancel()
    timeout = nil
    let requests = (active.map { [$0] } ?? []) + pending
    active = nil
    pending.removeAll()
    requests.forEach { $0.continuation.resume(throwing: error) }
  }

  private func pump() {
    guard !invalid, active == nil, !pending.isEmpty else { return }
    let request = pending.removeFirst()
    active = request
    timeout = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
      guard let self, self.active?.id == request.id else { return }
      self.invalidate(CameraError.timeout)
      self.onFatalError?(CameraError.timeout)
    }
    camera.requestSendPTPCommand(request.command, outData: request.data) {
      [weak self] data, response, error in
      Task { @MainActor in self?.finish(request.id, data: data, response: response, error: error) }
    }
  }

  private func finish(_ id: UInt32, data: Data, response: Data, error: Error?) {
    guard let request = active, request.id == id, !invalid else { return }
    timeout?.cancel()
    timeout = nil
    active = nil
    do {
      if let error { throw error }
      let result = try PTPCodec.response(response, data: data)
      // ImageCaptureCore owns the underlying PTP session and may rewrite
      // transaction IDs. Match callbacks by request, log the device ID.
      if request.operation != 0x9153 || result.code != 0x2001 {
        log?(
          String(
            format: "PTP 0x%04X → 0x%04X · %d bytes · tx %u", request.operation, result.code,
            data.count, result.transaction))
      }
      request.continuation.resume(returning: result)
    } catch {
      log?(error.localizedDescription)
      request.continuation.resume(throwing: error)
    }
    pump()
  }
}
