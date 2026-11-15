import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/camera/camera_bridge.dart';
import 'core/camera/camera_controller.dart';
import 'features/shooting/shooting_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CanonEOSLinkApp());
}

class CanonEOSLinkApp extends StatelessWidget {
  const CanonEOSLinkApp({super.key, this.repository});
  final CameraRepository? repository;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Canon EOS Link',
    debugShowCheckedModeBanner: false,
    builder: (context, child) => DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xffe6f0f7), Color(0xffd5e3f0), Color(0xffeff2f4)],
        ),
      ),
      child: child,
    ),
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: const Color(0xff397bc3),
            brightness: Brightness.light,
          ).copyWith(
            surface: const Color(0xfff5f8fb),
            primary: const Color(0xff2869af),
            onPrimary: Colors.white,
          ),
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: Color(0xff192938),
        surfaceTintColor: Colors.transparent,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xaaffffff),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xccffffff)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          side: const BorderSide(color: Color(0x55768fa8)),
        ),
      ),
    ),
    home: ShootingPage(
      controller: CameraController(repository ?? NativeCameraRepository()),
    ),
  );
}
