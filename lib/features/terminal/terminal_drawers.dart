import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../history/history_controller.dart';
import '../history/history_repository.dart';
import '../snippets/snippet_controller.dart';
import '../snippets/snippet_repository.dart';
import '../../ui/shelly_icon_button.dart';

Future<void> showSnippetsDrawer(
  BuildContext context, {
  required ValueChanged<String> onInsert,
  required ValueChanged<String> onRun,
  required SnippetRepository repository,
  required String hostId,
}) {
  return _showRightDrawer(
    context,
    child: _SnippetsDrawer(
      onInsert: onInsert,
      onRun: onRun,
      repository: repository,
      hostId: hostId,
    ),
  );
}

Future<void> showHistoryDrawer(
  BuildContext context, {
  required ValueChanged<String> onInsert,
  required ValueChanged<String> onRun,
  required HistoryRepository repository,
  required SnippetRepository snippets,
  required String hostId,
}) {
  return _showRightDrawer(
    context,
    child: _HistoryDrawer(
      onInsert: onInsert,
      onRun: onRun,
      repository: repository,
      snippets: snippets,
      hostId: hostId,
    ),
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

class _SnippetsDrawer extends StatefulWidget {
  const _SnippetsDrawer({
    required this.onInsert,
    required this.onRun,
    required this.repository,
    required this.hostId,
  });

  final ValueChanged<String> onInsert;
  final ValueChanged<String> onRun;
  final SnippetRepository repository;
  final String hostId;

  @override
  State<_SnippetsDrawer> createState() => _SnippetsDrawerState();
}

class _SnippetsDrawerState extends State<_SnippetsDrawer> {
  late final SnippetController _controller = SnippetController(
    repository: widget.repository,
    hostId: widget.hostId,
  );
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _controller.dispose();
    super.dispose();
  }

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
        onPressed: _createSnippet,
      ),
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, child) {
          if (_controller.status == SnippetListStatus.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_controller.status == SnippetListStatus.failure) {
            return _DrawerError(
              message: _controller.errorMessage ?? '读取便签失败，请重试。',
              onRetry: _controller.load,
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              TextField(
                controller: _searchController,
                onChanged: _controller.search,
                decoration: InputDecoration(
                  hintText: '搜索便签',
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: context.shelly.onSurface3,
                  ),
                  filled: true,
                  fillColor: context.shelly.surface2,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              for (final snippet in _controller.items)
                _CommandTile(
                  icon: snippet.pinned
                      ? Icons.push_pin_rounded
                      : Icons.notes_rounded,
                  title: snippet.name,
                  command: snippet.command,
                  onTap: () => _handleAction(snippet),
                  onLongPress: () => _handleAction(snippet),
                ),
              if (_controller.items.isEmpty)
                const _EmptyCommands(icon: Icons.notes_rounded, label: '暂无便签'),
            ],
          );
        },
      ),
    );
  }

  Future<void> _handleAction(CommandSnippet snippet) async {
    final action = await _showCommandActions(
      context,
      canEdit: true,
      allowPin: true,
      pinned: snippet.pinned,
    );
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
        await _editSnippet(snippet);
        return;
      case _CommandAction.pin:
        try {
          await _controller.togglePinned(snippet);
        } on SnippetRepositoryException catch (error) {
          if (mounted) _message(context, error.message);
        }
        return;
      case _CommandAction.delete:
        await _deleteSnippet(snippet);
        return;
    }
  }

  Future<void> _createSnippet() => _editSnippet(null);

  Future<void> _editSnippet(CommandSnippet? existing) async {
    final result = await _showSnippetEditor(
      context,
      existing: existing,
      hostId: widget.hostId,
    );
    if (result == null || !mounted) return;
    try {
      await _controller.save(result, existing: existing);
    } on SnippetRepositoryException catch (error) {
      if (mounted) _message(context, error.message);
    }
  }

  Future<void> _deleteSnippet(CommandSnippet snippet) async {
    final confirmed = await _confirmDelete(context, '删除便签？');
    if (confirmed != true || !mounted) return;
    try {
      await _controller.delete(snippet);
    } on SnippetRepositoryException catch (error) {
      if (mounted) _message(context, error.message);
    }
  }
}

class _HistoryDrawer extends StatefulWidget {
  const _HistoryDrawer({
    required this.onInsert,
    required this.onRun,
    required this.repository,
    required this.snippets,
    required this.hostId,
  });

  final ValueChanged<String> onInsert;
  final ValueChanged<String> onRun;
  final HistoryRepository repository;
  final SnippetRepository snippets;
  final String hostId;

