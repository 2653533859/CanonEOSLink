import 'dart:math' as math;
import 'dart:ui';

import 'pose_reference.dart';

class PoseTrackingSnapshot {
  const PoseTrackingSnapshot({
    this.enabled = false,
    this.status = 'off',
    this.points = const {},
  });
  factory PoseTrackingSnapshot.fromMap(Map<String, dynamic> map) {
    final enabled = map['enabled'] == true;
    final status = map['status'] as String? ?? 'off';
    final points = <String, Offset>{};
    if (enabled && status == 'detected') {
      for (final item in map['points'] as List? ?? []) {
        if (item is! Map) continue;
        final name = item['name'];
        final x = item['x'];
        final y = item['y'];
        final confidence = item['confidence'];
        if (name is String &&
            x is num &&
            y is num &&
            confidence is num &&
            x.isFinite &&
            y.isFinite &&
            confidence.isFinite &&
            x >= 0 &&
            x <= 1 &&
            y >= 0 &&
            y <= 1 &&
            confidence >= .35 &&
            confidence <= 1) {
          points[name] = Offset(x.toDouble(), y.toDouble());
        }
      }
    }
    return PoseTrackingSnapshot(
      enabled: enabled,
      status: status,
      points: points,
    );
  }
  final bool enabled;
  final String status;

  /// Top-left origin, normalized to the displayed, untransformed JPEG.
  final Map<String, Offset> points;
}

class PoseMatchResult {
  const PoseMatchResult(this.title, this.hints, {this.complete = false});
  final String title;
  final List<String> hints;
  final bool complete;
}

class _Side {
  const _Side(
    this.shoulder,
    this.elbow,
    this.wrist,
    this.hip,
    this.knee,
    this.ankle,
  );
  final Offset? shoulder, elbow, wrist, hip, knee, ankle;
}

