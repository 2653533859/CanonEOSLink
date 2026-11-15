import 'dart:async';
import 'dart:math' as math;

import 'package:canon_eos_link/core/camera/camera_bridge.dart';
import 'package:canon_eos_link/core/camera/camera_controller.dart';
import 'package:canon_eos_link/features/pose_guide/detected_pose_overlay.dart';
import 'package:canon_eos_link/features/pose_guide/pose_matcher.dart';
import 'package:canon_eos_link/features/pose_guide/pose_reference.dart';
import 'package:canon_eos_link/features/shooting/shooting_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Offset> referencePoints(
  PoseReference pose, {
  double aspect = 1.5,
  bool mirrored = false,
  double scale = 1,
}) {
  final fraction = pose.framing == '半身' ? .62 : 1.0;
  final height = .94 / fraction;
  final width = math.min(aspect * .92, height * .68);
  Offset point(int index) {
    final p = pose.joints[index];
    final x = .5 + ((mirrored ? 1 - p.dx : p.dx) - .5) * width / aspect;
    final y = (1 - height * fraction) / 2 + p.dy * height;
    return Offset(.5 + (x - .5) * scale, .5 + (y - .5) * scale);
  }

  return {
    'leftShoulder': point(2),
    'rightShoulder': point(3),
    'leftElbow': point(4),
    'leftWrist': point(5),
    'rightElbow': point(6),
    'rightWrist': point(7),
    'leftHip': point(8),
    'rightHip': point(9),
    if (pose.framing == '全身') ...{
      'leftKnee': point(10),
      'leftAnkle': point(11),
      'rightKnee': point(12),
      'rightAnkle': point(13),
    },
  };
}

Map<String, dynamic> trackingData(
  Map<String, Offset> points, {
  String status = 'detected',
  bool enabled = true,
}) => {
  'enabled': enabled,
  'status': status,
  'points': points.entries
      .map(
        (e) => {
          'name': e.key,
          'x': e.value.dx,
          'y': e.value.dy,
          'confidence': .9,
        },
      )
      .toList(),
};

class TrackingCamera implements CameraRepository {
  final changes = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final commands = <(String, Map<String, dynamic>?)>[];
  Map<String, dynamic> pose = {
    'enabled': false,
    'status': 'off',
    'points': <dynamic>[],
  };
  Map<String, dynamic> get snapshot => {
    'state': 'liveview_running',
    'textureId': 42,
    'width': 960,
    'height': 640,
    'poseTracking': pose,
  };
  @override
  Stream<Map<String, dynamic>> get events => changes.stream;
  @override
  Future<Map<String, dynamic>> getState() async => snapshot;
  @override
  Future<void> command(String method, [Map<String, dynamic>? args]) async {
    commands.add((method, args));
    if (method == 'setPoseTracking') {
      final enabled = args?['enabled'] == true;
      pose = {
        'enabled': enabled,
        'status': enabled ? 'waiting' : 'off',
        'points': <dynamic>[],
      };
      changes.add(snapshot);
    }
  }

  void emit(Map<String, dynamic> value) {
    pose = value;
    changes.add(snapshot);
  }

  @override
  Future<String> diagnostics() async => '';
}

void main() {
  test('native points require valid finite coordinates and confidence', () {
    final parsed = PoseTrackingSnapshot.fromMap({
      'enabled': true,
      'status': 'detected',
      'points': [
        {'name': 'good', 'x': .2, 'y': .3, 'confidence': .9},
        {'name': 'low', 'x': .3, 'y': .5, 'confidence': .2},
        {'name': 'bad', 'x': double.nan, 'y': .5, 'confidence': .9},
        {'name': 'outside', 'x': 1.2, 'y': .5, 'confidence': .9},
      ],
    });
    expect(parsed.points, {'good': const Offset(.2, .3)});
    final disabled = PoseTrackingSnapshot.fromMap(
      trackingData({'leftWrist': const Offset(.1, .2)}, enabled: false),
    );
    expect(disabled.points, isEmpty);
  });

  test(
    'matching is consistent with reference, mirror, scale and image aspect',
    () {
      for (final pose in poseReferences) {
        for (final mirror in [false, true]) {
          for (final aspect in [1.5, .67]) {
            final data = trackingData(
              referencePoints(
                pose,
                aspect: aspect,
                mirrored: mirror,
                scale: .75,
              ),
            );
            final result = PoseMatcher.match(
              pose,
              PoseTrackingSnapshot.fromMap(data),
              imageAspect: aspect,
              mirrored: mirror,
            );
            expect(
              result.complete,
              isTrue,
              reason: '${pose.id} mirror=$mirror aspect=$aspect',
            );
            expect(
              result.title,
              '关键点轮廓接近参考',
              reason:
                  '${pose.id} mirror=$mirror aspect=$aspect ${result.hints}',
            );
          }
        }
      }
    },
  );

  test('missing or ambiguous people never claim a complete match', () {
    final pose = poseReferences.first;
    final points = referencePoints(pose)..remove('leftWrist');
    final partial = PoseMatcher.match(
      pose,
      PoseTrackingSnapshot.fromMap(trackingData(points)),
      imageAspect: 1.5,
    );
    expect(partial.complete, isFalse);
    expect(partial.title, '部分关键点可见');
    for (final status in [
      'multiple',
      'noPerson',
      'tooFar',
      'partial',
      'waiting',
      'error',
    ]) {
      final result = PoseMatcher.match(
        pose,
        PoseTrackingSnapshot.fromMap(
          trackingData(referencePoints(pose), status: status),
        ),
        imageAspect: 1.5,
      );
      expect(result.complete, isFalse, reason: status);
      expect(result.title, isNot('关键点轮廓接近参考'));
    }
  });

  test(
    'different arm position produces guidance instead of claiming match',
    () {
      final pose = poseReferences.first;
      final points = referencePoints(pose);
      final shoulder = points['leftShoulder']!;
      points['leftWrist'] = shoulder + const Offset(-.15, -.15);
      final result = PoseMatcher.match(
        pose,
        PoseTrackingSnapshot.fromMap(trackingData(points)),
        imageAspect: 1.5,
      );
      expect(result.title, '可参考轮廓微调');
      expect(result.hints.any((text) => text.contains('手臂')), isTrue);
    },
  );

  testWidgets(
    'tracking is opt-in, displays local result, and stops when reference is removed',
    (tester) async {
      tester.view.physicalSize = const Size(500, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = TrackingCamera();
      final controller = CameraController(repository);
      await tester.pumpWidget(
        MaterialApp(home: ShootingPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(repository.commands, isEmpty);
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
        find.text('本机姿态识别'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('本机姿态识别'));
      await tester.pumpAndSettle();
      expect(repository.commands.single.$1, 'setPoseTracking');
      expect(repository.commands.single.$2, {'enabled': true});
      expect(find.text('等待识别画面'), findsOneWidget);
      repository.emit(trackingData(referencePoints(poseReferences.first)));
      await tester.pumpAndSettle();
      expect(find.text('关键点轮廓接近参考'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byType(Texture),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byType(DetectedPoseOverlay), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byTooltip('移除姿势参考'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byTooltip('移除姿势参考'));
      await tester.pumpAndSettle();
      expect(repository.commands.last.$2, {'enabled': false});
      expect(find.byType(DetectedPoseOverlay), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await repository.changes.close();
    },
  );
}
