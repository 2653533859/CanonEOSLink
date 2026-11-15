import 'package:flutter/material.dart';

import '../../core/camera/camera_controller.dart';
import '../../shared/glass_panel.dart';
import '../pose_guide/photo_pose_reference.dart';
import '../pose_guide/pose_reference.dart';
import '../pose_guide/pose_library_page.dart';

class AIPanel extends StatefulWidget {
  const AIPanel({super.key, required this.controller, this.onPoseSelected});
  final CameraController controller;
  final ValueChanged<PoseReference>? onPoseSelected;
  @override
  State<AIPanel> createState() => _AIPanelState();
}

class _AIPanelState extends State<AIPanel> {
  final goal = TextEditingController();
  CameraController get controller => widget.controller;
  @override
  void dispose() {
    goal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    final configured = snapshot.aiConfig['hasKey'] == true;
    final result = snapshot.guidance;
    final suggestions = (result['suggestions'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final notes = List<String>.from(result['composition'] as List? ?? []);
    final recommended = <(PoseReference, String)>[];
    final seen = <String>{};
    for (final value in (result['poseRecommendations'] as List? ?? [])) {
      if (value is! Map ||
          value['id'] is! String ||
          value['reason'] is! String) {
        continue;
      }
      final id = value['id'] as String;
      final matches = allPoseReferences.where((pose) => pose.id == id);
      if (matches.isNotEmpty && seen.add(id)) {
        recommended.add((matches.first, value['reason'] as String));
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: GlassPanel(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'AI 摄影指导',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'AI 服务设置',
                    onPressed: controller.aiBusy || controller.busy
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  AISettingsPage(controller: controller),
                            ),
                          ),
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
              TextField(
                controller: goal,
                maxLength: 300,
                decoration: const InputDecoration(
                  labelText: '拍摄目标（可选）',
                  hintText: '例如：自然光人像，背景柔和',
                  isDense: true,
                ),
              ),
              Text(
                configured ? '按需分析当前画面，建议不会自动修改相机。' : '请先在右上角配置 AI 服务。',
                style: TextStyle(color: Colors.black54, fontSize: 12),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed:
                    configured &&
                        snapshot.live &&
                        !controller.busy &&
                        !controller.aiBusy
                    ? _analyze
                    : null,
                icon: controller.aiBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.image_search_outlined),
                label: Text(controller.aiBusy ? '正在分析' : '分析当前画面'),
              ),
              if (result.isNotEmpty) ...[
                const Divider(height: 24),
                Text(
                  result['summary'] as String? ?? '',
                  style: const TextStyle(height: 1.5),
                ),
                for (final note in notes)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '• $note',
                      style: const TextStyle(
                        color: Colors.black87,
                        height: 1.4,
                      ),
                    ),
                  ),
                if (recommended.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text(
                    '推荐姿势',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Text(
                    '基于上次分析的画面，场景变化后请重新分析',
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                  for (final (pose, reason) in recommended)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(pose.title),
                      subtitle: Text(reason),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final selected = await Navigator.push<PoseReference>(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                PoseLibraryPage(initialPoseId: pose.id),
                          ),
                        );
                        if (selected != null && context.mounted) {
                          widget.onPoseSelected?.call(selected);
                        }
                      },
                    ),
                ] else ...[
                  const SizedBox(height: 12),
                  const Text(
                    '本次没有可用的姿势推荐，可调整拍摄目标后重新分析',
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ],
                if (result['confidence'] is num)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '模型置信度 ${(result['confidence'] as num).toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                  ),
                for (final item in suggestions)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${item['title']}：${item['label']}'),
                    subtitle: Text(
                      '${item['reason'] ?? ''}${item['applicable'] == true
                          ? ''
                          : item['property'] == 'shutter'
                          ? (snapshot.exposure['flash'] == '开启'
                                ? '\n仅供参考：闪光灯开启时仅可应用不高于 1/250s 的快门'
                                : '\n仅供参考：尚未确认闪光灯同步状态')
                          : '\n仅供参考：尚不满足应用条件'}',
                    ),
                    trailing: TextButton(
                      onPressed:
                          item['applicable'] == true &&
                              snapshot.exposure['verified'] == true &&
                              item['revision'] ==
                                  snapshot.exposure['revision'] &&
                              !controller.busy
                          ? () => _apply(item)
                          : null,
                      child: const Text('应用'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _analyze() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('发送当前取景帧'),
        content: const Text(
          '将当前画面、拍摄目标、已读取的相机参数和本机姿势目录发送至你配置的 AI 服务，以获取摄影和姿势建议。仅在点击确认后发送。',
        ),
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
    if (confirmed == true && mounted) {
      await controller.run('analyzeFrame', {
        'goal': goal.text,
        'poses': allPoseReferences
            .map(
              (p) => {
                'id': p.id,
                'title': p.title,
                'scene': p.scene,
                'framing': p.framing,
                'people': '${p.peopleCount}',
                'style': p.style,
                'description': p.description,
              },
            )
            .toList(),
      });
    }
  }

  Future<void> _apply(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('应用${item['title']}建议'),
        content: Text(
          '设置为 ${item['label']}？\n${item['reason']}\n\n应用前会重新校验相机模式和可用档位。',
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
    if (confirmed == true && mounted) {
      await controller.run('setExposure', {
        'property': item['property'],
        'value': item['raw'],
        'revision': item['revision'],
      });
    }
  }
}

class AISettingsPage extends StatefulWidget {
  const AISettingsPage({super.key, required this.controller});
  final CameraController controller;
  @override
  State<AISettingsPage> createState() => _AISettingsPageState();
}

class _AISettingsPageState extends State<AISettingsPage> {
  final form = GlobalKey<FormState>();
  late final TextEditingController endpoint;
  late final TextEditingController model;
  final keyInput = TextEditingController();
  bool saving = false;
  @override
  void initState() {
    super.initState();
    endpoint = TextEditingController(
      text: widget.controller.snapshot.aiConfig['endpoint'] as String? ?? '',
    );
    model = TextEditingController(
      text: widget.controller.snapshot.aiConfig['model'] as String? ?? '',
    );
  }

  @override
  void dispose() {
    endpoint.dispose();
    model.dispose();
    keyInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('AI 服务设置')),
    body: SafeArea(
      child: Form(
        key: form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              '使用兼容 Chat Completions 图片输入和 JSON 输出的服务。API Key 保存在本机钥匙串。',
              style: TextStyle(color: Colors.black87, height: 1.5),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: endpoint,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '完整接口地址',
                hintText: 'https://.../v1/chat/completions',
              ),
              validator: (value) {
                final url = Uri.tryParse(value?.trim() ?? '');
                if (url == null ||
                    url.scheme != 'https' ||
                    url.host.isEmpty ||
                    !url.path.endsWith('/chat/completions') ||
                    url.hasQuery ||
                    url.hasFragment ||
                    url.userInfo.isNotEmpty) {
                  return '请输入 HTTPS 的 /chat/completions 完整地址';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: model,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '支持图片输入的模型 ID'),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请输入模型 ID' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: keyInput,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: widget.controller.snapshot.aiConfig['hasKey'] == true
                    ? '留空可保留当前地址的密钥'
                    : '输入服务密钥',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: saving ? null : _save,
              child: const Text('保存配置'),
            ),
            TextButton(
              onPressed: saving
                  ? null
                  : () async {
                      final cleared = await widget.controller.run(
                        'clearAIConfig',
                      );
                      if (context.mounted && cleared) {
                        Navigator.pop(context);
                      }
                    },
              child: const Text('清除配置与密钥'),
            ),
            AnimatedBuilder(
              animation: widget.controller,
              builder: (context, _) => widget.controller.error == null
                  ? const SizedBox.shrink()
                  : Text(
                      widget.controller.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
  Future<void> _save() async {
    if (!form.currentState!.validate()) return;
    setState(() => saving = true);
    final saved = await widget.controller.run('saveAIConfig', {
      'endpoint': endpoint.text.trim(),
      'model': model.text.trim(),
      'key': keyInput.text,
    });
    if (!mounted) return;
    setState(() => saving = false);
    if (saved) Navigator.pop(context);
  }
}
