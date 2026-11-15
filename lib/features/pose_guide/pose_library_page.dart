import 'package:flutter/material.dart';

import 'pose_reference.dart';
import 'pose_illustration.dart';
import 'photo_pose_reference.dart';
import 'basic_photo_pose_reference.dart';

class PoseLibraryPage extends StatefulWidget {
  const PoseLibraryPage({super.key, this.initialPoseId});
  final String? initialPoseId;
  @override
  State<PoseLibraryPage> createState() => _PoseLibraryPageState();
}

class _PoseLibraryPageState extends State<PoseLibraryPage> {
  String scene = '全部', framing = '全部', style = '全部', people = '全部';
  bool basicsOnly = false;
  @override
  void initState() {
    super.initState();
    final matches = allPoseReferences.where(
      (p) => p.id == widget.initialPoseId,
    );
    if (matches.isNotEmpty) {
      final pose = matches.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _details(context, pose);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = allPoseReferences
        .where(
          (p) =>
              (!basicsOnly || basicPoseIds.contains(p.id)) &&
              (scene == '全部' || p.scene == scene) &&
              (framing == '全部' || p.framing == framing) &&
              (people == '全部' ||
                  (people == '单人' && p.peopleCount == 1) ||
                  (people == '双人' && p.peopleCount == 2) ||
                  (people == '多人' && p.peopleCount >= 3)) &&
              (style == '全部' || p.style == style),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('姿势参考')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '真人摄影参考 · 离线可用',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ),
                      FilterChip(
                        label: const Text('基础姿势'),
                        selected: basicsOnly,
                        onSelected: (value) =>
                            setState(() => basicsOnly = value),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _filters(
                    '场景',
                    ['全部', '户外', '室内', '街景'],
                    scene,
                    (v) => setState(() => scene = v),
                  ),
                  _filters(
                    '构图',
                    ['全部', '全身', '半身'],
                    framing,
                    (v) => setState(() => framing = v),
                  ),
                  _filters(
                    '风格',
                    ['全部', '自然', '优雅', '活力'],
                    style,
                    (v) => setState(() => style = v),
                  ),
                  _filters(
                    '人数',
                    ['全部', '单人', '双人', '多人'],
                    people,
                    (v) => setState(() => people = v),
                  ),
                ],
              ),
            ),
            Expanded(
              child: results.isEmpty
                  ? const Center(child: Text('没有匹配的姿势，请调整筛选。'))
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: results.length,
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 260,
                            mainAxisExtent: 260,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                      itemBuilder: (context, index) {
                        final pose = results[index];
                        return Card(
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => _details(context, pose),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: _referenceImage(pose)),
                                Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        pose.title,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${pose.scene} · ${pose.framing} · ${pose.style}',
                                        style: const TextStyle(
                                          color: Colors.black54,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _referenceImage(PoseReference pose, {BoxFit fit = BoxFit.cover}) {
    final asset = pose.photoAsset;
    if (asset == null) return PoseIllustration(pose: pose, opacity: .9);
    return Image.asset(
      asset,
      fit: fit,
      errorBuilder: (_, _, _) => const Center(child: Text('图片无法加载')),
    );
  }

  Widget _filters(
    String title,
    List<String> values,
    String selected,
    ValueChanged<String> onSelected,
  ) => SizedBox(
    height: 46,
    child: Row(
      children: [
        SizedBox(
          width: 42,
          child: Text(
            title,
            style: const TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ),
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final value in values)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(value),
                    selected: value == selected,
                    onSelected: (_) => onSelected(value),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
  void _details(BuildContext context, PoseReference pose) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (detailContext) => Scaffold(
        appBar: AppBar(title: Text(pose.title)),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              SizedBox(
                height: 280,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: _referenceImage(pose, fit: BoxFit.contain),
                ),
              ),
              const SizedBox(height: 16),
              if (pose.photographer != null) ...[
                Text(
                  '摄影：${pose.photographer} · Pexels',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
                const SizedBox(height: 8),
              ],
              Text(
                pose.description,
                style: const TextStyle(fontSize: 16, height: 1.5),
              ),
              const SizedBox(height: 18),
              const Text('动作提示', style: TextStyle(fontWeight: FontWeight.w600)),
              for (final line in pose.instructions)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '• $line',
                    style: const TextStyle(color: Colors.black87, height: 1.4),
                  ),
                ),
              const SizedBox(height: 18),
              const Text('推荐机位', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                pose.cameraPosition,
                style: const TextStyle(color: Colors.black87, height: 1.4),
              ),
              const SizedBox(height: 8),
              Text(
                pose.focalLength,
                style: const TextStyle(color: Colors.black87),
              ),
              const Text(
                '焦段为全画幅等效值，R10 可按约 1.6 倍裁切系数换算。',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
              const SizedBox(height: 18),
              const Text('常见问题', style: TextStyle(fontWeight: FontWeight.w600)),
              for (final line in pose.mistakes)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '• $line',
                    style: const TextStyle(color: Colors.black87, height: 1.4),
                  ),
                ),
              const SizedBox(height: 24),
              if (pose.supportsOverlay)
                FilledButton.icon(
                  icon: const Icon(Icons.center_focus_weak),
                  label: const Text('用于取景参考'),
                  onPressed: () {
                    Navigator.pop(detailContext);
                    Navigator.pop(context, pose);
                  },
                ),
              const SizedBox(height: 12),
              Text(
                pose.supportsOverlay
                    ? '照片为相似动作参考；取景轮廓为手绘示意，姿态与照片并非完全一致。开启本机识别后可查看基础比较提示。'
                    : '真人照片仅供动作与构图参考，暂不支持取景叠加或姿态匹配。',
                style: const TextStyle(
                  color: Colors.black54,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
