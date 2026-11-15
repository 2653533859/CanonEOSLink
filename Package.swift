// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "CanonPTPCore",
  platforms: [.macOS(.v13)],
  targets: [
    .target(
      name: "CanonPTPCore", path: "ios/Runner/CameraBridge",
      exclude: [
        "PTPTransport.swift", "JPEGTexture.swift", "USBCameraCoordinator.swift",
        "CameraFlutterBridge.swift", "AIConfigurationStore.swift", "PhotoEditorBridge.swift",
      ],
      sources: ["PTPProtocol.swift", "ExposureSettings.swift", "CanonEOS.swift", "AIGuidance.swift", "PhotoEditCore.swift", "PhotoEditStorage.swift", "PoseTracking.swift", "CaptureDownloadWorkspace.swift"]),
    .testTarget(name: "CanonPTPCoreTests", dependencies: ["CanonPTPCore"], path: "tests/swift"),
  ]
)
