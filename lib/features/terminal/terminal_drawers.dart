import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_theme.dart';
import '../../app/models.dart';
import '../../ui/shelly_icon_button.dart';

Future<void> showFilesDrawer(BuildContext context, HostProfile server) {
  return _showRightDrawer(context, child: _FilesDrawer(server: server));
}

Future<void> showSnippetsDrawer(
  BuildContext context, {
  required ValueChanged<String> onInsert,
  required ValueChanged<String> onRun,
}) {
  return _showRightDrawer(
    context,
    child: _SnippetsDrawer(onInsert: onInsert, onRun: onRun),
  );
}

Future<void> showHistoryDrawer(
  BuildContext context, {
  required ValueChanged<String> onInsert,
  required ValueChanged<String> onRun,
}) {
  return _showRightDrawer(
    context,
    child: _HistoryDrawer(onInsert: onInsert, onRun: onRun),
  );
}

Future<void> _showRightDrawer(BuildContext context, {required Widget child}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭侧栏',
    barrierColor: context.shelly.scrim,
    transitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (context, animation, secondaryAnimation) {
      final width = math.min(340.0, MediaQuery.sizeOf(context).width * 0.84);
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(width: width, height: double.infinity, child: child),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curve = CurvedAnimation(
        parent: animation,
        curve: const Cubic(0.22, 0.9, 0.3, 1),
        reverseCurve: const Cubic(0.5, 0, 0.75, 0.4),
      );
      return SlideTransition(
        position: Tween(
          begin: const Offset(1.02, 0),
          end: Offset.zero,
        ).animate(curve),
        child: child,
      );
    },
  );
}

class _DrawerFrame extends StatelessWidget {
  const _DrawerFrame({
    required this.icon,
    required this.title,
    required this.child,
    this.headerRight,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? headerRight;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Material(
      color: colors.elevated,
      elevation: 18,
      shadowColor: Colors.black.withValues(alpha: 0.32),
      borderRadius: const BorderRadius.horizontal(left: Radius.circular(28)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        left: false,
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  const SizedBox(width: 2),
                  ShellyIconButton(
                    icon: Icons.close_rounded,
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    dimension: 40,
                  ),
                  const SizedBox(width: 2),
                  Icon(icon, size: 19, color: colors.onSurface2),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  ?headerRight,
                  const SizedBox(width: 8),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _FilesDrawer extends StatefulWidget {
  const _FilesDrawer({required this.server});

  final HostProfile server;

  @override
  State<_FilesDrawer> createState() => _FilesDrawerState();
}

class _FilesDrawerState extends State<_FilesDrawer> {
  String _path = '/home';

  List<({String name, bool directory, String size})> get _items =>
      _path == '/home'
      ? const [
          (name: 'app', directory: true, size: '目录'),
          (name: 'deploy.sh', directory: false, size: '1.2 KB'),
          (name: 'nginx.conf', directory: false, size: '4.6 KB'),
        ]
      : const [
          (name: 'src', directory: true, size: '目录'),
          (name: 'package.json', directory: false, size: '2.1 KB'),
        ];

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return _DrawerFrame(
      icon: Icons.folder_rounded,
      title: '文件',
      headerRight: Text(
        widget.server.name,
        style: TextStyle(
          color: colors.onSurface3,
          fontFamily: 'monospace',
          fontSize: 10.5,
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _path,
                  style: TextStyle(
                    color: colors.onSurface3,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
              ShellyIconButton(
                icon: Icons.upload_rounded,
                tooltip: '上传',
                dimension: 38,
                size: 18,
                active: true,
                onPressed: () => _message('已选择上传文件（演示）'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
            child: Text(
              '${_items.length} 个项目',
              style: TextStyle(color: colors.onSurface3, fontSize: 10.5),
            ),
          ),
          if (_path != '/home')
            _FileRow(
              name: '..',
              suffix: '上级',
              icon: Icons.folder_rounded,
              onTap: () => setState(() => _path = '/home'),
            ),
          for (final item in _items)
            _FileRow(
              name: item.name,
              suffix: item.size,
              icon: item.directory
                  ? Icons.folder_rounded
                  : item.name.endsWith('.conf') || item.name.endsWith('.sh')
                  ? Icons.code_rounded
                  : Icons.description_rounded,
              onTap: () {
                if (item.directory) {
                  setState(() => _path = '$_path/${item.name}');
                } else {
                  _message('开始下载 ${item.name}');
                }
              },
              onLongPress: () => _showFileActions(item.name),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '.. 返回上级 · 点文件下载 · 长按更多',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurface3, fontSize: 10.5),
            ),
          ),
        ],
      ),
    );
  }

  void _showFileActions(String name) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.download_rounded),
              title: const Text('下载'),
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('复制路径'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: '$_path/$name'));
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('删除'),
              onTap: () => Navigator.pop(context),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.name,
    required this.suffix,
    required this.icon,
    required this.onTap,
    this.onLongPress,
  });

