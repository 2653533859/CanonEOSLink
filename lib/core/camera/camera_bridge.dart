import 'package:flutter/services.dart';

abstract interface class CameraRepository {
  Stream<Map<String, dynamic>> get events;
  Future<Map<String, dynamic>> getState();
  Future<void> command(String method, [Map<String, dynamic>? arguments]);
  Future<String> diagnostics();
}

class NativeCameraRepository implements CameraRepository {
  static const _methods = MethodChannel('com.parado.canoneos/control');
  static const _events = EventChannel('com.parado.canoneos/events');

  @override
  Stream<Map<String, dynamic>> get events => _events
      .receiveBroadcastStream()
      .map((value) => Map<String, dynamic>.from(value as Map));
  @override
  Future<Map<String, dynamic>> getState() async => Map<String, dynamic>.from(
    await _methods.invokeMapMethod('getState') ?? {},
  );
  @override
  Future<void> command(String method, [Map<String, dynamic>? arguments]) async {
    await _methods.invokeMethod<Object?>(method, arguments);
  }

  @override
  Future<String> diagnostics() async =>
      await _methods.invokeMethod<String>('exportDiagnostics') ?? '';
}

class CameraSnapshot {
  const CameraSnapshot({
    this.state = 'disconnected',
    this.busy = false,
    this.message = '连接相机后，点击搜索 USB',
    this.model = 'Canon EOS R10',
    this.textureId = -1,
    this.aspectRatio = 1.5,
    this.fps = 0,
    this.autoDownload = true,
    this.devices = const [],
    this.files = const [],
    this.captureCount = 0,
    this.logs = const [],
    this.exposure = const {},
    this.aiConfig = const {},
    this.guidance = const {},
    this.canUndoExposure = false,
    this.aiBusy = false,
    this.poseTracking = const {},
    this.histogram = const [],
    this.highlightClipped = false,
    this.rawCount = 0,
  });

  factory CameraSnapshot.fromMap(Map<String, dynamic> map) {
    List<Map<String, dynamic>> records(String key) => (map[key] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final width = (map['width'] as num?)?.toDouble() ?? 3;
    final height = (map['height'] as num?)?.toDouble() ?? 2;
    return CameraSnapshot(
      state: map['state'] as String? ?? 'disconnected',
      busy: map['busy'] as bool? ?? false,
      message: map['message'] as String? ?? '',
      model: map['model'] as String? ?? 'Canon EOS R10',
      textureId: (map['textureId'] as num?)?.toInt() ?? -1,
      aspectRatio: width > 0 && height > 0 ? width / height : 1.5,
      fps: (map['fps'] as num?)?.toDouble() ?? 0,
      autoDownload: map['autoDownload'] as bool? ?? true,
      devices: records('devices'),
      files: records('files'),
      captureCount: (map['captureCount'] as num?)?.toInt() ?? 0,
      logs: List<String>.from(map['logs'] as List? ?? []),
      exposure: Map<String, dynamic>.from(map['exposure'] as Map? ?? {}),
      aiConfig: Map<String, dynamic>.from(map['aiConfig'] as Map? ?? {}),
      guidance: Map<String, dynamic>.from(map['guidance'] as Map? ?? {}),
      canUndoExposure: map['canUndoExposure'] as bool? ?? false,
      aiBusy: map['aiBusy'] as bool? ?? false,
      poseTracking: Map<String, dynamic>.from(
        map['poseTracking'] as Map? ?? {},
      ),
      histogram: (map['histogram'] as List? ?? [])
          .whereType<num>()
          .map((e) => e.toDouble().clamp(0.0, 1.0))
          .toList(),
      highlightClipped: map['highlightClipped'] as bool? ?? false,
      rawCount: (map['rawCount'] as num?)?.toInt() ?? 0,
    );
  }
  final String state, message, model;
  final bool busy, autoDownload;
  final int textureId, captureCount;
  final double aspectRatio, fps;
  final List<Map<String, dynamic>> devices, files;
  final List<String> logs;
  final Map<String, dynamic> exposure, aiConfig, guidance;
  final bool canUndoExposure, aiBusy;
  final Map<String, dynamic> poseTracking;
  final List<double> histogram;
  final bool highlightClipped;
  final int rawCount;
  bool get connected =>
      const ['ready', 'liveview_starting', 'liveview_running'].contains(state);
  bool get live => state == 'liveview_running';
  bool get previewActive => live || state == 'liveview_starting';
  String get label => switch (state) {
    'discovering' => '搜索中',
    'connecting' => '连接中',
    'ready' => '已连接',
    'liveview_starting' => '等待画面',
    'liveview_running' => '实时取景',
    'error' => '连接异常',
    _ => '未连接',
  };
}