/// Compares visible 2D joint angles and limb directions, not identity, facial
/// expression, depth or photographic quality. It never changes the camera.
class PoseMatcher {
  static PoseMatchResult match(
    PoseReference reference,
    PoseTrackingSnapshot tracking, {
    required double imageAspect,
    bool mirrored = false,
  }) {
    if (!tracking.enabled) return const PoseMatchResult('姿态识别已关闭', []);
    switch (tracking.status) {
      case 'waiting':
        return const PoseMatchResult('等待识别画面', ['请保持取景并让人物进入画面。']);
      case 'noPerson':
        return const PoseMatchResult('未识别到人物', ['请让单人主体进入画面，并保持足够光线。']);
      case 'multiple':
        return const PoseMatchResult('画面中有多个人', ['请让一位主体单独进入画面。']);
      case 'tooFar':
        return const PoseMatchResult('人物在画面中较小', ['可适当靠近或调整构图，让人物更清晰。']);
      case 'partial':
        return const PoseMatchResult('关键点不足', ['请减少遮挡，让肩膀和手臂清晰可见。']);
      case 'error':
        return const PoseMatchResult('本机识别暂不可用', ['请关闭后重试；静态姿势参考仍可使用。']);
      case 'detected':
        break;
      default:
        return const PoseMatchResult('等待识别画面', []);
    }
    if (!imageAspect.isFinite ||
        imageAspect <= 0 ||
        reference.joints.length != 14) {
      return const PoseMatchResult('参考数据不可用', []);
    }
    final p = tracking.points;
    Offset? actual(String name) {
      final point = p[name];
      return point == null ? null : Offset(point.dx * imageAspect, point.dy);
    }

    final observed = [
      _Side(
        actual('leftShoulder'),
        actual('leftElbow'),
        actual('leftWrist'),
        actual('leftHip'),
        actual('leftKnee'),
        actual('leftAnkle'),
      ),
      _Side(
        actual('rightShoulder'),
        actual('rightElbow'),
        actual('rightWrist'),
        actual('rightHip'),
        actual('rightKnee'),
        actual('rightAnkle'),
      ),
    ];
    if (observed.any((side) => side.shoulder == null || side.hip == null)) {
      return const PoseMatchResult('身体部分可见', ['请让双肩与髋部进入画面后再比较。']);
    }
    if ((observed[0].shoulder!.dx - observed[1].shoulder!.dx).abs() < .015) {
      return const PoseMatchResult('双肩重叠', ['请略微调整角度，让双肩更容易辨认。']);
    }
    observed.sort((a, b) => a.shoulder!.dx.compareTo(b.shoulder!.dx));
    final fraction = reference.framing == '半身' ? .62 : 1.0;
    final figureHeight = .94 / fraction;
    final figureWidth = math.min(imageAspect * .92, figureHeight * .68);
    final referenceAspect = figureWidth / figureHeight;
    Offset ref(int i) {
      final point = reference.joints[i];
      return Offset(
        (mirrored ? 1 - point.dx : point.dx) * referenceAspect,
        point.dy,
      );
    }

    final target = [
      _Side(ref(2), ref(4), ref(5), ref(8), ref(10), ref(11)),
      _Side(ref(3), ref(6), ref(7), ref(9), ref(12), ref(13)),
    ]..sort((a, b) => a.shoulder!.dx.compareTo(b.shoulder!.dx));
    final body =
        _mid(observed[0].hip!, observed[1].hip!) -
        _mid(observed[0].shoulder!, observed[1].shoulder!);
    final targetBody =
        _mid(target[0].hip!, target[1].hip!) -
        _mid(target[0].shoulder!, target[1].shoulder!);
    if (body.distance < .05 || targetBody.distance < .05) {
      return const PoseMatchResult('身体关键点不足', ['请保持主体清晰，避免身体关键点被遮挡。']);
    }
    final hints = <String>[];
    var arms = 0, legs = 0;
    for (var index = 0; index < 2; index++) {
      final current = observed[index], expected = target[index];
      final side = index == 0 ? '画面左侧' : '画面右侧';
      if (current.elbow != null && current.wrist != null) {
        final jointDiff = _angleDifference(
          _jointAngle(current.shoulder!, current.elbow!, current.wrist!),
          _jointAngle(expected.shoulder!, expected.elbow!, expected.wrist!),
        );
        final directionDiff = _angleDifference(
          _relativeAngle(body, current.wrist! - current.shoulder!),
          _relativeAngle(targetBody, expected.wrist! - expected.shoulder!),
        );
        if (jointDiff != null && directionDiff != null) {
          arms++;
          if (jointDiff > 35 || directionDiff > 40) {
            hints.add('$side手臂与参考不同，可调整弯曲或抬起方向。');
          }
        }
      }
      if (reference.framing == '全身' &&
          current.knee != null &&
          current.ankle != null) {
        final jointDiff = _angleDifference(
          _jointAngle(current.hip!, current.knee!, current.ankle!),
          _jointAngle(expected.hip!, expected.knee!, expected.ankle!),
        );
        final directionDiff = _angleDifference(
          _relativeAngle(body, current.ankle! - current.hip!),
          _relativeAngle(targetBody, expected.ankle! - expected.hip!),
        );
        if (jointDiff != null && directionDiff != null) {
          legs++;
          if (jointDiff > 35 || directionDiff > 40) {
            hints.add('$side腿部与参考不同，可调整站位或弯曲角度。');
          }
        }
      }
    }
    if (arms == 0) return const PoseMatchResult('手臂关键点不足', ['请让至少一侧手臂完整可见。']);
    final complete = arms == 2 && (reference.framing != '全身' || legs == 2);
    if (!complete) {
      return PoseMatchResult('部分关键点可见', [
        ...hints.take(2),
        reference.framing == '全身' ? '请让双臂与双腿尽量完整入画。' : '请让双臂尽量完整入画。',
      ]);
    }
    if (hints.isEmpty) {
      return const PoseMatchResult('关键点轮廓接近参考', [
        '可继续微调表情、手指与机位。',
      ], complete: true);
    }
    return PoseMatchResult('可参考轮廓微调', hints.take(2).toList(), complete: true);
  }

  static Offset _mid(Offset a, Offset b) => (a + b) / 2;
  static double? _jointAngle(Offset a, Offset center, Offset b) =>
      _relativeAngle(a - center, b - center);
  static double? _relativeAngle(Offset a, Offset b) {
    if (a.distance < .005 || b.distance < .005) return null;
    return math.atan2(a.dx * b.dy - a.dy * b.dx, a.dx * b.dx + a.dy * b.dy) *
        180 /
        math.pi;
  }

  static double? _angleDifference(double? a, double? b) {
    if (a == null || b == null) return null;
    final delta = (a - b).abs() % 360;
    return math.min(delta, 360 - delta);
  }
}
