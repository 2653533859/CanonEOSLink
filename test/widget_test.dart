import 'dart:async';

import 'package:canon_eos_link/core/camera/camera_bridge.dart';
import 'package:canon_eos_link/core/camera/camera_controller.dart';
import 'package:canon_eos_link/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCameraRepository implements CameraRepository {
  final updates = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  Map<String, dynamic> state = {'state': 'disconnected'};
  final calls = <String>[];
  Completer<void>? pending;
  Object? failure;
  @override
  Stream<Map<String, dynamic>> get events => updates.stream;
  @override
  Future<Map<String, dynamic>> getState() async => state;
  @override
  Future<void> command(String method, [Map<String, dynamic>? arguments]) async {
    calls.add(method);
    if (failure != null) throw failure!;
    await pending?.future;
  }

  @override
  Future<String> diagnostics() async => 'PTP 0x1001 → 0x2001';
  void update(Map<String, dynamic> data) {
    state = data;
    updates.add(data);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'duplicate shutter requests are blocked until native request finishes',
    () async {
      final repository = FakeCameraRepository()..state = {'state': 'ready'};
      final controller = CameraController(repository);
      await controller.initialize();
      expect(controller.canCapture, isTrue);
      repository.pending = Completer<void>();
      final capture = controller.run('capture');
      await controller.run('capture');
      expect(repository.calls, ['capture']);
      expect(controller.canCapture, isFalse);
      repository.pending!.complete();
      await capture;
      expect(controller.canCapture, isTrue);
      controller.dispose();
      await repository.updates.close();
    },
  );

  test(
    'disconnect events immediately disable capture and clear live state',
    () async {
      final repository = FakeCameraRepository()
        ..state = {'state': 'liveview_running', 'textureId': 9};
      final controller = CameraController(repository);
      await controller.initialize();
      repository.update({'state': 'disconnected', 'message': 'USB 已拔出'});
      expect(controller.canCapture, isFalse);
      expect(controller.snapshot.live, isFalse);
      expect(controller.snapshot.message, 'USB 已拔出');
      controller.dispose();
      await repository.updates.close();
    },
  );

  test('native errors are shown and pending commands release the UI', () async {
    final repository = FakeCameraRepository()
      ..failure = PlatformException(code: 'camera_error', message: '未获得相机权限');
    final controller = CameraController(repository);
    await controller.initialize();
    await controller.run('discover');
    expect(controller.error, '未获得相机权限');
    expect(controller.busy, isFalse);
    controller.dispose();
    await repository.updates.close();
  });

  test(
    'native method channel uses the documented method and argument contract',
    () async {
      const channel = MethodChannel('com.parado.canoneos/control');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'getState' ? {'state': 'ready'} : null;
          });
      final repository = NativeCameraRepository();
      expect((await repository.getState())['state'], 'ready');
      await repository.command('startLiveView', {'parameter': 0x00200000});
      expect(calls.last.method, 'startLiveView');
      expect(calls.last.arguments, {'parameter': 0x00200000});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    },
  );

  for (final size in [
    const Size(428, 926),
    const Size(320, 568),
    const Size(926, 428),
  ]) {
    testWidgets('disconnected and connected layouts fit $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = FakeCameraRepository();
      await tester.pumpWidget(CanonEOSLinkApp(repository: repository));
      await tester.pumpAndSettle();
      expect(find.text('搜索 USB 相机'), findsOneWidget);
      expect(find.byType(Texture), findsNothing);
      expect(tester.takeException(), isNull);
      repository.update({'state': 'ready', 'message': '已连接'});
      await tester.pumpAndSettle();
      expect(find.text('开启取景'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await repository.updates.close();
    });
  }

  testWidgets('only a decoded native frame enables the texture', (
    tester,
  ) async {
    final repository = FakeCameraRepository()
      ..state = {'state': 'liveview_starting', 'textureId': 42};
    await tester.pumpWidget(CanonEOSLinkApp(repository: repository));
    await tester.pumpAndSettle();
    expect(find.byType(Texture), findsNothing);
    repository.update({
      'state': 'liveview_running',
      'textureId': 42,
      'width': 960,
      'height': 640,
    });
    await tester.pumpAndSettle();
    expect(tester.widget<Texture>(find.byType(Texture)).textureId, 42);
    await tester.pumpWidget(const SizedBox());
    await repository.updates.close();
  });
}