  @override
  State<_HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<_HistoryDrawer> {
  late final HistoryController _controller = HistoryController(
    repository: widget.repository,
    snippets: widget.snippets,
    hostId: widget.hostId,
  );
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return _DrawerFrame(
      icon: Icons.history_rounded,
      title: '历史',
      headerRight: ShellyIconButton(
        icon: Icons.delete_sweep_outlined,
        tooltip: '清空当前设备历史',
        dimension: 40,
        size: 19,
        onPressed: _clearHistory,
      ),
      child: ListenableBuilder(
        listenable: _controller,
        builder: (context, child) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            TextField(
              controller: _searchController,
              onChanged: _controller.search,
              decoration: InputDecoration(
                hintText: '搜索命令',
                prefixIcon: Icon(
                  Icons.search_rounded,
                  color: colors.onSurface3,
                ),
                filled: true,
                fillColor: colors.surface2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_controller.status == HistoryListStatus.loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_controller.status == HistoryListStatus.failure)
              _DrawerError(
                message: _controller.errorMessage ?? '读取命令历史失败，请重试。',
                onRetry: _controller.load,
              )
            else
              for (final item in _controller.items)
                _CommandTile(
                  icon: item.pinned
                      ? Icons.push_pin_rounded
                      : Icons.history_rounded,
                  title: item.command,
                  command: _historyMeta(item),
                  onTap: () => _handleAction(item),
                  onLongPress: () => _handleAction(item),
                ),
            if (_controller.status == HistoryListStatus.ready &&
                _controller.items.isEmpty)
              const _EmptyCommands(icon: Icons.history_rounded, label: '暂无历史'),
          ],
        ),
      ),
    );
  }

  String _historyMeta(CommandHistoryEntry item) {
    final local = item.startedAt.toLocal();
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return item.exitCode == null
        ? '$time · 未知结果'
        : '$time · 退出码 ${item.exitCode}';
  }

  Future<void> _handleAction(CommandHistoryEntry item) async {
    final action = await _showCommandActions(
      context,
      canEdit: true,
      allowPin: true,
      pinned: item.pinned,
      editLabel: '转便签',
    );
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
        await _convertToSnippet(item);
        return;
      case _CommandAction.pin:
        try {
          await _controller.togglePinned(item);
        } on HistoryRepositoryException catch (error) {
          if (mounted) _message(context, error.message);
        }
        return;
      case _CommandAction.delete:
        final confirmed = await _confirmDelete(context, '删除这条历史？');
        if (confirmed != true || !mounted) return;
        try {
          await _controller.delete(item);
        } on HistoryRepositoryException catch (error) {
          if (mounted) _message(context, error.message);
        }
        return;
    }
  }

  Future<void> _convertToSnippet(CommandHistoryEntry item) async {
    final name = await _showNamePrompt(context, initial: item.command);
    if (name == null || !mounted) return;
    try {
      await _controller.convertToSnippet(item, name: name, global: false);
      if (mounted) _message(context, '已保存为设备便签');
    } on SnippetRepositoryException catch (error) {
      if (mounted) _message(context, error.message);
    }
  }

  Future<void> _clearHistory() async {
    if (_controller.items.isEmpty) return;
    final confirmed = await _confirmDelete(context, '清空当前设备历史？');
    if (confirmed != true || !mounted) return;
    try {
      await _controller.clear();
    } on HistoryRepositoryException catch (error) {
      if (mounted) _message(context, error.message);
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

class _DrawerError extends StatelessWidget {
  const _DrawerError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    ),
  );
}

Future<SnippetDraft?> _showSnippetEditor(
  BuildContext context, {
  CommandSnippet? existing,
  required String hostId,
}) {
  return showDialog<SnippetDraft>(
    context: context,
    builder: (context) =>
        _SnippetEditorDialog(existing: existing, hostId: hostId),
  );
}

class _SnippetEditorDialog extends StatefulWidget {
  const _SnippetEditorDialog({required this.existing, required this.hostId});

  final CommandSnippet? existing;
  final String hostId;

  @override
  State<_SnippetEditorDialog> createState() => _SnippetEditorDialogState();
}

class _SnippetEditorDialogState extends State<_SnippetEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _command;
  late final TextEditingController _description;
  late final TextEditingController _tags;
  late bool _deviceOnly;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.name ?? '');
    _command = TextEditingController(text: existing?.command ?? '');
    _description = TextEditingController(text: existing?.description ?? '');
    _tags = TextEditingController(text: existing?.tags.join(', ') ?? '');
    _deviceOnly = existing?.hostScope != null;
  }

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _description.dispose();
    _tags.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '添加便签' : '编辑便签'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: _command,
              decoration: const InputDecoration(labelText: '命令'),
              minLines: 1,
              maxLines: 4,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            TextField(
              controller: _description,
              decoration: const InputDecoration(labelText: '描述'),
            ),
            TextField(
              controller: _tags,
              decoration: const InputDecoration(labelText: '标签（逗号分隔）'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('仅当前设备'),
              value: _deviceOnly,
              onChanged: (value) => setState(() => _deviceOnly = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            SnippetDraft(
              name: _name.text,
              command: _command.text,
              description: _description.text,
              tags: _tags.text.split(','),
              hostScope: _deviceOnly ? widget.hostId : null,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

Future<bool?> _confirmDelete(BuildContext context, String title) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: const Text('此操作无法撤销。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
}

Future<String?> _showNamePrompt(
  BuildContext context, {
  required String initial,
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (context) => _SnippetNameDialog(initial: initial),
  );
  return result == null || result.isEmpty ? null : result;
}

class _SnippetNameDialog extends StatefulWidget {
  const _SnippetNameDialog({required this.initial});

  final String initial;

  @override
  State<_SnippetNameDialog> createState() => _SnippetNameDialogState();
}

class _SnippetNameDialogState extends State<_SnippetNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('保存为便签'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
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

enum _CommandAction { insert, run, edit, pin, delete }

Future<_CommandAction?> _showCommandActions(
  BuildContext context, {
  required bool canEdit,
  required bool allowPin,
  required bool pinned,
  String editLabel = '编辑',
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
                label: editLabel,
                onTap: () => Navigator.pop(context, _CommandAction.edit),
              ),
            if (allowPin)
              _Action(
                icon: pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                label: pinned ? '取消置顶' : '置顶',
                onTap: () => Navigator.pop(context, _CommandAction.pin),
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
