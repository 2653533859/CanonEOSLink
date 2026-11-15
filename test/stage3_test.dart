import 'dart:async';
import 'dart:convert';

import 'package:canon_eos_link/core/camera/camera_bridge.dart';
import 'package:canon_eos_link/core/camera/camera_controller.dart';
import 'package:canon_eos_link/features/photo_editor/photo_editor_page.dart';
import 'package:canon_eos_link/features/photo_editor/photo_repository.dart';
import 'package:canon_eos_link/features/pose_guide/pose_library_page.dart';
import 'package:canon_eos_link/features/pose_guide/pose_reference.dart';
import 'package:canon_eos_link/features/pose_guide/photo_pose_reference.dart';
import 'package:canon_eos_link/features/pose_guide/basic_photo_pose_reference.dart';
import 'package:canon_eos_link/features/pose_guide/pose_illustration.dart';
import 'package:canon_eos_link/features/shooting/shooting_page.dart';
import 'package:canon_eos_link/features/shooting/capture_gallery.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class EmptyCamera implements CameraRepository {
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  Future<Map<String, dynamic>> getState() async => {
    'aiConfig': {'hasKey': true},
  };
  @override
  Future<void> command(String method, [Map<String, dynamic>? args]) async {}
  @override
  Future<String> diagnostics() async => '';
}

class LivePoseCamera extends EmptyCamera {
  @override
  Future<Map<String, dynamic>> getState() async => {
    'state': 'liveview_running',
    'textureId': 42,
    'width': 960,
    'height': 640,
  };
}

