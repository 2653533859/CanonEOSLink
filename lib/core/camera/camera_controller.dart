import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'camera_bridge.dart';

class CameraController extends ChangeNotifier {
  CameraController(this.repository);
  final CameraRepository repository;
  CameraSnapshot snapshot = const CameraSnapshot();
  String? error;
  bool _pending = false;
  bool _aiPending = false;
  bool _disposed = false;
  bool _hasEvent = false;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  bool get busy => _pending || snapshot.busy;
  bool get canCapture => snapshot.connected && !busy;
  bool get aiBusy => _aiPending || snapshot.aiBusy;

  Future<void> initialize() async {
    _subscription = repository.events.listen((data) {
      _hasEvent = true;
      snapshot = CameraSnapshot.fromMap(data);
      _notify();
    }, onError: (Object e) => _setError(e));
    try {
      final data = await repository.getState();
      if (!_hasEvent) snapshot = CameraSnapshot.fromMap(data);
      _notify();
    } catch (e) {
      _setError(e);
    }
  }

  Future<bool> run(String method, [Map<String, dynamic>? arguments]) async {
    if (method == 'analyzeFrame') {
      if (busy || aiBusy) return false;
      _aiPending = true;
      error = null;
      _notify();
      try {
        await repository.command(method, arguments);
      } catch (e) {
        _setError(e);
      } finally {
        _aiPending = false;
        _notify();
      }
      return error == null;
    }
    if (busy) return false;
    _pending = true;
    error = null;
    _notify();
    try {
      await repository.command(method, arguments);
    } catch (e) {
      _setError(e);
    } finally {
      _pending = false;
      _notify();
    }
    return error == null;
  }

  void _setError(Object exception) {
    error = switch (exception) {
      PlatformException e => e.message ?? e.code,
      MissingPluginException() => 'USB 相机功能需要在 iPhone 上运行此 iOS 工程。',
      _ => exception.toString(),
    };
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
