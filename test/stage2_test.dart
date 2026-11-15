import 'dart:async';

import 'package:canon_eos_link/core/camera/camera_bridge.dart';
import 'package:canon_eos_link/core/camera/camera_controller.dart';
import 'package:canon_eos_link/features/ai_guidance/ai_panel.dart';
import 'package:canon_eos_link/features/shooting/shooting_page.dart';
import 'package:canon_eos_link/features/shooting/widgets/exposure_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class StageTwoRepository implements CameraRepository {
  final updates = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final calls = <(String, Map<String, dynamic>?)>[];
  Map<String, dynamic> state = {};
  Completer<void>? analysis;
  @override
  Stream<Map<String, dynamic>> get events => updates.stream;
  @override
  Future<Map<String, dynamic>> getState() async => state;
  @override
  Future<void> command(String method, [Map<String, dynamic>? arguments]) async {
    calls.add((method, arguments));
    if (method == 'analyzeFrame') await analysis?.future;
  }

  @override
  Future<String> diagnostics() async => '';
}

Map<String, dynamic> get exposure => {
  'revision': 4,
  'verified': true,
  'mode': 'M',
  'fields': [
    {
      'id': 'iso',
      'title': 'ISO',
      'label': '400',
      'raw': 88,
      'writable': true,
      'options': [
        {'raw': 88, 'label': '400'},
        {'raw': 96, 'label': '800'},
      ],
    },
    {
      'id': 'aperture',
      'title': '光圈',
      'label': 'f/5.6',
      'raw': 48,
      'writable': false,
      'options': [],
    },
  ],
};

void main() {
  testWidgets('AI pose suggestions open only known local references', (
    tester,
  ) async {
    final repository = StageTwoRepository()
      ..state = {
        'state': 'liveview_running',
        'aiConfig': {'hasKey': true},
        'guidance': {
          'summary': '适合人像',
          'composition': <String>[],
          'suggestions': <Object>[],
          'poseRecommendations': [
            {'id': 'photo_pair_park', 'reason': '适合双人'},
            {'id': 'unknown', 'reason': '无效'},
            {'id': 'photo_pair_park', 'reason': '重复'},
          ],
        },
      };
    final controller = CameraController(repository);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AIPanel(controller: controller)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('双人并肩'), findsOneWidget);
    expect(find.text('无效'), findsNothing);
    expect(find.text('重复'), findsNothing);
    await tester.ensureVisible(find.text('双人并肩'));
    await tester.tap(find.text('双人并肩'));
    await tester.pumpAndSettle();
    expect(find.text('摄影：Polina Tankilevitch · Pexels'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await repository.updates.close();
  });
  test('AI analysis does not block an independent camera command', () async {
    final repository = StageTwoRepository()
      ..state = {'state': 'liveview_running'}
      ..analysis = Completer<void>();
    final controller = CameraController(repository);
    await controller.initialize();
    final analyzing = controller.run('analyzeFrame');
    expect(controller.aiBusy, isTrue);
    expect(controller.busy, isFalse);
    expect(await controller.run('capture'), isTrue);
    expect(repository.calls.map((c) => c.$1), ['analyzeFrame', 'capture']);
    repository.analysis!.complete();
    await analyzing;
    controller.dispose();
    await repository.updates.close();
  });

  testWidgets(
    'manual exposure choice requires confirmation and carries revision',
    (tester) async {
      final repository = StageTwoRepository()
        ..state = {'state': 'ready', 'exposure': exposure};
      final controller = CameraController(repository);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ExposurePanel(controller: controller)),
        ),
      );
      await tester.tap(find.text('ISO  400'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('800'));
      await tester.pumpAndSettle();
      expect(repository.calls, isEmpty);
      await tester.tap(find.text('确认修改'));
      await tester.pumpAndSettle();
      expect(repository.calls.single.$1, 'setExposure');
      expect(repository.calls.single.$2, {
        'property': 'iso',
        'value': 96,
        'revision': 4,
      });
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await repository.updates.close();
    },
  );

  testWidgets(
    'AI request requires consent and suggested writes require another confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = StageTwoRepository()
        ..state = {
          'state': 'liveview_running',
          'aiConfig': {'hasKey': true},
          'exposure': exposure,
          'guidance': {
            'summary': '可改善',
            'composition': ['注意背景'],
            'confidence': 0.8,
            'suggestions': [
              {
                'title': 'ISO',
                'property': 'iso',
                'label': '800',
                'raw': 96,
                'revision': 4,
                'reason': '减少抖动',
                'applicable': true,
              },
            ],
          },
        };
      final controller = CameraController(repository);
      await controller.initialize();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: AIPanel(controller: controller)),
          ),
        ),
      );
      await tester.tap(find.text('分析当前画面'));
      await tester.pumpAndSettle();
      expect(repository.calls, isEmpty);
      await tester.tap(find.text('确认分析'));
      await tester.pumpAndSettle();
      expect(repository.calls.single.$1, 'analyzeFrame');
      await tester.tap(find.text('应用'));
      await tester.pumpAndSettle();
      expect(repository.calls.length, 1);
      await tester.tap(find.text('确认应用'));
      await tester.pumpAndSettle();
      expect(repository.calls.last.$1, 'setExposure');
      expect(repository.calls.last.$2, {
        'property': 'iso',
        'value': 96,
        'revision': 4,
      });
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await repository.updates.close();
    },
  );

  testWidgets('stale AI recommendation cannot be applied', (tester) async {
    final repository = StageTwoRepository()
      ..state = {
        'state': 'ready',
        'exposure': exposure,
        'guidance': {
          'summary': '建议',
          'composition': <String>[],
          'confidence': 0.8,
          'suggestions': [
            {
              'title': 'ISO',
              'property': 'iso',
              'label': '800',
              'raw': 96,
              'revision': 3,
              'reason': 'x',
              'applicable': true,
            },
          ],
        },
      };
    final controller = CameraController(repository);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: AIPanel(controller: controller)),
        ),
      ),
    );
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '应用'),
    );
    expect(button.onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await repository.updates.close();
  });

  testWidgets('AI settings validates URL before storing key', (tester) async {
    final repository = StageTwoRepository();
    final controller = CameraController(repository);
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(home: AISettingsPage(controller: controller)),
    );
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'http://example.test/v1/chat/completions',
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'vision');
    await tester.enterText(find.byType(TextFormField).at(2), 'key');
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 HTTPS 的 /chat/completions 完整地址'), findsOneWidget);
    expect(repository.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    await repository.updates.close();
  });

  testWidgets('half-press autofocus triggers command and histogram shows clipping', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = StageTwoRepository()
      ..state = {
        'state': 'liveview_running',
        'textureId': 7,
        'width': 960,
        'height': 640,
        'histogram': List<double>.filled(16, 0.5),
        'highlightClipped': true,
      };
    final controller = CameraController(repository);
    await tester.pumpWidget(
      MaterialApp(home: ShootingPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('高光溢出'), findsOneWidget);
    await tester.tap(find.text('半按对焦'));
    await tester.pumpAndSettle();
    expect(repository.calls.single.$1, 'autofocus');
    await tester.pumpWidget(const SizedBox());
    await repository.updates.close();
  });
}
