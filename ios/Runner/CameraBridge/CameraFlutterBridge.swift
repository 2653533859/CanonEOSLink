import Flutter

@MainActor
final class CameraFlutterBridge: NSObject, FlutterStreamHandler {
  private let coordinator: USBCameraCoordinator
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel

  init(registrar: FlutterPluginRegistrar) {
    coordinator = USBCameraCoordinator(registry: registrar.textures())
    methods = FlutterMethodChannel(
      name: "com.parado.canoneos/control", binaryMessenger: registrar.messenger())
    events = FlutterEventChannel(
      name: "com.parado.canoneos/events", binaryMessenger: registrar.messenger())
    super.init()
    events.setStreamHandler(self)
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "disposed", message: "相机桥接已释放", details: nil))
        return
      }
      Task { @MainActor in
        do {
          result(
            try await self.coordinator.handle(
              call.method, arguments: call.arguments as? [String: Any] ?? [:]))
        } catch {
          result(
            FlutterError(code: "camera_error", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  nonisolated func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    Task { @MainActor in
      coordinator.emit = { events($0) }
      events(coordinator.snapshot())
    }
    return nil
  }

  nonisolated func onCancel(withArguments arguments: Any?) -> FlutterError? {
    Task { @MainActor in coordinator.emit = nil }
    return nil
  }
}
