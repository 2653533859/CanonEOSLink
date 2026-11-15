import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/camera/camera_controller.dart';
import '../ai_guidance/ai_panel.dart';
import 'photo_repository.dart';

class PhotoEditorPage extends StatefulWidget {
  const PhotoEditorPage({
    super.key,
    required this.path,
    required this.controller,
    this.repository,
  });
  final String path;
  final CameraController controller;
  final PhotoRepository? repository;
  @override
  State<PhotoEditorPage> createState() => _PhotoEditorPageState();
}

class _PhotoEditorPageState extends State<PhotoEditorPage> {
  late final PhotoRepository repository;
  PhotoRecipe recipe = const PhotoRecipe();
  final history = <PhotoRecipe>[];
  PhotoRecipe? dragStart;
  PhotoRecipe? analyzedRecipe;
  Uint8List? preview;
  Map<String, dynamic>? analysis;
  String? error, exportedPath;
  bool loading = true,
      rendering = false,
      comparing = false,
      actionBusy = false,
      analyzing = false,
      preserveExif = false;
  Timer? debounce;
  int previewVersion = 0;
  bool previewInFlight = false;
  String? previewError;

  @override
  void initState() {
    super.initState();
    repository = widget.repository ?? NativePhotoRepository();
    _load();
  }

  @override
  void dispose() {
    debounce?.cancel();
    previewVersion++;
    super.dispose();
  }