class FakePhotos implements PhotoRepository {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  );
  final previews = <PhotoRecipe>[];
  final saves = <PhotoRecipe>[];
  final exports = <PhotoRecipe>[];
  final savedToPhotos = <String>[];
  final analyses = <PhotoRecipe>[];
  Completer<Uint8List>? firstPreview;
  bool failNextPreview = false;
  @override
  Future<PhotoRecipe> loadRecipe(String path) async => const PhotoRecipe();
  @override
  Future<void> saveRecipe(String path, PhotoRecipe recipe) async {
    saves.add(recipe);
  }

  @override
  Future<Uint8List> preview(String path, PhotoRecipe recipe) async {
    previews.add(recipe);
    if (failNextPreview) {
      failNextPreview = false;
      throw PlatformException(code: 'render', message: '无法渲染');
    }
    if (previews.length == 1 && firstPreview != null) {
      return firstPreview!.future;
    }
    return png;
  }

  @override
  Future<PhotoRecipe> autoRecipe(String path) async =>
      const PhotoRecipe(exposure: .4, contrast: 1.04);
  @override
  Future<String> export(
    String path,
    PhotoRecipe recipe, {
    bool preserveExif = false,
  }) async {
    exports.add(recipe);
    return '/app/Documents/Exports/output.jpg';
  }

  @override
  Future<void> saveToPhotos(String exportedPath) async {
    savedToPhotos.add(exportedPath);
  }

  @override
  Future<Map<String, dynamic>> analyze(
    String path,
    PhotoRecipe recipe,
    String goal,
  ) async {
    analyses.add(recipe);
    return {
      'summary': '曝光均匀',
      'composition': ['注意背景'],
      'applicable': true,
      'recipe': {
        'exposure': .25,
        'contrast': 1.05,
        'saturation': 1.1,
        'warmth': .2,
      },
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('capture page channel sends the cursor and returns entries', () async {
    const channel = MethodChannel('com.parado.canoneos/control');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return {
        'items': [
          {'path': '/app/Captures/old.jpg', 'name': 'old.jpg'},
        ],
        'nextCursor': null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final page = await loadCapturePage('new.jpg');
    expect(received?.method, 'listCaptures');
    expect((received?.arguments as Map)['before'], 'new.jpg');
    expect((page['items'] as List).length, 1);
  });
  testWidgets('capture gallery loads more and retries a failed page', (
    tester,
  ) async {
    final camera = CameraController(EmptyCamera());
    var calls = 0;
    final cursors = <String?>[];
    Future<Map<String, dynamic>> loader(String? before) async {
      cursors.add(before);
      calls++;
      if (calls == 2) throw PlatformException(code: 'read', message: '读取失败');
      if (before == null) {
        return {
          'items': [
            {'path': '/missing/new.jpg'},
          ],
          'nextCursor': 'new.jpg',
        };
      }
      return {
        'items': [
          {'path': '/missing/old.jpg'},
        ],
        'nextCursor': null,
      };
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CaptureGallery(controller: camera, loader: loader),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('加载失败：读取失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(cursors, [null, 'new.jpg', 'new.jpg']);
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('加载更多'), findsNothing);
    await tester.tap(find.text('刷新照片'));
    await tester.pumpAndSettle();
    expect(cursors.last, isNull);
    expect(find.text('加载更多'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    camera.dispose();
  });
  test('native photo channel passes path and adjustment recipe', () async {
    const channel = MethodChannel('com.parado.canoneos/photo');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'loadRecipe') {
            return {
              'exposure': .5,
              'contrast': 1.0,
              'saturation': 1.0,
              'warmth': 0.0,
            };
          }
          if (call.method == 'export') return '/app/Documents/Exports/a.jpg';
          return null;
        });
    final repository = NativePhotoRepository();
    final recipe = await repository.loadRecipe('/app/Documents/Captures/a.jpg');
    expect(recipe.exposure, .5);
    expect(
      await repository.export('/app/Documents/Captures/a.jpg', recipe),
      '/app/Documents/Exports/a.jpg',
    );
    expect(calls.last.method, 'export');
    expect(
      (calls.last.arguments as Map)['path'],
      '/app/Documents/Captures/a.jpg',
    );
    expect(((calls.last.arguments as Map)['recipe'] as Map)['exposure'], .5);
    await repository.saveToPhotos('/app/Documents/Exports/a.jpg');
    expect(calls.last.method, 'saveToPhotos');
    expect(
      (calls.last.arguments as Map)['path'],
      '/app/Documents/Exports/a.jpg',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test('pose catalog has complete, bounded and unique local references', () {
    expect(poseReferences.length, greaterThanOrEqualTo(6));
    expect(
      poseReferences.map((p) => p.id).toSet().length,
      poseReferences.length,
    );
    for (final pose in poseReferences) {
      expect(pose.joints.length, 14);
      expect(pose.photoAsset, isNotNull);
      expect(pose.photographer, isNotNull);
      expect(pose.photoSource, isNotNull);
      expect(pose.instructions, isNotEmpty);
      expect(pose.mistakes, isNotEmpty);
      expect(pose.cameraPosition, isNotEmpty);
      expect(pose.focalLength, contains('等效'));
      for (final joint in pose.joints) {
        expect(joint.dx, inInclusiveRange(0, 1));
        expect(joint.dy, inInclusiveRange(0, 1));
      }
    }
  });

  test('every pose has a bundled photographic reference', () async {
    for (final pose in [...poseReferences, ...photoPoseReferences]) {
      final path = pose.photoAsset;
      expect(path, isNotNull, reason: pose.id);
      expect(
        (await rootBundle.load(path!)).lengthInBytes,
        greaterThan(0),
        reason: pose.id,
      );
    }
  });

  testWidgets('basic poses filter contains only curated existing references', (
    tester,
  ) async {
    final all = [...poseReferences, ...photoPoseReferences];
    expect(basicPoseIds.length, greaterThanOrEqualTo(10));
    expect(basicPoseIds.difference(all.map((p) => p.id).toSet()), isEmpty);
    await tester.pumpWidget(const MaterialApp(home: PoseLibraryPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('基础姿势'));
    await tester.pumpAndSettle();
    expect(find.text('双臂交叠'), findsOneWidget);
    expect(find.text('街边倚靠'), findsNothing);
    await tester.tap(find.text('基础姿势'));
    await tester.pumpAndSettle();
    expect(find.text('街边倚靠'), findsOneWidget);
  });

  testWidgets(
    'real photo references have credits and cannot be used as an unverified overlay',
    (tester) async {
      expect(photoPoseReferences.length, greaterThanOrEqualTo(47));
      expect(
        {
          ...photoPoseReferences.map((p) => p.id),
          ...poseReferences.map((p) => p.id),
        }.length,
        photoPoseReferences.length + poseReferences.length,
      );
      expect(
        photoPoseReferences.every(
          (p) =>
              p.photoAsset != null &&
              p.photographer != null &&
              p.photoSource != null &&
              !p.supportsOverlay,
        ),
        isTrue,
      );
      await tester.pumpWidget(const MaterialApp(home: PoseLibraryPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('街边倚靠'));
      await tester.pumpAndSettle();
      expect(find.textContaining('摄影：Juliano Astc'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('真人照片仅供'),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('用于取景参考'), findsNothing);
    },
  );

  testWidgets('people filter separates couples and groups', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PoseLibraryPage()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('多人'));
    await tester.tap(find.text('多人'));
    await tester.pumpAndSettle();
    expect(find.text('三人搭肩'), findsOneWidget);
    expect(find.text('双人并肩'), findsNothing);
    await tester.ensureVisible(find.text('双人'));
    await tester.tap(find.text('双人'));
    await tester.pumpAndSettle();
    expect(find.text('三人搭肩'), findsNothing);
    expect(find.text('双人并肩'), findsOneWidget);
  });

  for (final size in [const Size(320, 568), const Size(926, 428)]) {
    testWidgets('pose and editor screens fit $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(home: PoseLibraryPage()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final camera = CameraController(EmptyCamera());
      await camera.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: PhotoEditorPage(
            path: '/app/Documents/Captures/a.jpg',
            controller: camera,
            repository: FakePhotos(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      camera.dispose();
    });
  }

  testWidgets('pose filters, detail and selection work offline', (
    tester,
  ) async {
    PoseReference? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  selected = await Navigator.push<PoseReference>(
                    context,
                    MaterialPageRoute(builder: (_) => const PoseLibraryPage()),
                  );
                },
                child: const Text('打开姿势库'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开姿势库'));
    await tester.pumpAndSettle();
    expect(find.text('街边倚靠'), findsOneWidget);
    await tester.tap(find.text('室内'));
    await tester.pumpAndSettle();
    expect(find.text('自然站姿'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('坐姿前倾'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.text('坐姿前倾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('坐姿前倾'));
    await tester.pumpAndSettle();
    expect(find.text('动作提示'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('用于取景参考'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('用于取景参考'));
    await tester.pumpAndSettle();
    expect(selected?.id, 'sit_forward');
  });

  testWidgets(
    'selected pose overlays live view and can be mirrored or removed',
    (tester) async {
      tester.view.physicalSize = const Size(500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final camera = CameraController(LivePoseCamera());
      await tester.pumpWidget(
        MaterialApp(home: ShootingPage(controller: camera)),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('姿势参考'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('姿势参考'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('自然站姿'),
        250,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(find.text('自然站姿'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自然站姿'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('用于取景参考'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('用于取景参考'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byTooltip('镜像姿势'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('镜像姿势'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(Texture),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      final overlay = tester.widget<PoseIllustration>(
        find.byWidgetPredicate(
          (widget) => widget is PoseIllustration && widget.overlay,
        ),
      );
      expect(overlay.pose.id, 'stand_relaxed');
      expect(overlay.mirror, isTrue);
      await tester.scrollUntilVisible(
        find.byTooltip('移除姿势参考'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('移除姿势参考'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) => widget is PoseIllustration && widget.overlay,
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('photo presets undo compare and export keep original path', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final camera = CameraController(EmptyCamera());
    await camera.initialize();
    final photos = FakePhotos();
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoEditorPage(
          path: '/app/Documents/Captures/a.jpg',
          controller: camera,
          repository: photos,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('黑白'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(photos.previews.last.saturation, 0);
    await tester.tap(find.byTooltip('撤销上一步'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(photos.previews.last.saturation, 1);
    await tester.tap(find.text('暖调'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(photos.previews.last.warmth, .35);
    await tester.tap(find.text('查看原片'));
    await tester.pumpAndSettle();
    expect(photos.previews.last, const PhotoRecipe());
    await tester.scrollUntilVisible(
      find.text('分析这张照片'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    final analyze = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '分析这张照片'),
    );
    expect(analyze.onPressed, isNull);
    await tester.scrollUntilVisible(
      find.text('查看原片'),
      -250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('查看原片'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('导出 JPEG'));
    await tester.tap(find.text('导出 JPEG'));
    await tester.pumpAndSettle();
    expect(photos.saves.single.warmth, .35);
    expect(photos.exports.single, photos.saves.single);
    expect(find.textContaining('已导出至'), findsOneWidget);
    await tester.ensureVisible(find.text('将上次导出保存到相册'));
    await tester.tap(find.text('将上次导出保存到相册'));
    await tester.pumpAndSettle();
    expect(photos.savedToPhotos, ['/app/Documents/Exports/output.jpg']);
    expect(find.text('已保存到系统相册'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    camera.dispose();
  });

  testWidgets('failed photo preview hides old image and can be retried', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final camera = CameraController(EmptyCamera());
    await camera.initialize();
    final photos = FakePhotos();
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoEditorPage(
          path: '/app/Documents/Captures/a.jpg',
          controller: camera,
          repository: photos,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    photos.failNextPreview = true;
    await tester.tap(find.text('暖调'));
    await tester.pump();
    expect(find.byType(InteractiveViewer), findsNothing);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.text('预览失败：无法渲染'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);
    await tester.tap(find.text('重试预览'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(photos.previews.last.warmth, .35);
    await tester.pumpWidget(const SizedBox());
    camera.dispose();
  });

  testWidgets('photo AI analysis asks consent and flags stale adjustment', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final camera = CameraController(EmptyCamera());
    await camera.initialize();
    final photos = FakePhotos();
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoEditorPage(
          path: '/app/Documents/Captures/a.jpg',
          controller: camera,
          repository: photos,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('分析这张照片'));
    await tester.tap(find.text('分析这张照片'));
    await tester.pumpAndSettle();
    expect(photos.analyses, isEmpty);
    await tester.tap(find.text('确认分析'));
    await tester.pumpAndSettle();
    expect(photos.analyses.single, const PhotoRecipe());
    expect(find.text('曝光均匀'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('应用 AI 调色'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('应用 AI 调色'));
    await tester.pumpAndSettle();
    expect(photos.previews.last.exposure, 0);
    await tester.tap(find.text('确认应用'));
    await tester.pumpAndSettle();
    expect(photos.previews.last.exposure, .25);
    await tester.tap(find.byTooltip('撤销上一步'));
    await tester.pumpAndSettle();
    expect(photos.previews.last, const PhotoRecipe());
    await tester.scrollUntilVisible(
      find.text('黑白'),
      -250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('黑白'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('以下建议基于之前的调整版本。'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.scrollUntilVisible(
      find.text('应用 AI 调色'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('以下建议基于之前的调整版本。'), findsOneWidget);
    final stale = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '应用 AI 调色'),
    );
    expect(stale.onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    camera.dispose();
  });

  testWidgets('preview requests coalesce while a prior render is running', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final camera = CameraController(EmptyCamera());
    await camera.initialize();
    final photos = FakePhotos()..firstPreview = Completer<Uint8List>();
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoEditorPage(
          path: '/app/Documents/Captures/a.jpg',
          controller: camera,
          repository: photos,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(photos.previews.length, 1);
    await tester.tap(find.text('黑白'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('暖调'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(photos.previews.length, 1);
    photos.firstPreview!.complete(photos.png);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(photos.previews.length, 2);
    expect(photos.previews.last.warmth, .35);
    await tester.pumpWidget(const SizedBox());
    camera.dispose();
  });
}
