import 'package:flutter/material.dart';

import '../../../core/camera/camera_controller.dart';

class ExposurePanel extends StatelessWidget {
  const ExposurePanel({super.key, required this.controller});
  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    final snapshot = controller.snapshot;
    final exposure = snapshot.exposure;
    final fields = (exposure['fields'] as List? ?? [])
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();
    final revision = exposure['revision'] as int?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '相机参数',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                ),
                Text(
                  exposure['mode'] as String? ?? '未读取',
                  style: const TextStyle(color: Colors.black54),
                ),
                IconButton(
                  tooltip: '读取相机参数',
                  onPressed: controller.busy
                      ? null
                      : () => controller.run('refreshExposure'),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (fields.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '读取相机当前曝光参数后，可调整设备支持的档位。',
                  style: TextStyle(color: Colors.black54, height: 1.5),
                ),
              )
            else ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final field in fields)
                    ActionChip(
                      label: Text('${field['title']}  ${field['label']}'),
                      onPressed:
                          !controller.busy &&
                              field['writable'] == true &&
                              revision != null
                          ? () => _pick(context, field, revision)
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                exposure['verified'] == true
                    ? '点击可用参数修改；每次写入后等待相机确认。'
                    : '参数尚未确认，请重新读取。',
                style: const TextStyle(color: Colors.black54, fontSize: 12),
              ),
            ],
            if (snapshot.canUndoExposure)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: controller.busy
                      ? null
                      : () => controller.run('undoExposure'),
                  icon: const Icon(Icons.undo),
                  label: const Text('撤销上次参数修改'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pick(
    BuildContext context,
    Map<String, dynamic> field,
    int revision,
  ) async {
    final options = (field['options'] as List? ?? [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      useSafeArea: true,
      builder: (context) => SizedBox(
        height: 420,
        child: Column(
          children: [
            ListTile(
              title: Text('选择${field['title']}'),
              subtitle: Text('当前：${field['label']}'),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options[index];
                  return ListTile(
                    title: Text(option['label'] as String),
                    trailing: option['raw'] == field['raw']
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(context, option),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null ||
        !context.mounted ||
        selected['raw'] == field['raw']) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('修改${field['title']}'),
        content: Text(
          '${field['label']} → ${selected['label']}\n将再次读取相机状态，确认档位仍可用。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认修改'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await controller.run('setExposure', {
        'property': field['id'],
        'value': selected['raw'],
        'revision': revision,
      });
    }
  }
}