  String _message(Object error) => switch (error) {
    PlatformException e => e.message ?? e.code,
    MissingPluginException() => '照片处理需要在 iOS 工程中运行。',
    _ => error.toString(),
  };
  Future<void> _load() async {
    try {
      final loaded = await repository.loadRecipe(widget.path);
      if (!mounted) return;
      setState(() {
        recipe = loaded;
        loading = false;
      });
      _schedulePreview(immediate: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '读取调整记录失败，已使用默认值：${_message(e)}';
          loading = false;
        });
        _schedulePreview(immediate: true);
      }
    }
  }

  void _schedulePreview({bool immediate = false}) {
    debounce?.cancel();
    previewVersion++;
    setState(() {
      rendering = true;
      previewError = null;
    });
    debounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 160),
      _pumpPreview,
    );
  }

  Future<void> _pumpPreview() async {
    if (!mounted || previewInFlight) return;
    debounce?.cancel();
    debounce = null;
    previewInFlight = true;
    final version = previewVersion;
    final target = comparing ? const PhotoRecipe() : recipe;
    try {
      final bytes = await repository.preview(widget.path, target);
      if (mounted && version == previewVersion) {
        setState(() {
          preview = bytes;
          rendering = false;
          previewError = null;
        });
      }
    } catch (e) {
      if (mounted && version == previewVersion) {
        setState(() {
          rendering = false;
          preview = null;
          previewError = _message(e);
        });
      }
    } finally {
      previewInFlight = false;
      if (mounted && version != previewVersion) _pumpPreview();
    }
  }

  void _remember(PhotoRecipe previous) {
    if (previous == recipe) return;
    history.add(previous);
    if (history.length > 30) history.removeAt(0);
  }

  void _applyRecipe(PhotoRecipe next) {
    if (next == recipe) return;
    final previous = recipe;
    setState(() {
      recipe = next;
      _remember(previous);
      comparing = false;
      error = null;
    });
    _schedulePreview();
  }

  void _change(PhotoRecipe next) {
    dragStart ??= recipe;
    setState(() {
      recipe = next;
    });
    _schedulePreview();
  }

  void _endChange(double _) {
    if (dragStart != null) {
      setState(() {
        _remember(dragStart!);
        dragStart = null;
      });
    }
  }

  void _undo() {
    if (history.isEmpty) return;
    setState(() {
      recipe = history.removeLast();
      comparing = false;
    });
    _schedulePreview();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('照片编辑'),
      actions: [
        IconButton(
          tooltip: '撤销上一步',
          onPressed: history.isEmpty || actionBusy ? null : _undo,
          icon: const Icon(Icons.undo),
        ),
      ],
    ),
    body: SafeArea(
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(
              builder: (context, constraints) {
                final imageHeight = constraints.maxWidth > 700 ? 360.0 : 300.0;
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                    Container(
                      height: imageHeight,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (preview != null && !rendering)
                            InteractiveViewer(
                              child: Image.memory(
                                preview!,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                              ),
                            )
                          else if (previewError != null)
                            Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '预览失败：$previewError',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        _schedulePreview(immediate: true),
                                    child: const Text('重试预览'),
                                  ),
                                ],
                              ),
                            )
                          else if (!rendering)
                            const Center(
                              child: Icon(
                                Icons.image_outlined,
                                color: Colors.white38,
                                size: 40,
                              ),
                            ),
                          if (rendering)
                            const Positioned(
                              top: 12,
                              right: 12,
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          Positioned(
                            left: 12,
                            top: 12,
                            child: Text(
                              comparing ? '原片' : '调整预览',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('查看原片'),
                      subtitle: comparing ? const Text('导出仍使用调整后的结果') : null,
                      value: comparing,
                      onChanged: actionBusy
                          ? null
                          : (value) {
                              setState(() {
                                comparing = value;
                                preview = null;
                              });
                              _schedulePreview(immediate: true);
                            },
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ActionChip(
                          label: const Text('自动优化'),
                          onPressed: actionBusy ? null : _auto,
                        ),
                        ActionChip(
                          label: const Text('自然'),
                          onPressed: actionBusy
                              ? null
                              : () => _applyRecipe(
                                  const PhotoRecipe(
                                    exposure: .15,
                                    contrast: 1.04,
                                    saturation: 1.03,
                                  ),
                                ),
                        ),
                        ActionChip(
                          label: const Text('暖调'),
                          onPressed: actionBusy
                              ? null
                              : () => _applyRecipe(
                                  const PhotoRecipe(
                                    exposure: .1,
                                    contrast: 1.04,
                                    saturation: 1.04,
                                    warmth: .35,
                                  ),
                                ),
                        ),
                        ActionChip(
                          label: const Text('黑白'),
                          onPressed: actionBusy
                              ? null
                              : () => _applyRecipe(
                                  const PhotoRecipe(
                                    contrast: 1.1,
                                    saturation: 0,
                                  ),
                                ),
                        ),
                        ActionChip(
                          label: const Text('还原'),
                          onPressed: actionBusy
                              ? null
                              : () => _applyRecipe(const PhotoRecipe()),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _slider(
                      '曝光',
                      recipe.exposure,
                      -2,
                      2,
                      (v) => recipe.copyWith(exposure: v),
                      suffix: ' EV',
                    ),
                    _slider(
                      '对比度',
                      recipe.contrast,
                      .5,
                      1.5,
                      (v) => recipe.copyWith(contrast: v),
                    ),
                    _slider(
                      '饱和度',
                      recipe.saturation,
                      0,
                      2,
                      (v) => recipe.copyWith(saturation: v),
                    ),
                    _slider(
                      '冷暖',
                      recipe.warmth,
                      -1,
                      1,
                      (v) => recipe.copyWith(warmth: v),
                    ),
                    _slider(
                      '高光',
                      recipe.highlights,
                      -1,
                      1,
                      (v) => recipe.copyWith(highlights: v),
                    ),
                    _slider(
                      '阴影',
                      recipe.shadows,
                      -1,
                      1,
                      (v) => recipe.copyWith(shadows: v),
                    ),
                    const Text(
                      '自动优化依据画面平均亮度计算，不识别场景；原片不会被修改。',
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: actionBusy ? null : _save,
                            icon: const Icon(Icons.save_outlined),
                            label: const Text('保存调整'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: actionBusy ? null : _export,
                            icon: const Icon(Icons.ios_share),
                            label: const Text('导出 JPEG'),
                          ),
                        ),
                      ],
                    ),
                    if (exportedPath != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '已导出至“文件”App 的 EOS Link / Exports。',
                              style: TextStyle(
                                color: Colors.black87,
                                fontSize: 12,
                              ),
                            ),
                            TextButton.icon(
                              onPressed: actionBusy ? null : _saveToPhotos,
                              icon: const Icon(Icons.photo_library_outlined),
                              label: const Text('将上次导出保存到相册'),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('保留拍摄参数 EXIF'),
                      subtitle: const Text(
                        '导出时保留快门、光圈、ISO、焦距，剥离 GPS 与序列号',
                        style: TextStyle(fontSize: 12),
                      ),
                      value: preserveExif,
                      onChanged: actionBusy
                          ? null
                          : (value) => setState(() => preserveExif = value),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '导出会生成独立 JPEG；色彩按 sRGB 输出，默认不保留原片 EXIF/GPS。',
                      style: TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                    const Divider(height: 32),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'AI 照片分析',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          tooltip: 'AI 服务设置',
                          onPressed: analyzing
                              ? null
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => AISettingsPage(
                                      controller: widget.controller,
                                    ),
                                  ),
                                ),
                          icon: const Icon(Icons.settings_outlined),
                        ),
                      ],
                    ),
                    AnimatedBuilder(
                      animation: widget.controller,
                      builder: (context, _) {
                        final configured =
                            widget.controller.snapshot.aiConfig['hasKey'] ==
                            true;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              !configured
                                  ? '请先配置 AI 服务。'
                                  : comparing
                                  ? '请先关闭原片对比，再分析调整后的预览。'
                                  : '分析当前调整后的照片预览。',
                              style: const TextStyle(
                                color: Colors.black54,
                                fontSize: 12,
                              ),
                            ),
                            TextButton.icon(
                              onPressed:
                                  configured &&
                                      !analyzing &&
                                      !actionBusy &&
                                      !comparing
                                  ? _analyze
                                  : null,
                              icon: analyzing
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.image_search_outlined),
                              label: Text(analyzing ? '正在分析' : '分析这张照片'),
                            ),
                          ],
                        );
                      },
                    ),
                    if (analysis != null) ...[
                      if (analyzedRecipe != recipe)
                        const Text(
                          '以下建议基于之前的调整版本。',
                          style: TextStyle(color: Colors.black54, fontSize: 12),
                        ),
                      Text(
                        analysis!['summary'] as String? ?? '',
                        style: const TextStyle(height: 1.5),
                      ),
                      for (final line in List<String>.from(
                        analysis!['composition'] as List? ?? [],
                      ))
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '• $line',
                            style: const TextStyle(color: Colors.black87),
                          ),
                        ),
                      if (analysis!['confidence'] is num)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '模型置信度 ${(analysis!['confidence'] as num).toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.black54,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      if (analysis!['recipe'] is Map)
                        TextButton.icon(
                          onPressed:
                              analysis!['applicable'] == true &&
                                  analyzedRecipe == recipe &&
                                  !actionBusy &&
                                  !analyzing
                              ? _applyAI
                              : null,
                          icon: const Icon(Icons.tune),
                          label: const Text('应用 AI 调色'),
                        ),
                    ],
                  ],
                  ),
                );
              },
            ),
    ),
  );
  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    PhotoRecipe Function(double) update, {
    String suffix = '',
  }) => Row(
    children: [
      SizedBox(width: 56, child: Text(label)),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: actionBusy || comparing ? null : (v) => _change(update(v)),
          onChangeEnd: _endChange,
        ),
      ),
      SizedBox(
        width: 60,
        child: Text(
          '${value.toStringAsFixed(2)}$suffix',
          textAlign: TextAlign.end,
          style: const TextStyle(color: Colors.black54, fontSize: 12),
        ),
      ),
    ],
  );
  Future<void> _auto() async {
    setState(() {
      actionBusy = true;
      error = null;
    });
    try {
      final next = await repository.autoRecipe(widget.path);
      if (mounted) _applyRecipe(next);
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => actionBusy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      actionBusy = true;
      error = null;
    });
    try {
      await repository.saveRecipe(widget.path, recipe);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('调整记录已保存')));
      }
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => actionBusy = false);
    }
  }

  Future<void> _export() async {
    setState(() {
      actionBusy = true;
      error = null;
    });
    try {
      await repository.saveRecipe(widget.path, recipe);
      final path = await repository.export(
        widget.path,
        recipe,
        preserveExif: preserveExif,
      );
      if (mounted) setState(() => exportedPath = path);
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => actionBusy = false);
    }
  }

  Future<void> _saveToPhotos() async {
    final path = exportedPath;
    if (path == null) return;
    setState(() {
      actionBusy = true;
      error = null;
    });
    try {
      await repository.saveToPhotos(path);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已保存到系统相册')));
      }
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => actionBusy = false);
    }
  }

  Future<void> _analyze() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('发送照片预览'),
        content: const Text('将当前调整后的照片预览发送到你配置的 AI 服务，获取曝光、构图与色彩建议。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认分析'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final selected = recipe;
    setState(() {
      analyzing = true;
      error = null;
    });
    try {
      final result = await repository.analyze(
        widget.path,
        selected,
        '分析照片的曝光、构图与色彩，给出可执行的改进建议',
      );
      if (mounted) {
        setState(() {
          analysis = result;
          analyzedRecipe = selected;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = _message(e));
    } finally {
      if (mounted) setState(() => analyzing = false);
    }
  }

  Future<void> _applyAI() async {
    final savedAnalysis = analysis;
    final sourceRecipe = analyzedRecipe;
    if (savedAnalysis == null ||
        savedAnalysis['applicable'] != true ||
        savedAnalysis['recipe'] is! Map ||
        sourceRecipe != recipe) {
      return;
    }
    final proposed = PhotoRecipe.fromMap(
      Map<String, dynamic>.from(savedAnalysis['recipe'] as Map),
    );
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('应用 AI 调色'),
        content: Text(
          '曝光 ${proposed.exposure.toStringAsFixed(2)} EV\n对比度 ${proposed.contrast.toStringAsFixed(2)}\n饱和度 ${proposed.saturation.toStringAsFixed(2)}\n冷暖 ${proposed.warmth.toStringAsFixed(2)}\n\n应用后仍可调整、撤销，并需另行导出。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认应用'),
          ),
        ],
      ),
    );
    if (confirm == true &&
        mounted &&
        analyzedRecipe == sourceRecipe &&
        recipe == sourceRecipe &&
        !actionBusy) {
      _applyRecipe(proposed);
    }
  }
}
