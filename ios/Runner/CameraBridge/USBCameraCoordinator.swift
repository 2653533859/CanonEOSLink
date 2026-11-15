import Flutter
import Foundation
@preconcurrency import ImageCaptureCore
import UIKit

@MainActor
final class USBCameraCoordinator: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
  var emit: (([String: Any]) -> Void)?
  private let browser = ICDeviceBrowser()
  private let registry: FlutterTextureRegistry
  private let texture = JPEGTexture()
  private(set) var textureID: Int64 = -1
  private var devices: [String: ICCameraDevice] = [:]
  private var camera: ICCameraDevice?
  private var transport: ImageCaptureTransport?
  private var eos: CanonEOS?
  private var state = "disconnected"
  private var busy = false
  private var message = "连接相机后，点击搜索 USB"
  private var model = "Canon EOS R10"
  private var catalogReady = false
  private var sessionGeneration = 0
  private var sessionWaiter: CheckedContinuation<Void, Error>?
  private var sessionTimeout: Task<Void, Never>?
  private var liveTask: Task<Void, Never>?
  private var downloadTask: Task<Void, Never>?
  private var downloadProgress: Progress?
  private var downloadDirectory: URL?
  private var downloadQueue: [ICCameraFile] = []
  private var queuedHandles: Set<UInt32> = []
  private var knownHandles: Set<UInt32> = []
  private var importedHandles: Set<UInt32> = []
  private var pendingEventHandles: Set<UInt32> = []
  private var downloadWaiter: CheckedContinuation<String, Error>?
  private var downloadTimeout: Task<Void, Never>?
  private var captureTimeout: Task<Void, Never>?
  private var receivedJPEGCount = 0
  private var openingDevices: Set<ObjectIdentifier> = []
  private var captures: [URL] = []
  private var logs: [String] = []
  private var frameSize = CGSize(width: 3, height: 2)
  private var fps = 0.0
  private var autoDownload = true
  private var backgroundObserver: NSObjectProtocol?
  private var suspending = false
  private let aiStore = AIConfigurationStore()
  private let aiService = AIGuidanceService()
  private var aiTask: Task<GuidanceResult, Error>?
  private var aiRequestID: UUID?
  private var guidance: GuidanceResult?
  private var latestJPEG: Data?
  private var latestFrameTime: Date?
  private let poseTracker = PoseTracker()

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
    poseTracker.onChange = { [weak self] in self?.publish() }
    browser.delegate = self
    browser.browsedDeviceTypeMask = ICDeviceTypeMask(
      rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
    textureID = registry.register(texture)
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    // Remove abandoned transfers, including files left by older versions.
    CaptureDownloadWorkspace.remove(caches.appendingPathComponent("Incoming", isDirectory: true))
    CaptureDownloadWorkspace.remove(caches.appendingPathComponent("IncomingDownloads", isDirectory: true))
    loadCaptures()
    backgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.log("应用进入后台，关闭相机会话；返回后请重新连接")
        self.poseTracker.setEnabled(false)
        await self.suspend()
      }
    }
  }

  func snapshot() -> [String: Any] {
    let rawNames = cameraRAWBasenames()
    return [
      "state": state, "busy": busy, "message": message, "model": model,
      "textureId": textureID, "width": frameSize.width, "height": frameSize.height,
      "fps": fps, "autoDownload": autoDownload, "catalogReady": catalogReady,
      "devices": devices.sorted(by: { $0.key < $1.key }).map { id, device in
        [
          "id": id, "name": device.name ?? "USB 相机", "vendorId": device.usbVendorID,
          "transport": device.transportType ?? "unknown",
        ] as [String: Any]
      },
      "files": cameraFiles().suffix(30).reversed().map { file in
        let name = file.name ?? "JPEG"
        let base = (name as NSString).deletingPathExtension.uppercased()
        return [
          "handle": Int(file.ptpObjectHandle), "name": name,
          "downloaded": importedHandles.contains(file.ptpObjectHandle),
          "hasRAW": rawNames.contains(base),
        ] as [String: Any]
      }, "rawCount": rawNames.count,
      "captureCount": captures.count, "logs": logs,
      "exposure": eos?.exposure.dictionary ?? [:], "canUndoExposure": eos?.canUndoExposure ?? false,
      "aiConfig": aiStore.snapshot(), "aiBusy": aiTask != nil,
      "guidance": guidance?.dictionary ?? [:],
      "poseTracking": poseTracker.dictionary,
      "histogram": texture.histogram,
      "highlightClipped": texture.highlightClipped,
    ]
  }

  func handle(_ method: String, arguments: [String: Any]) async throws -> Any? {
    if method == "getState" { return snapshot() }
    if method == "exportDiagnostics" { return logs.joined(separator: "\n") }
    if method == "listCaptures" {
      let before = arguments["before"] as? String
      if before == nil {
        captures = try CaptureCatalog(directory: capturesDirectory).list()
        publish()
      }
      let page = CaptureCatalog.page(captures, before: before)
      return [
        "items": page.items.map { ["path": $0.path, "name": $0.lastPathComponent] },
        "nextCursor": page.next as Any? ?? NSNull(),
      ] as [String: Any]
    }
    if method == "analyzeFrame" { return try await analyzeFrame(arguments) }
    guard !busy, !suspending else { throw CameraError.unavailable("相机正在处理上一项操作") }
    busy = true
    publish()
    let generation = sessionGeneration
    defer {
      // abort() owns state after disconnect, but busy must still clear.
      if generation == sessionGeneration {
        busy = false
        publish()
        scheduleDownloads()
      }
    }
    do {
      switch method {
      case "discover": try await discover()
      case "connect":
        guard let id = arguments["deviceId"] as? String else {
          throw CameraError.invalidData("缺少设备 ID")
        }
        try await connect(id)
      case "disconnect": try await disconnect()
      case "getDeviceInfo":
        let driver = try requireEOS()
        let wasLive = liveTask != nil
        await pauseFrames()
        guard generation == sessionGeneration else { throw CameraError.disconnected }
        defer {
          if wasLive && camera != nil && generation == sessionGeneration { startFrameLoop() }
        }
        let info = try await driver.readDeviceInfo()
        guard generation == sessionGeneration else { throw CameraError.disconnected }
        model = info.model
        log(
          "\(info.manufacturer) \(info.model) · 固件 \(info.version) · \(info.operations.count) 项 PTP 操作"
        )
      case "refreshExposure", "setExposure", "undoExposure":
        let driver = try requireEOS()
        let wasLive = liveTask != nil
        await pauseFrames()
        guard generation == sessionGeneration else { throw CameraError.disconnected }
        defer {
          if generation == sessionGeneration {
            recordPendingHandles(driver.drainPendingObjectHandles())
            if wasLive && camera != nil { startFrameLoop() }
          }
        }
        if method == "refreshExposure" {
          try await driver.refreshExposure()
          message = "已读取相机当前参数"
        } else {
          do {
            if method == "setExposure" {
              guard let name = arguments["property"] as? String,
                let property = ExposureProperty(rawValue: name),
                let value = arguments["value"] as? NSNumber,
                let revision = arguments["revision"] as? NSNumber,
                value.int64Value >= 0, value.int64Value <= Int64(UInt32.max)
              else {
                throw CameraError.invalidData("参数请求格式无效")
              }
              try await driver.setExposure(
                property, value: value.uint32Value, revision: revision.intValue)
              message = "参数写入已由相机确认"
            } else {
              try await driver.undoExposure()
              message = "参数已恢复"
            }
          } catch {
            if generation == sessionGeneration { try? await driver.refreshExposure() }
            throw error
          }
          guard generation == sessionGeneration else { throw CameraError.disconnected }
          try? await driver.refreshExposure()
          guidance = nil
        }
        guard generation == sessionGeneration else { throw CameraError.disconnected }
      case "saveAIConfig":
        guard aiTask == nil else { throw CameraError.unavailable("AI 分析进行中") }
        try aiStore.save(
          endpoint: arguments["endpoint"] as? String ?? "",
          model: arguments["model"] as? String ?? "", key: arguments["key"] as? String ?? "")
        guidance = nil
        message = "AI 服务配置已保存"
      case "clearAIConfig":
        guard aiTask == nil else { throw CameraError.unavailable("AI 分析进行中") }
        try aiStore.clear()
        guidance = nil
        message = "AI 服务配置已清除"
      case "startLiveView":
        guard state == "ready" else { throw CameraError.unavailable("请先连接相机并等待目录就绪") }
        let driver = try requireEOS()
        let parameter = (arguments["parameter"] as? NSNumber)?.uint32Value ?? 0x0020_0000
        guard [UInt32(0x0010_0000), 0x0020_0000].contains(parameter) else {
          throw CameraError.invalidData("不支持的取景参数")
        }
        driver.viewfinderParameter = parameter
        try await driver.startLiveView()
        guard generation == sessionGeneration else { throw CameraError.disconnected }
        recordPendingHandles(driver.drainPendingObjectHandles())
        state = "liveview_starting"
        message = "等待相机第一帧…"
        startFrameLoop()
      case "stopLiveView":
        let driver = try requireEOS()
        await pauseFrames()
        guard generation == sessionGeneration else { throw CameraError.disconnected }
        poseTracker.setEnabled(false)
        try await driver.stopLiveView()
        guard generation == sessionGeneration else { throw CameraError.disconnected }
        state = "ready"
        message = "取景已停止"
        texture.clear()
        fps = 0
      case "autofocus":
        guard catalogReady else { throw CameraError.unavailable("相机目录尚未就绪") }
        let driver = try requireEOS()
        let wasLive = liveTask != nil
        await pauseFrames()
        guard generation == sessionGeneration else { throw CameraError.disconnected }
        defer {
          if wasLive && camera != nil && generation == sessionGeneration { startFrameLoop() }
        }
        try await driver.autofocus()
        guard generation == sessionGeneration else { throw CameraError.disconnected }
        recordPendingHandles(driver.drainPendingObjectHandles())
        message = "已完成半按快门对焦"
        log(message)
      case "capture":
        guard catalogReady else { throw CameraError.unavailable("相机目录尚未就绪") }
        let driver = try requireEOS()
        let wasLive = liveTask != nil
        await pauseFrames()
        guard generation == sessionGeneration else { throw CameraError.disconnected }
        defer {
          if wasLive && camera != nil && generation == sessionGeneration { startFrameLoop() }
        }
        let jpegCountBeforeCapture = receivedJPEGCount
        try await driver.capture()
        guard generation == sessionGeneration else { throw CameraError.disconnected }
        recordPendingHandles(driver.drainPendingObjectHandles())
        message = "快门命令已接受，等待相机新增 JPEG"
        log(message)
        captureTimeout?.cancel()
        if receivedJPEGCount == jpegCountBeforeCapture {
          captureTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            self?.log("15 秒内未检测到新增 JPEG。检查相机是否实际曝光、是否保存 JPEG；可从相机文件列表手动下载。")
          }
        } else {
          message = "已检测到新增 JPEG"
        }
      case "setPoseTracking":
        guard let enabled = arguments["enabled"] as? Bool else {
          throw CameraError.invalidData("缺少姿态识别状态")
        }
        if enabled {
          guard state == "liveview_running", liveTask != nil else {
            throw CameraError.unavailable("请先开启实时取景")
          }
        }
        poseTracker.setEnabled(enabled)
      case "setAutoDownload": autoDownload = arguments["enabled"] as? Bool ?? true
      case "refreshFiles":
        if let driver = eos { recordPendingHandles(driver.drainPendingObjectHandles()) }
        reconcilePendingHandles()
        log("已刷新 ImageCaptureCore 目录快照，共 \(cameraFiles().count) 张 JPEG")
      case "download":
        guard let handle = (arguments["handle"] as? NSNumber)?.uint32Value,
          let file = cameraFiles().first(where: { $0.ptpObjectHandle == handle })
        else {
          throw CameraError.unavailable("照片已不在当前相机目录中")
        }
        enqueue(file)
      default: throw CameraError.unavailable("未知方法：\(method)")
      }
    } catch {
      log(error.localizedDescription)
      if generation == sessionGeneration {
        message = error.localizedDescription
        if camera == nil { state = "error" }
      }
      throw error
    }
    return snapshot()
  }

  private func requireEOS() throws -> CanonEOS {
    guard let eos, camera?.hasOpenSession == true, catalogReady else {
      throw CameraError.disconnected
    }
    return eos
  }

  private func analyzeFrame(_ arguments: [String: Any]) async throws -> [String: Any] {
    guard !busy, !suspending, aiTask == nil, state == "liveview_running",
      let jpeg = latestJPEG, let time = latestFrameTime, Date().timeIntervalSince(time) < 5,
      let driver = eos
    else { throw CameraError.unavailable("请先开启实时取景并等待最新画面") }
    let configuration = try aiStore.configuration()
    let current = driver.exposure
    let generation = sessionGeneration
    let id = UUID()
    let goal = arguments["goal"] as? String ?? "获得自然、清晰的照片"
    let rawPoses = arguments["poses"] as? [[String: String]] ?? []
    guard rawPoses.count <= 200, rawPoses.allSatisfy({ pose in
      ["id", "title", "scene", "framing", "style", "description", "people"].allSatisfy {
        guard let value = pose[$0] else { return false }
        return !value.isEmpty && value.count <= 200
      }
    }) else { throw CameraError.invalidData("姿势目录数据无效") }
    let poses = rawPoses.map { pose in
      pose.filter { ["id", "title", "scene", "framing", "style", "description", "people"].contains($0.key) }
    }
    let task = Task {
      try await aiService.analyze(
        jpeg: jpeg, exposure: current, goal: goal, configuration: configuration, poses: poses)
    }
    aiRequestID = id
    aiTask = task
    guidance = nil
    publish()
    defer {
      if aiRequestID == id {
        aiRequestID = nil
        aiTask = nil
        publish()
      }
    }
    do {
      let result = try await task.value
      guard generation == sessionGeneration, aiRequestID == id else {
        throw CameraError.disconnected
      }
      guidance = result
      log("AI 分析完成；参数建议须逐项确认")
      return snapshot()
    } catch {
      if generation == sessionGeneration { log("AI 分析失败：\(error.localizedDescription)") }
      throw error
    }
  }

  private func discover() async throws {
    #if targetEnvironment(simulator)
      throw CameraError.unavailable("iOS 模拟器不支持 USB 相机连接，请在 iPhone 真机上使用")
    #else
    let generation = sessionGeneration
    guard camera == nil else { throw CameraError.unavailable("请先断开当前相机") }
    let control: ICAuthorizationStatus = await withCheckedContinuation { callback in
      browser.requestControlAuthorization { callback.resume(returning: $0) }
    }
    guard generation == sessionGeneration else { throw CameraError.disconnected }
    guard control == .authorized else { throw CameraError.unavailable("相机控制权限未允许，请到 iOS 设置开启相机权限") }
    let contents: ICAuthorizationStatus = await withCheckedContinuation { callback in
      browser.requestContentsAuthorization { callback.resume(returning: $0) }
    }
    guard generation == sessionGeneration else { throw CameraError.disconnected }
    guard contents == .authorized else { throw CameraError.unavailable("外接相机内容访问权限未允许") }
    guard UIApplication.shared.applicationState != .background else {
      throw CameraError.disconnected
    }
    browser.stop()
    devices.removeAll()
    state = "discovering"
    message = "正在搜索 USB 相机，请保持相机开机并解锁 iPhone"
    browser.start()
    log(message)
    #endif
  }

  private func connect(_ id: String) async throws {
    let generation = sessionGeneration
    guard camera == nil, let device = devices[id] else {
      throw CameraError.unavailable("设备不可用，请重新搜索")
    }
    guard !openingDevices.contains(ObjectIdentifier(device)), !device.hasOpenSession else {
      throw CameraError.unavailable("上一会话尚未关闭，请稍后重试或重新插拔 USB")
    }
    guard device.usbVendorID == 0x04A9 else {
      throw CameraError.unavailable("此验证版本仅允许连接 Canon USB 相机")
    }
    camera = device
    device.delegate = self
    state = "connecting"
    message = "打开 PTP 会话并读取相机目录…"
    publish()
    do {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        sessionWaiter = continuation
        sessionTimeout = Task { [weak self] in
          do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
          self?.abort(CameraError.timeout)
        }
        openingDevices.insert(ObjectIdentifier(device))
        device.requestOpenSession(options: nil) { [weak self] error in
          Task { @MainActor in
            self?.openingDevices.remove(ObjectIdentifier(device))
            guard let self, generation == self.sessionGeneration, self.camera === device else {
              // A timed-out open can still succeed after abort().
              if device.hasOpenSession { device.requestCloseSession() }
              return
            }
            if let error { self.abort(error) }
          }
        }
      }
      guard generation == sessionGeneration, camera === device else {
        throw CameraError.disconnected
      }
      guard
        device.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
      else {
        throw CameraError.unavailable("相机未开放 PTP 命令能力")
      }
      let transport = ImageCaptureTransport(camera: device)
      transport.log = { [weak self] in self?.log($0) }
      transport.onFatalError = { [weak self] in self?.abort($0) }
      self.transport = transport
      let driver = CanonEOS(transport: transport)
      eos = driver
      let info = try await driver.readDeviceInfo()
      guard generation == sessionGeneration, camera === device else {
        throw CameraError.disconnected
      }
      recordPendingHandles(driver.drainPendingObjectHandles())
      model = info.model
      state = "ready"
      message = "PTP 已连接，目录已就绪"
      log("\(info.model) · PTP supported · \(info.operations.count) 项操作")
    } catch {
      if generation == sessionGeneration, camera === device { abort(error) }
      throw error
    }
  }

  private func disconnect() async throws {
    let generation = sessionGeneration
    let driver = eos
    await pauseFrames()
    guard generation == sessionGeneration else { return }
    do { try await driver?.shutdown() } catch { log("恢复相机状态失败：\(error.localizedDescription)") }
    if generation == sessionGeneration { abort() }
  }

  private func suspend() async {
    guard !suspending else { return }
    suspending = true
    let generation = sessionGeneration
    let backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Close Canon session") {
      [weak self] in
      Task { @MainActor in self?.abort() }
    }
    let deadline = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
      self?.abort()
    }
    while busy && generation == sessionGeneration {
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    if generation == sessionGeneration {
      busy = true
      try? await disconnect()
    }
    deadline.cancel()
    if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
    browser.stop()
    devices.removeAll()
    suspending = false
    publish()
  }

  private func abort(_ error: Error? = nil) {
    sessionGeneration += 1
    aiTask?.cancel()
    aiTask = nil
    aiRequestID = nil
    guidance = nil
    latestJPEG = nil
    latestFrameTime = nil
    liveTask?.cancel()
    liveTask = nil
    downloadTask?.cancel()
    downloadTask = nil
    downloadProgress?.cancel()
    downloadProgress = nil
    if let directory = downloadDirectory { CaptureDownloadWorkspace.remove(directory) }
    downloadDirectory = nil
    downloadTimeout?.cancel()
    downloadTimeout = nil
    downloadWaiter?.resume(throwing: error ?? CameraError.disconnected)
    downloadWaiter = nil
    sessionTimeout?.cancel()
    sessionTimeout = nil
    sessionWaiter?.resume(throwing: error ?? CameraError.disconnected)
    sessionWaiter = nil
    captureTimeout?.cancel()
    captureTimeout = nil
    transport?.invalidate(error ?? CameraError.disconnected)
    transport = nil
    eos = nil
    let oldCamera = camera
    camera = nil
    oldCamera?.delegate = nil
    if oldCamera?.hasOpenSession == true { oldCamera?.requestCloseSession() }
    catalogReady = false
    busy = false
    fps = 0
    downloadQueue.removeAll()
    queuedHandles.removeAll()
    knownHandles.removeAll()
    importedHandles.removeAll()
    pendingEventHandles.removeAll()
    texture.clear()
    state = error == nil ? "disconnected" : "error"
    message = error?.localizedDescription ?? "相机已断开"
    poseTracker.setEnabled(false)
    log(message)
  }

  private func pauseFrames() async {
    poseTracker.suspend()
    let previous = liveTask
    liveTask = nil
    previous?.cancel()
    await previous?.value
  }

  private func startFrameLoop() {
    guard liveTask == nil, let driver = eos else { return }
    let generation = sessionGeneration
    liveTask = Task { [weak self] in
      guard let self else { return }
      var lastGood = Date()
      var reportTime = Date()
      var frames = 0
      do {
        while !Task.isCancelled && generation == self.sessionGeneration {
          do {
            let jpeg = try await driver.frame()
            try Task.checkCancellation()
            let size = try await self.texture.update(jpeg)
            try Task.checkCancellation()
            guard generation == self.sessionGeneration else { return }
            self.frameSize = size
            self.latestJPEG = jpeg
            self.latestFrameTime = Date()
            if !self.busy { self.poseTracker.submit(jpeg) }
            self.registry.textureFrameAvailable(self.textureID)
            lastGood = Date()
            frames += 1
            let elapsed = Date().timeIntervalSince(reportTime)
            if self.state != "liveview_running" || elapsed >= 1 {
              self.state = "liveview_running"
              self.message = "实时取景中"
              self.fps = Double(frames) / max(elapsed, 0.1)
              self.publish()
              frames = 0
              reportTime = Date()
            }
          } catch CameraError.response(_, let code) where code == 0x2019 || code == 0xA102 {
            if Date().timeIntervalSince(lastGood) > 4 {
              throw CameraError.unavailable("相机持续忙碌，未取得取景帧")
            }
          }
          try await Task.sleep(nanoseconds: 100_000_000)
        }
      } catch is CancellationError { return } catch {
        guard !Task.isCancelled, generation == self.sessionGeneration else { return }
        self.liveTask = nil
        self.poseTracker.setEnabled(false)
        self.log("实时取景停止：\(error.localizedDescription)")
        self.busy = true
        try? await driver.stopLiveView()
        guard generation == self.sessionGeneration else { return }
        self.busy = false
        self.state = "ready"
        self.fps = 0
        self.message = error.localizedDescription
        self.texture.clear()
        self.publish()
        self.scheduleDownloads()
      }
    }
  }

  private func cameraFiles() -> [ICCameraFile] {
    (camera?.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.filter {
      ["jpg", "jpeg"].contains(($0.name ?? "").split(separator: ".").last?.lowercased() ?? "")
    }.sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
  }

  private func cameraRAWBasenames() -> Set<String> {
    Set(
      (camera?.mediaFiles ?? []).compactMap { ($0 as? ICCameraFile)?.name }.compactMap { name in
        let ext = (name as NSString).pathExtension.lowercased()
        guard ext == "cr3" || ext == "cr2" else { return nil }
        return (name as NSString).deletingPathExtension.uppercased()
      })
  }

  private var capturesDirectory: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Captures", isDirectory: true)
  }

  private func loadCaptures() {
    do {
      captures = try CaptureCatalog(directory: capturesDirectory).list()
    } catch { log("读取本地照片失败：\(error.localizedDescription)") }
  }

  private func recordPendingHandles(_ handles: [UInt32]) {
    var added = false
    for handle in handles where handle != 0 && !knownHandles.contains(handle) && !importedHandles.contains(handle) {
      if pendingEventHandles.insert(handle).inserted {
        added = true
        log("记录 EOS 对象事件：handle \(handle)")
      }
    }
    if added { reconcilePendingHandles() }
  }

  private func reconcilePendingHandles() {
    guard catalogReady, !pendingEventHandles.isEmpty else { return }
    for file in cameraFiles() {
      let handle = file.ptpObjectHandle
      if pendingEventHandles.remove(handle) != nil || !knownHandles.contains(handle) {
        guard !knownHandles.contains(handle) else { continue }
        knownHandles.insert(handle)
        receivedJPEGCount += 1
        captureTimeout?.cancel()
        captureTimeout = nil
        log("事件兜底匹配 JPEG：\(file.name ?? "JPEG") · handle \(handle)")
        if autoDownload { enqueue(file) }
      }
    }
    pendingEventHandles.subtract(knownHandles)
    pendingEventHandles.subtract(importedHandles)
  }

  private func enqueue(_ file: ICCameraFile) {
    guard !queuedHandles.contains(file.ptpObjectHandle),
      !importedHandles.contains(file.ptpObjectHandle)
    else { return }
    queuedHandles.insert(file.ptpObjectHandle)
    downloadQueue.append(file)
    scheduleDownloads()
  }

  private func scheduleDownloads() {
    guard !busy, !suspending, downloadTask == nil, !downloadQueue.isEmpty, camera != nil else {
      return
    }
    let generation = sessionGeneration
    busy = true
    publish()
    downloadTask = Task { [weak self] in
      guard let self, !Task.isCancelled, generation == self.sessionGeneration else { return }
      let wasLive = self.liveTask != nil
      await self.pauseFrames()
      guard generation == self.sessionGeneration else { return }
      defer {
        if generation == self.sessionGeneration {
          self.busy = false
          self.downloadTask = nil
          if wasLive { self.startFrameLoop() }
          self.publish()
        }
      }
      while !self.downloadQueue.isEmpty && !Task.isCancelled && generation == self.sessionGeneration
      {
        let file = self.downloadQueue.removeFirst()
        self.message = "正在下载 \(file.name ?? "JPEG")"
        self.publish()
        do {
          let path = try await self.download(file)
          guard generation == self.sessionGeneration else { return }
          self.importedHandles.insert(file.ptpObjectHandle)
          self.pendingEventHandles.remove(file.ptpObjectHandle)
          try? await self.eos?.acknowledgeObjectTransfer(file.ptpObjectHandle)
          self.loadCaptures()
          self.message = "照片已保存到本机"
          self.log("下载完成：\(URL(fileURLWithPath: path).lastPathComponent)")
        } catch {
          guard generation == self.sessionGeneration else { return }
          self.message = error.localizedDescription
          self.log("下载失败：\(error.localizedDescription)")
        }
        self.queuedHandles.remove(file.ptpObjectHandle)
      }
    }
  }

  private func download(_ file: ICCameraFile) async throws -> String {
    let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).jpg"
    let destination = capturesDirectory.appendingPathComponent(name)
    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("IncomingDownloads", isDirectory: true)
    let directory = try CaptureDownloadWorkspace(root: root).create()
    downloadDirectory = directory
    let generation = sessionGeneration
    return try await withCheckedThrowingContinuation { continuation in
      downloadWaiter = continuation
      downloadTimeout = Task { [weak self] in
        do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
        self?.abort(CameraError.timeout)
      }
      downloadProgress = file.requestDownload(options: [
        .downloadsDirectoryURL: directory, .saveAsFilename: name,
        .overwrite: false, .deleteAfterSuccessfulDownload: false,
      ]) { [weak self] filename, error in
        Task { @MainActor in
          defer { CaptureDownloadWorkspace.remove(directory) }
          guard let self, generation == self.sessionGeneration, let waiter = self.downloadWaiter
          else { return }
          self.downloadDirectory = nil
          self.downloadWaiter = nil
          self.downloadTimeout?.cancel()
          self.downloadTimeout = nil
          self.downloadProgress = nil
          if let error {
            waiter.resume(throwing: error)
            return
          }
          let url = directory.appendingPathComponent(
            (filename as NSString?)?.lastPathComponent ?? name)
          guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
          else {
            waiter.resume(throwing: CameraError.invalidData("下载的 JPEG 无法解码"))
            return
          }
          do {
            try FileManager.default.moveItem(at: url, to: destination)
            waiter.resume(returning: destination.path)
          } catch { waiter.resume(throwing: error) }
        }
      }
    }
  }

  func log(_ text: String) {
    let time = ISO8601DateFormatter().string(from: Date())
    logs.append("\(time)  \(text)")
    if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    publish()
  }
  private func publish() { emit?(snapshot()) }

  nonisolated func deviceBrowser(
    _ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool
  ) {
    Task { @MainActor in
      guard let device = device as? ICCameraDevice,
        device.transportType == ICDeviceTransport.transportTypeUSB.rawValue
      else { return }
      let id = device.uuidString ?? String(describing: ObjectIdentifier(device))
      devices[id] = device
      log("发现 \(device.name ?? "相机") · USB vendor \(device.usbVendorID)")

    }
  }
  nonisolated func deviceBrowser(
    _ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool
  ) {
    Task { @MainActor in
      devices = devices.filter { $0.value !== device }
      if camera === device { abort(CameraError.disconnected) }
      publish()

    }
  }
  nonisolated func didRemove(_ device: ICDevice) {
    Task { @MainActor in
      if camera === device { abort(CameraError.disconnected) }
    }
  }
  nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
    Task { @MainActor in
      guard camera === device else { return }
      if let error { abort(error) } else { log("PTP 会话已打开，等待目录枚举完成") }

    }
  }
  nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
    Task { @MainActor in
      if camera === device { abort(error ?? CameraError.disconnected) }

    }
  }
  nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
    Task { @MainActor in
      guard camera === device else { return }
      knownHandles = Set(cameraFiles().map(\.ptpObjectHandle))
      catalogReady = true
      sessionTimeout?.cancel()
      sessionTimeout = nil
      sessionWaiter?.resume()
      sessionWaiter = nil
      publish()

    }
  }
  nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
    Task { @MainActor in
      guard self.camera === camera, catalogReady else { return }
      for file in cameraFiles() where !knownHandles.contains(file.ptpObjectHandle) {
        knownHandles.insert(file.ptpObjectHandle)
        pendingEventHandles.remove(file.ptpObjectHandle)
        receivedJPEGCount += 1
        captureTimeout?.cancel()
        captureTimeout = nil
        log("新增 JPEG：\(file.name ?? "JPEG") · handle \(file.ptpObjectHandle)")
        if autoDownload { enqueue(file) }
      }
      reconcilePendingHandles()
      publish()

    }
  }
  nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
    Task { @MainActor in
      guard self.camera === camera else { return }
      let handles = Set(items.map(\.ptpObjectHandle))
      knownHandles.subtract(handles)
      importedHandles.subtract(handles)
      queuedHandles.subtract(handles)
      downloadQueue.removeAll { handles.contains($0.ptpObjectHandle) }
      publish()
    }
  }
  nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
    Task { @MainActor in publish()
    }
  }
  nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
    Task { @MainActor in publish()
    }
  }
  nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
    Task { @MainActor in
      guard self.camera === camera else { return }
      log(
        "PTP event："
          + eventData.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " "))
      if let handle = PTPCodec.ptpEventObjectHandle(eventData) {
        recordPendingHandles([handle])
      }

    }
  }
  nonisolated func cameraDevice(
    _ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem,
    error: Error?
  ) {
  }
  nonisolated func cameraDevice(
    _ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
    for item: ICCameraItem, error: Error?
  ) {
  }
  nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
    Task { @MainActor in publish()
    }
  }
  nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
    Task { @MainActor in
      if camera === device { abort(CameraError.unavailable("设备访问受限，请解锁设备")) }

    }
  }
}