  final String name;
  final String suffix;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: colors.surface2,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 16, color: colors.onSurface2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  suffix,
                  style: TextStyle(
                    color: colors.onSurface3,
                    fontFamily: 'monospace',
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SnippetsDrawer extends StatefulWidget {
  const _SnippetsDrawer({required this.onInsert, required this.onRun});

  final ValueChanged<String> onInsert;
  final ValueChanged<String> onRun;

  @override
  State<_SnippetsDrawer> createState() => _SnippetsDrawerState();
}

class _SnippetsDrawerState extends State<_SnippetsDrawer> {
  final List<({String name, String command})> _snippets = [
    (name: '磁盘占用', command: 'df -h'),
  ];

  @override
  Widget build(BuildContext context) {
    return _DrawerFrame(
      icon: Icons.notes_rounded,
      title: '便签',
      headerRight: ShellyIconButton(
        icon: Icons.add_rounded,
        tooltip: '添加',
        dimension: 40,
        size: 19,
        onPressed: () => _message(context, '添加便签（演示）'),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          for (final snippet in _snippets)
            _CommandTile(
              icon: Icons.notes_rounded,
              title: snippet.name,
              command: snippet.command,
              onTap: () => _handleAction(snippet),
              onLongPress: () => _handleAction(snippet),
            ),
          if (_snippets.isEmpty)
            const _EmptyCommands(icon: Icons.notes_rounded, label: '暂无便签'),
          const SizedBox(height: 12),
          Text(
            '点按展开操作 · 长按管理',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.shelly.onSurface3, fontSize: 10.5),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAction(({String name, String command}) snippet) async {
    final action = await _showCommandActions(context, canEdit: true);
    if (!mounted || action == null) return;
    switch (action) {
      case _CommandAction.insert:
        Navigator.pop(context);
        widget.onInsert(snippet.command);
        return;
      case _CommandAction.run:
        Navigator.pop(context);
        widget.onRun(snippet.command);
        return;
      case _CommandAction.edit:
        _message(context, '编辑便签（演示）');
        return;
      case _CommandAction.delete:
        setState(() => _snippets.remove(snippet));
        _message(context, '已删除');
        return;
    }
  }
}

class _HistoryDrawer extends StatefulWidget {
  const _HistoryDrawer({required this.onInsert, required this.onRun});

  final ValueChanged<String> onInsert;
  final ValueChanged<String> onRun;

  @override
  State<_HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<_HistoryDrawer> {
  final List<({String command, String meta})> _history = [
    (command: 'docker ps -a', meta: '刚刚 · prod-web-01'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return _DrawerFrame(
      icon: Icons.history_rounded,
      title: '历史',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Container(
            height: 40,
            decoration: BoxDecoration(
              color: colors.surface2,
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Icon(Icons.search_rounded, size: 16, color: colors.onSurface3),
                const SizedBox(width: 10),
                Text(
                  '搜索命令',
                  style: TextStyle(color: colors.onSurface3, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (final item in _history)
            _CommandTile(
              icon: Icons.chevron_right_rounded,
              title: item.command,
              command: item.meta,
              onTap: () => _handleAction(item),
              onLongPress: () => _handleAction(item),
            ),
          if (_history.isEmpty)
            const _EmptyCommands(icon: Icons.history_rounded, label: '暂无历史'),
          const SizedBox(height: 12),
          Text(
            '自动采集已执行命令 · 点按插入 · 长按管理',
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.onSurface3, fontSize: 10.5),
          ),
        ],
      ),
    );
  }

  Future<void> _handleAction(({String command, String meta}) item) async {
    final action = await _showCommandActions(context, canEdit: false);
    if (!mounted || action == null) return;
    switch (action) {
      case _CommandAction.insert:
        Navigator.pop(context);
        widget.onInsert(item.command);
        return;
      case _CommandAction.run:
        Navigator.pop(context);
        widget.onRun(item.command);
        return;
      case _CommandAction.edit:
        return;
      case _CommandAction.delete:
        setState(() => _history.remove(item));
        _message(context, '已删除');
        return;
    }
  }
}

class _CommandTile extends StatelessWidget {
  const _CommandTile({
    required this.icon,
    required this.title,
    required this.command,
    required this.onTap,
    required this.onLongPress,
  });

  final IconData icon;
  final String title;
  final String command;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colors.surface2,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: colors.onSurface2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      command,
                      style: TextStyle(
                        color: colors.onSurface3,
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyCommands extends StatelessWidget {
  const _EmptyCommands({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 42),
      child: Column(
        children: [
          Icon(icon, size: 25, color: colors.onSurface3),
          const SizedBox(height: 9),
          Text(label, style: TextStyle(color: colors.onSurface3, fontSize: 11)),
        ],
      ),
    );
  }
}

enum _CommandAction { insert, run, edit, delete }

Future<_CommandAction?> _showCommandActions(
  BuildContext context, {
  required bool canEdit,
}) {
  return showModalBottomSheet<_CommandAction>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 18),
        child: Row(
          children: [
            _Action(
              icon: Icons.keyboard_tab_rounded,
              label: '插入',
              onTap: () => Navigator.pop(context, _CommandAction.insert),
            ),
            _Action(
              icon: Icons.play_arrow_rounded,
              label: '运行',
              onTap: () => Navigator.pop(context, _CommandAction.run),
            ),
            if (canEdit)
              _Action(
                icon: Icons.edit_rounded,
                label: '编辑',
                onTap: () => Navigator.pop(context, _CommandAction.edit),
              ),
            _Action(
              icon: Icons.delete_outline_rounded,
              label: '删除',
              onTap: () => Navigator.pop(context, _CommandAction.delete),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 19),
              const SizedBox(height: 3),
              Text(label, style: const TextStyle(fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }
}

void _message(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
