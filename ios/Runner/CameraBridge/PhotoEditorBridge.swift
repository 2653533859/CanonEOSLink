import Flutter
import Foundation
import Photos

private actor PhotoProcessor {
  func render(
    _ data: Data, recipe: PhotoRecipe, maxDimension: Int?, preserveMetadataFrom sourceData: Data? = nil
  ) throws -> Data {
    try PhotoEditCore.render(
      PhotoEditCore.image(data), recipe: recipe, maxDimension: maxDimension,
      preserveMetadataFrom: sourceData)
  }
  func auto(_ data: Data) throws -> [String: Double] {
    try PhotoEditCore.automaticRecipe(PhotoEditCore.image(data)).dictionary
  }
}

/// Photo operations use a separate channel and never mutate the source file.
@MainActor
final class PhotoEditorBridge {
  private let methods: FlutterMethodChannel
  private let aiStore = AIConfigurationStore()
  private let aiService = AIGuidanceService()
  private let processor = PhotoProcessor()
  private let storage = PhotoEditStorage(
    documents: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])

  init(registrar: FlutterPluginRegistrar) {
    methods = FlutterMethodChannel(
      name: "com.parado.canoneos/photo", binaryMessenger: registrar.messenger())
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "disposed", message: "照片处理不可用", details: nil))
        return
      }
      Task { @MainActor in
        do {
          result(
            try await self.handle(call.method, arguments: call.arguments as? [String: Any] ?? [:]))
        } catch {
          result(
            FlutterError(code: "photo_error", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func handle(_ method: String, arguments: [String: Any]) async throws -> Any? {
    guard let path = arguments["path"] as? String else { throw CameraError.invalidData("缺少照片路径") }
    if method == "saveToPhotos" {
      let url = try storage.exportedURL(path)
      let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
      guard status == .authorized || status == .limited else {
        throw CameraError.unavailable("无法添加到系统相册，请在系统设置中允许照片添加权限")
      }
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
      }
      return nil
    }
    let source = try storage.sourceURL(path)
    let settings = try PhotoRecipe(dictionary: arguments["recipe"] as? [String: Any] ?? [:])
    switch method {
    case "loadRecipe":
      return try storage.loadRecipe(source: source).dictionary
    case "saveRecipe":
      try storage.saveRecipe(source: source, recipe: settings)
      return nil
    case "preview", "autoRecipe", "export", "analyzePhoto":
      let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
      if method == "autoRecipe" {
        return try await processor.auto(bytes)
      }
      if method == "analyzePhoto" {
        let configuration = try aiStore.configuration()
        let goal = arguments["goal"] as? String ?? "分析照片的曝光、构图和色彩，提出简洁改进建议"
        let preview = try await processor.render(bytes, recipe: settings, maxDimension: 1024)
        let result = try await aiService.analyzePhoto(
          jpeg: preview, recipe: settings, goal: goal, configuration: configuration)
        return result.dictionary
      }
      let maxDimension = method == "preview" ? 1280 : nil
      let preserveExif = method == "export" && (arguments["preserveExif"] as? Bool ?? false)
      let data = try await processor.render(
        bytes, recipe: settings, maxDimension: maxDimension,
        preserveMetadataFrom: preserveExif ? bytes : nil)
      if method == "preview" { return FlutterStandardTypedData(bytes: data) }
      return try storage.export(data).path
    default: throw CameraError.unavailable("未知照片处理操作")
    }
  }
}
