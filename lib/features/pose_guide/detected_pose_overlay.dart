import 'package:flutter/material.dart';

import 'pose_matcher.dart';

class DetectedPoseOverlay extends StatelessWidget {
  const DetectedPoseOverlay({super.key, required this.tracking});
  final PoseTrackingSnapshot tracking;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: CustomPaint(
      painter: _DetectedPainter(tracking.points),
      child: const SizedBox.expand(),
    ),
  );
}

class _DetectedPainter extends CustomPainter {
  _DetectedPainter(this.points);
  final Map<String, Offset> points;
  static const segments = [
    ['leftShoulder', 'rightShoulder'],
    ['leftShoulder', 'leftElbow'],
    ['leftElbow', 'leftWrist'],
    ['rightShoulder', 'rightElbow'],
    ['rightElbow', 'rightWrist'],
    ['leftShoulder', 'leftHip'],
    ['rightShoulder', 'rightHip'],
    ['leftHip', 'rightHip'],
    ['leftHip', 'leftKnee'],
    ['leftKnee', 'leftAnkle'],
    ['rightHip', 'rightKnee'],
    ['rightKnee', 'rightAnkle'],
  ];
  @override
  void paint(Canvas canvas, Size size) {
    Offset position(Offset p) => Offset(p.dx * size.width, p.dy * size.height);
    final stroke = Paint()
      ..color = const Color(0xff70d7c3)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final segment in segments) {
      final a = points[segment[0]], b = points[segment[1]];
      if (a != null && b != null) {
        canvas.drawLine(position(a), position(b), stroke);
      }
    }
    final fill = Paint()..color = const Color(0xff70d7c3);
    for (final point in points.values) {
      canvas.drawCircle(position(point), 3, fill);
    }
  }

  @override
  bool shouldRepaint(covariant _DetectedPainter oldDelegate) =>
      oldDelegate.points != points;
}
