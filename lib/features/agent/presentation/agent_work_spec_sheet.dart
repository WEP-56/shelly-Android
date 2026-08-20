import 'package:flutter/material.dart';

import '../../../app/app_theme.dart';
import '../../../ui/settings_tiles.dart';
import '../data/agent_settings_repository.dart';
import 'agent_form_sheet.dart';

/// Editor for the user-authored work spec handed to the model as lower-priority
/// guidance. Returns the saved text, or null when the sheet is dismissed.
Future<String?> showAgentWorkSpecSheet(
  BuildContext context, {
  required AgentSettingsRepository settings,
  required String spec,
}) {
  return showAgentFormSheet<String>(
    context,
    builder: (context) => _WorkSpecSheet(settings: settings, spec: spec),
  );
}

class _WorkSpecSheet extends StatefulWidget {
  const _WorkSpecSheet({required this.settings, required this.spec});

  final AgentSettingsRepository settings;
  final String spec;

  @override
  State<_WorkSpecSheet> createState() => _WorkSpecSheetState();
}

class _WorkSpecSheetState extends State<_WorkSpecSheet> {
  late final _text = TextEditingController(text: widget.spec);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.settings.saveWorkSpec(_text.text);
      if (!mounted) return;
      Navigator.pop(context, saved);
    } on AgentSettingsException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          SheetHeader(
            icon: Icons.description_outlined,
            title: 'Agent 工作规范',
            subtitle: '交给模型的低优先级参考，不会覆盖安全规则',
            actions: [
              IconButton(
                onPressed: _saving ? null : () => _save(),
                tooltip: '保存',
                icon: const Icon(Icons.check_rounded),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                tooltip: '关闭',
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
              children: [
                if (_error case final message?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      message,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.surface2,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colors.line),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 15,
                        color: colors.onSurface3,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '这段文字会随每轮对话发给模型，请不要写入密码、私钥或任何 API Key。'
                          '它的优先级低于应用的安全规则：写入命令仍然需要你逐条批准。',
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.5,
                            color: colors.onSurface2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                AgentFormField(
                  controller: _text,
                  label: '工作规范',
                  hint:
                      '例如：\n'
                      '- 这台机器上的服务用 systemd 管理，重启前先看日志。\n'
                      '- 部署目录在 /srv/app，不要动 /etc 下的文件。',
                  helper:
                      '最多 ${AgentSettingsRepository.workSpecMaxLength} 字，留空表示不使用。',
                  maxLines: 16,
                  maxLength: AgentSettingsRepository.workSpecMaxLength,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
