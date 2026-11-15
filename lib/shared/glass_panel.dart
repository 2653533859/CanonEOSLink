import 'dart:ui';

import 'package:flutter/material.dart';

/// A restrained translucent surface for secondary controls over the viewfinder UI.
class GlassPanel extends StatelessWidget {
  const GlassPanel({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(20),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0x99ffffff),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: .8)),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ),
      ),
    ),
  );
}
