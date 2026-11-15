import 'dart:async';

import 'package:canon_eos_link/core/camera/camera_bridge.dart';
import 'package:canon_eos_link/core/camera/camera_controller.dart';
import 'package:canon_eos_link/features/photo_editor/photo_editor_page.dart';
import 'package:canon_eos_link/features/photo_editor/photo_repository.dart';
import 'package:canon_eos_link/features/shooting/shooting_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _StageFourCameraRepository implements CameraRepository {
  final updates = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  Map<String, dynamic> state = {'state': 'disconnected'};

  @override
  Stream<Map<String, dynamic>> get events => updates.stream;

  @override
  Future<Map<String, dynamic>> getState() async => state;

  @override
  Future<void> command(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {}

  @override
  Future<String> diagnostics() async => '';
}

final _tinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PhotoRecipe serializes highlights and shadows with zero defaults', () {
    const empty = PhotoRecipe();
    expect(empty.highlights, 0);
    expect(empty.shadows, 0);
    expect(PhotoRecipe.fromMap(const {'exposure': 0.5}), const PhotoRecipe(exposure: 0.5));

    final adjusted = empty.copyWith(highlights: -0.4, shadows: 0.6);
    expect(adjusted.toMap(), {
      'exposure': 0,
      'contrast': 1,
      'saturation': 1,
      'warmth': 0,
      'highlights': -0.4,
      'shadows': 0.6,
    });
    expect(PhotoRecipe.fromMap(adjusted.toMap()), adjusted);
    expect(adjusted.hashCode, PhotoRecipe.fromMap(adjusted.toMap()).hashCode);
  });

  test('NativePhotoRepository.export forwards preserveExif only when enabled', () async {
    const channel = MethodChannel('com.parado.canoneos/photo');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return '/app/Documents/Exports/out.jpg';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final repo = NativePhotoRepository();
    const recipe = PhotoRecipe(highlights: -0.5, shadows: 0.3);

    await repo.export('/app/Documents/Captures/a.jpg', recipe);
    final firstArgs = Map<String, dynamic>.from(calls.last.arguments as Map);
    expect(firstArgs.containsKey('preserveExif'), isFalse);
    expect((firstArgs['recipe'] as Map)['highlights'], -0.5);
    expect((firstArgs['recipe'] as Map)['shadows'], 0.3);

    await repo.export('/app/Documents/Captures/a.jpg', recipe, preserveExif: true);
    final secondArgs = Map<String, dynamic>.from(calls.last.arguments as Map);
    expect(secondArgs['preserveExif'], isTrue);
  });

  testWidgets('PhotoEditorPage exposes highlights, shadows, and EXIF export switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const channel = MethodChannel('com.parado.canoneos/photo');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'loadRecipe' => <String, dynamic>{},
            'preview' => _tinyPng,
            'export' => '/app/Documents/Exports/a.jpg',
            _ => null,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final cameraRepo = _StageFourCameraRepository();
    final camera = CameraController(cameraRepo);
    await camera.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: PhotoEditorPage(
          path: '/app/Documents/Captures/a.jpg',
          controller: camera,
          repository: NativePhotoRepository(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('高光'), findsOneWidget);
    expect(find.text('阴影'), findsOneWidget);
    expect(find.text('保留拍摄参数 EXIF'), findsOneWidget);

    await tester.ensureVisible(find.text('保留拍摄参数 EXIF'));
    await tester.tap(find.text('保留拍摄参数 EXIF'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('导出 JPEG'));
    await tester.tap(find.text('导出 JPEG'));
    await tester.pumpAndSettle();

    final exportCall = calls.lastWhere((call) => call.method == 'export');
    final args = Map<String, dynamic>.from(exportCall.arguments as Map);
    expect(args['preserveExif'], isTrue);

    await tester.pumpWidget(const SizedBox());
    camera.dispose();
    await cameraRepo.updates.close();
  });

  testWidgets('ShootingPage camera files sheet highlights companion RAW files', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _StageFourCameraRepository()
      ..state = {
        'state': 'ready',
        'model': 'Canon EOS R10',
        'rawCount': 2,
        'files': [
          {
            'handle': 101,
            'name': 'IMG_0001.JPG',
            'downloaded': false,
            'hasRAW': true,
          },
          {
            'handle': 102,
            'name': 'IMG_0002.JPG',
            'downloaded': true,
            'hasRAW': false,
          },
        ],
      };
    final controller = CameraController(repo);
    await controller.initialize();
    expect(controller.snapshot.rawCount, 2);

    await tester.pumpWidget(
      MaterialApp(home: ShootingPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('相机里的 JPEG'));
    await tester.tap(find.text('相机里的 JPEG'));
    await tester.pumpAndSettle();

    expect(find.text('同卡 RAW 2 张（仅提示，不传输）'), findsOneWidget);
    expect(find.text('IMG_0001.JPG'), findsOneWidget);
    expect(find.text('包含同名 RAW (CR3)'), findsOneWidget);
    expect(find.text('IMG_0002.JPG'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await repo.updates.close();
  });
}
