import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/camera/camera_controller.dart';
import '../photo_editor/photo_editor_page.dart';

typedef CapturePageLoader = Future<Map<String, dynamic>> Function(
  String? before,
);

Future<Map<String, dynamic>> loadCapturePage(String? before) async {
  const channel = MethodChannel('com.parado.canoneos/control');
  final result = await channel.invokeMapMethod<String, dynamic>(
    'listCaptures',
    {'before': ?before},
  );
  if (result == null) throw const FormatException('照片列表为空响应');
  return result;
}

class CaptureGallery extends StatefulWidget {
  const CaptureGallery({
    super.key,
    required this.controller,
    this.loader = loadCapturePage,
  });
  final CameraController controller;
  final CapturePageLoader loader;

  @override
  State<CaptureGallery> createState() => _CaptureGalleryState();
}

class _CaptureGalleryState extends State<CaptureGallery> {
  final items = <Map<String, dynamic>>[];
  String? cursor, error;
  bool loading = false, initial = true;
  bool failedRefresh = false;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    if (loading) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.loader(refresh ? null : cursor);
      final next = (page['items'] as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      final nextCursor = page['nextCursor'] as String?;
      if (!mounted) return;
      setState(() {
        if (refresh) items.clear();
        items.addAll(next);
        cursor = nextCursor;
        initial = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          failedRefresh = refresh;
          error = e is PlatformException ? (e.message ?? e.code) : e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          TextButton.icon(
            onPressed: loading ? null : () => _load(refresh: true),
            icon: const Icon(Icons.refresh),
            label: const Text('刷新照片'),
          ),
          if (loading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      if (error != null)
        Row(
          children: [
            Expanded(child: Text('加载失败：$error')),
            TextButton(
              onPressed: loading
                  ? null
                  : () => _load(refresh: initial || failedRefresh),
              child: const Text('重试'),
            ),
          ],
        ),
      Expanded(
        child: items.isEmpty
            ? Center(
                child: Text(
                  loading
                      ? '正在加载照片…'
                      : error != null
                      ? '无法读取照片列表'
                      : '还没有照片。连接相机并拍摄第一张 JPEG。',
                ),
              )
            : GridView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: items.length,
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemBuilder: (context, index) {
                  final path = items[index]['path'] as String;
                  return InkWell(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PhotoEditorPage(
                          path: path,
                          controller: widget.controller,
                        ),
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        cacheWidth: 400,
                        errorBuilder: (_, _, _) => const Center(
                          child: Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
      if (cursor != null)
        TextButton(
          onPressed: loading ? null : () => _load(),
          child: const Text('加载更多'),
        ),
    ],
  );
}
