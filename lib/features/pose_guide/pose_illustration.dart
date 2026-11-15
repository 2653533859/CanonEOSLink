import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'pose_reference.dart';

class PoseIllustration extends StatelessWidget {
  const PoseIllustration({
    super.key,
    required this.pose,
    this.overlay = false,
    this.mirror = false,
    this.opacity = .65,
  });
  final PoseReference pose;
  final bool overlay, mirror;
  final double opacity;
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _PosePainter(
      pose,
      overlay: overlay,
      mirror: mirror,
      opacity: opacity,
    ),
    child: const SizedBox.expand(),
  );
}

class _PosePainter extends CustomPainter {
  _PosePainter(
    this.pose, {
    required this.overlay,
    required this.mirror,
    required this.opacity,
  });
  final PoseReference pose;
  final bool overlay, mirror;
  final double opacity;
  @override
  void paint(Canvas canvas, Size size) {
    if (!overlay) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xffdce9f2),
      );
      final grid = Paint()
        ..color = const Color(0xffc1d3e0)
        ..strokeWidth = 1;
      for (var i = 1; i < 3; i++) {
        canvas.drawLine(
          Offset(size.width * i / 3, 0),
          Offset(size.width * i / 3, size.height),
          grid,
        );
        canvas.drawLine(
          Offset(0, size.height * i / 3),
          Offset(size.width, size.height * i / 3),
          grid,
        );
      }
    }
    final visibleFraction = pose.framing == '半身' ? .62 : 1.0;
    final height = size.height * .94 / visibleFraction;
    final width = math.min(size.width * .92, height * .68);
    final origin = Offset(
      (size.width - width) / 2,
      (size.height - height * visibleFraction) / 2,
    );
    Offset point(int index) {
      final p = pose.joints[index];
      return origin + Offset((mirror ? 1 - p.dx : p.dx) * width, p.dy * height);
    }

    final color = (overlay ? Colors.white : const Color(0xff365c7b)).withValues(
      alpha: opacity.clamp(0, 1),
    );
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, width * .022)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final faint = Paint()
      ..color = color.withValues(alpha: color.a * .20)
      ..style = PaintingStyle.fill;
    final torso = Path()
      ..moveTo(point(2).dx, point(2).dy)
      ..lineTo(point(3).dx, point(3).dy)
      ..lineTo(point(9).dx, point(9).dy)
      ..lineTo(point(8).dx, point(8).dy)
      ..close();
    canvas.drawPath(torso, faint);
    canvas.drawPath(torso, stroke);
    for (final pair in const [
      [1, 2],
      [1, 3],
      [2, 4],
      [4, 5],
      [3, 6],
      [6, 7],
      [8, 10],
      [10, 11],
      [9, 12],
      [12, 13],
    ]) {
      canvas.drawLine(point(pair[0]), point(pair[1]), stroke);
    }
    canvas.drawOval(
      Rect.fromCenter(
        center: point(0),
        width: width * .15,
        height: height * .12,
      ),
      stroke,
    );
    for (final i in const [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]) {
      canvas.drawCircle(
        point(i),
        math.max(2, width * .015),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PosePainter old) =>
      old.pose.id != pose.id ||
      old.overlay != overlay ||
      old.mirror != mirror ||
      old.opacity != opacity;
}
