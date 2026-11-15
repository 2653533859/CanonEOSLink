import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/camera/camera_controller.dart';
import '../../shared/glass_panel.dart';
import '../ai_guidance/ai_panel.dart';
import '../pose_guide/pose_illustration.dart';
import '../pose_guide/pose_library_page.dart';
import '../pose_guide/pose_reference.dart';
import '../pose_guide/pose_matcher.dart';
import '../pose_guide/detected_pose_overlay.dart';
import 'capture_gallery.dart';
import 'widgets/exposure_panel.dart';

class ShootingPage extends StatefulWidget {
  const ShootingPage({super.key, required this.controller});
  final CameraController controller;
  @override
  State<ShootingPage> createState() => _ShootingPageState();
}

class _ShootingPageState extends State<ShootingPage> {
  CameraController get controller => widget.controller;
  bool _grid = true;
  int _parameter = 0x00200000;
  PoseReference? _pose;
  bool _poseMirror = false;
  double _poseOpacity = .55;

  @override
  void initState() {
    super.initState();
    controller.initialize();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final snapshot = controller.snapshot;
      return Scaffold(
        appBar: AppBar(
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'EOS Link',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 22),
              ),
              Text(
                'USB 联机拍摄',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '已下载照片',
              onPressed: _openGallery,
              icon: const Icon(Icons.photo_library_outlined),
            ),
            IconButton(
              tooltip: '诊断日志',
              onPressed: _openDiagnostics,
              icon: const Icon(Icons.receipt_long_outlined),
            ),
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final controls = _controls();
              if (constraints.maxWidth > 700) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: _viewfinder(),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 340,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: controls,
                      ),
                    ),
                  ],
                );
              }
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            snapshot.model,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.circle,
                          size: 7,
                          color: snapshot.connected
                              ? const Color(0xff8fc8a1)
                              : Colors.black54,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          snapshot.label,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black87,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    _viewfinder(),
                    const SizedBox(height: 20),
                    controls,
                  ],
                ),
              );
            },
          ),
        ),
      );
    },
  );

  Widget _viewfinder() {
    final s = controller.snapshot;
    final tracking = PoseTrackingSnapshot.fromMap(s.poseTracking);
    return AspectRatio(
      aspectRatio: s.aspectRatio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: s.live ? Colors.black : const Color(0xffdbe6ef)),
            if (s.live && s.textureId >= 0)
              Texture(textureId: s.textureId)
            else
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        s.previewActive
                            ? Icons.hourglass_top
                            : Icons.camera_alt_outlined,
                        color: Colors.black45,
                        size: 36,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        s.previewActive ? '正在等待第一帧' : '连接相机，开始取景',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.black87,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        s.connected
                            ? '点击「开启取景」显示实时画面'
                            : '使用已验证的 USB 线连接 EOS R10',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.black54,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_grid && s.live)
              const IgnorePointer(child: CustomPaint(painter: _GridPainter())),
            if (s.live && _pose != null)
              IgnorePointer(
                child: PoseIllustration(
                  pose: _pose!,
                  overlay: true,
                  mirror: _poseMirror,
                  opacity: _poseOpacity,
                ),
              ),
            if (s.live &&
                _pose != null &&
                tracking.enabled &&
                tracking.status == 'detected')
              DetectedPoseOverlay(tracking: tracking),
            Positioned(
              top: 12,
              left: 12,
              child: Text(
                s.live ? '${s.fps.toStringAsFixed(1)} fps' : '实时画面',
                style: TextStyle(
                  color: s.live ? Colors.white70 : Colors.black54,
                  fontSize: 11,
                ),
              ),
            ),
            if (s.live && s.histogram.isNotEmpty)
              Positioned(
                bottom: 8,
                right: 44,
                child: IgnorePointer(
                  child: _HistogramHud(
                    bins: s.histogram,
                    highlightClipped: s.highlightClipped,
                  ),
                ),
              ),
            Positioned(
              bottom: 4,
              right: 4,
              child: IconButton(
                tooltip: '切换三分构图线',
                onPressed: () => setState(() => _grid = !_grid),
                icon: Icon(
                  Icons.grid_3x3,
                  color: _grid
                      ? Theme.of(context).colorScheme.primary
                      : (s.live ? Colors.white70 : Colors.black54),
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls() {
    final s = controller.snapshot;
    final enabled = !controller.busy;
    final tracking = PoseTrackingSnapshot.fromMap(s.poseTracking);
    final match = _pose == null
        ? null
        : PoseMatcher.match(
            _pose!,
            tracking,
            imageAspect: s.aspectRatio,
            mirrored: _poseMirror,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (controller.busy) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            controller.error ?? s.message,
            style: TextStyle(
              height: 1.5,
              color: controller.error != null
                  ? Theme.of(context).colorScheme.error
                  : Colors.black54,
            ),
          ),
        ),
        if (!s.connected) ...[
          FilledButton.icon(
            onPressed: enabled ? () => controller.run('discover') : null,
            icon: const Icon(Icons.usb),
            label: const Text('搜索 USB 相机'),
          ),
          for (final device in s.devices)
            Card(
              child: ListTile(
                leading: const Icon(Icons.camera_outlined),
                title: Text(device['name'] as String),
                subtitle: const Text('USB · 点击连接'),
                onTap: enabled
                    ? () =>
                          controller.run('connect', {'deviceId': device['id']})
                    : null,
                trailing: const Icon(Icons.chevron_right),
              ),
            ),
          const SizedBox(height: 12),
          const Text('开始前', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            '1. 关闭其他联机 App，相机保持开机\n2. 解锁 iPhone，允许外接相机访问\n3. 相机保存格式设为 JPEG 或 RAW + JPEG',
            style: TextStyle(color: Colors.black54, height: 1.8, fontSize: 13),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: enabled
                      ? () => controller.run(
                          s.previewActive ? 'stopLiveView' : 'startLiveView',
                          {'parameter': _parameter},
                        )
                      : null,
                  icon: Icon(
                    s.previewActive
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                  ),
                  label: Text(s.previewActive ? '停止取景' : '开启取景'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: enabled ? () => controller.run('disconnect') : null,
                child: const Text('断开'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: controller.canCapture
                    ? () => controller.run('autofocus')
                    : null,
                icon: const Icon(Icons.center_focus_strong_outlined, size: 18),
                label: const Text('半按对焦'),
              ),
              const SizedBox(width: 16),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    label: '遥控拍照',
                    button: true,
                    child: SizedBox(
                      width: 82,
                      height: 82,
                      child: FilledButton(
                        onPressed: controller.canCapture
                            ? () => controller.run('capture')
                            : null,
                        style: FilledButton.styleFrom(
                          shape: const CircleBorder(),
                          padding: EdgeInsets.zero,
                        ),
                        child: const Icon(Icons.camera_alt_outlined, size: 32),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '遥控拍照',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
        const SizedBox(height: 16),
        GlassPanel(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.accessibility_new),
                title: Text(_pose == null ? '姿势参考' : '姿势参考 · ${_pose!.title}'),
                subtitle: Text(_pose == null ? '浏览姿势和拍摄提示' : '开启取景后可叠加示意轮廓'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _choosePose,
              ),
              if (_pose != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _pose!.description,
                              style: const TextStyle(
                                color: Colors.black54,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '镜像姿势',
                            onPressed: () =>
                                setState(() => _poseMirror = !_poseMirror),
                            icon: Icon(
                              Icons.flip,
                              color: _poseMirror
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.black54,
                            ),
                          ),
                          IconButton(
                            tooltip: '移除姿势参考',
                            onPressed: enabled ? _clearPose : null,
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          const Text(
                            '轮廓透明度',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.black54,
                            ),
                          ),
                          Expanded(
                            child: Slider(
                              value: _poseOpacity,
                              min: .15,
                              max: .9,
                              onChanged: (value) =>
                                  setState(() => _poseOpacity = value),
                            ),
                          ),
                        ],
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          '本机姿态识别',
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: Text(
                          s.live ? '最多每秒分析一帧，不上传或保存关键点' : '开启实时取景后可使用',
                        ),
                        value: tracking.enabled,
                        onChanged: enabled && (s.live || tracking.enabled)
                            ? (value) => controller.run('setPoseTracking', {
                                'enabled': value,
                              })
                            : null,
                      ),
                      if (tracking.enabled && match != null) ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            match.title,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        for (final hint in match.hints)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: Text(
                                hint,
                                style: const TextStyle(
                                  color: Colors.black87,
                                  fontSize: 12,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        const Text(
                          '白色为参考轮廓，青色为识别关键点。结果仅供辅助，遮挡、侧身及光线会影响判断。',
                          style: TextStyle(
                            color: Colors.black54,
                            fontSize: 11,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (s.connected) ExposurePanel(controller: controller),
        AIPanel(
          controller: controller,
          onPoseSelected: (pose) => setState(() => _pose = pose),
        ),
        const Divider(height: 32, color: Colors.black12),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动接收新照片', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '保存到本机，保留相机原片',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
          value: s.autoDownload,
          onChanged: enabled
              ? (value) => controller.run('setAutoDownload', {'enabled': value})
              : null,
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.photo_library_outlined),
          title: const Text('已下载照片'),
          trailing: Text(
            '${s.captureCount}',
            style: const TextStyle(color: Colors.black54),
          ),
          onTap: _openGallery,
        ),
        if (s.connected)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.sd_card_outlined),
            title: const Text('相机里的 JPEG'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openCameraFiles,
          ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('连接诊断', style: TextStyle(fontSize: 14)),
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('取景请求参数'),
              subtitle: const Text('仅在取景失败时切换后重试'),
              trailing: DropdownButton<int>(
                value: _parameter,
                items: const [
                  DropdownMenuItem(value: 0x00200000, child: Text('0x200000')),
                  DropdownMenuItem(value: 0x00100000, child: Text('0x100000')),
                ],
                onChanged: enabled && !s.previewActive
                    ? (value) => setState(() => _parameter = value!)
                    : null,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: enabled && s.connected
                    ? () => controller.run('getDeviceInfo')
                    : null,
                icon: const Icon(Icons.info_outline),
                label: const Text('读取 GetDeviceInfo'),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _openDiagnostics,
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('查看与复制诊断日志'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Text(
          'USB 验证版 · 相机参数与 AI 建议需要真机验证',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.black54, fontSize: 11, height: 1.5),
        ),
      ],
    );
  }

  Future<void> _choosePose() async {
    final selected = await Navigator.of(context).push<PoseReference>(
      MaterialPageRoute<PoseReference>(builder: (_) => const PoseLibraryPage()),
    );
    if (selected != null && mounted) setState(() => _pose = selected);
  }

  Future<void> _clearPose() async {
    if (PoseTrackingSnapshot.fromMap(controller.snapshot.poseTracking)
        .enabled) {
      final disabled = await controller.run('setPoseTracking', {
        'enabled': false,
      });
      if (!disabled) return;
    }
    if (mounted) setState(() => _pose = null);
  }

  void _openGallery() =>
      _openSheet('已下载照片', () => CaptureGallery(controller: controller));

  void _openCameraFiles() => _openSheet(
    '相机里的 JPEG · 最近 30 张',
    () => Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: controller.busy
                  ? null
                  : () => controller.run('refreshFiles'),
              icon: const Icon(Icons.refresh),
              label: const Text('刷新目录'),
            ),
            if (controller.snapshot.rawCount > 0)
              Text(
                '同卡 RAW ${controller.snapshot.rawCount} 张（仅提示，不传输）',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
          ],
        ),
        Expanded(
          child: controller.snapshot.files.isEmpty
              ? const Center(child: Text('目录中尚未发现 JPEG'))
              : ListView(
                  children: [
                    for (final file in controller.snapshot.files)
                      ListTile(
                        title: Text(file['name'] as String),
                        subtitle: file['hasRAW'] == true
                            ? const Text('包含同名 RAW (CR3)')
                            : null,
                        trailing: IconButton(
                          tooltip: '下载照片',
                          icon: Icon(
                            file['downloaded'] == true
                                ? Icons.check
                                : Icons.download_outlined,
                          ),
                          onPressed:
                              controller.busy || file['downloaded'] == true
                              ? null
                              : () => controller.run('download', {
                                  'handle': file['handle'],
                                }),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    ),
  );

  void _openDiagnostics() => _openSheet(
    '诊断日志',
    () => Column(
      children: [
        TextButton.icon(
          onPressed: () async {
            try {
              await Clipboard.setData(
                ClipboardData(text: await controller.repository.diagnostics()),
              );
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('诊断日志已复制')));
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text('复制失败：$e')));
              }
            }
          },
          icon: const Icon(Icons.copy),
          label: const Text('复制日志'),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              controller.snapshot.logs.isEmpty
                  ? '尚无记录'
                  : controller.snapshot.logs.reversed.join('\n\n'),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.6,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  void _openSheet(String title, Widget Function() body) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .8,
          child: AnimatedBuilder(
            animation: controller,
            builder: (_, _) => Column(
              children: [
                ListTile(
                  title: Text(title),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                Expanded(child: body()),
              ],
            ),
          ),
        ),
      );
}

class _GridPainter extends CustomPainter {
  const _GridPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white24
      ..strokeWidth = .5;
    for (var i = 1; i <= 2; i++) {
      canvas.drawLine(
        Offset(size.width * i / 3, 0),
        Offset(size.width * i / 3, size.height),
        paint,
      );
      canvas.drawLine(
        Offset(0, size.height * i / 3),
        Offset(size.width, size.height * i / 3),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _HistogramHud extends StatelessWidget {
  const _HistogramHud({required this.bins, required this.highlightClipped});
  final List<double> bins;
  final bool highlightClipped;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (highlightClipped)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              '高光溢出',
              style: TextStyle(
                color: Color(0xffffb74d),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        SizedBox(
          width: 72,
          height: 28,
          child: CustomPaint(painter: _HistogramPainter(bins)),
        ),
      ],
    ),
  );
}

class _HistogramPainter extends CustomPainter {
  const _HistogramPainter(this.bins);
  final List<double> bins;

  @override
  void paint(Canvas canvas, Size size) {
    if (bins.isEmpty) return;
    final barWidth = size.width / bins.length;
    final paint = Paint()..color = Colors.white70;
    for (var i = 0; i < bins.length; i++) {
      final h = (bins[i].clamp(0.0, 1.0)) * size.height;
      canvas.drawRect(
        Rect.fromLTWH(i * barWidth, size.height - h, barWidth * 0.78, h),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter oldDelegate) =>
      oldDelegate.bins != bins;
}
