import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../../app/app_theme.dart';
import '../../app/models.dart';
import '../../core/ssh/ssh_session_controller.dart';
import '../../ui/shelly_icon_button.dart';
import 'sftp_browser_controller.dart';
import 'sftp_session.dart';
import 'sftp_transfer_controller.dart';

Future<void> showFilesDrawer(
  BuildContext context,
  HostProfile server, {
  required SshSessionController session,
  required SftpTransferController transfers,
}) {
  return _showRightDrawer(
    context,
    child: _FilesDrawer(server: server, session: session, transfers: transfers),
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
      final width = math.min(400.0, MediaQuery.sizeOf(context).width * 0.92);
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
                  if (headerRight != null) Flexible(child: headerRight!),
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
  const _FilesDrawer({
    required this.server,
    required this.session,
    required this.transfers,
  });

  final HostProfile server;
  final SshSessionController session;
  final SftpTransferController transfers;

  @override
  State<_FilesDrawer> createState() => _FilesDrawerState();
}

class _FilesDrawerState extends State<_FilesDrawer> {
  late final SftpBrowserController _browser = SftpBrowserController(
    sshSession: widget.session,
    initialPath: widget.server.lastPath,
  );
  final _searchController = TextEditingController();
  final Set<String> _refreshedUploads = {};

  @override
  void initState() {
    super.initState();
    widget.transfers.addListener(_onTransfersChanged);
    unawaited(_browser.load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    widget.transfers.removeListener(_onTransfersChanged);
    _browser.dispose();
    super.dispose();
  }

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
      child: ListenableBuilder(
        listenable: _browser,
        builder: (context, child) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            _buildToolbar(colors),
            if (_browser.status == SftpBrowserStatus.loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_browser.status == SftpBrowserStatus.failure)
              _DrawerError(
                message: _browser.errorMessage ?? '读取远程目录失败。',
                onRetry: _browser.load,
              )
            else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
                child: Text(
                  '${_browser.loadedCount} 个项目',
                  style: TextStyle(color: colors.onSurface3, fontSize: 10.5),
                ),
              ),
              if (_browser.path != '/')
                _FileRow(
                  name: '..',
                  suffix: '上级',
                  icon: Icons.folder_rounded,
                  onTap: _browser.goUp,
                ),
              for (final item in _browser.visibleEntries)
                _FileRow(
                  name: item.name,
                  suffix: _formatSize(item.size),
                  icon: item.isDirectory
                      ? Icons.folder_rounded
                      : item.name.endsWith('.conf') || item.name.endsWith('.sh')
                      ? Icons.code_rounded
                      : Icons.description_rounded,
                  onTap: () => _openEntry(item),
                  onLongPress: () => _showFileActions(item),
                ),
              if (_browser.visibleEntries.isEmpty)
                const _EmptyCommands(
                  icon: Icons.folder_open_rounded,
                  label: '目录为空',
                ),
            ],
            _buildTransfers(),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(ShellyColors colors) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _browser.path,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurface3,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
            PopupMenuButton<RemoteFileSort>(
              tooltip: '排序',
              icon: const Icon(Icons.sort_rounded, size: 19),
              onSelected: _browser.setSort,
              itemBuilder: (context) => const [
                PopupMenuItem(value: RemoteFileSort.name, child: Text('按名称')),
                PopupMenuItem(
                  value: RemoteFileSort.modified,
                  child: Text('按时间'),
                ),
                PopupMenuItem(value: RemoteFileSort.size, child: Text('按大小')),
              ],
            ),
            ShellyIconButton(
              icon: Icons.create_new_folder_outlined,
              tooltip: '新建目录',
              dimension: 38,
              size: 18,
              onPressed: _createDirectory,
            ),
            ShellyIconButton(
              icon: Icons.upload_rounded,
              tooltip: '上传',
              dimension: 38,
              size: 18,
              active: true,
              onPressed: _pickUpload,
            ),
            ShellyIconButton(
              icon: Icons.refresh_rounded,
              tooltip: '刷新',
              dimension: 38,
              size: 18,
              onPressed: _browser.load,
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _searchController,
          onChanged: _browser.search,
          decoration: InputDecoration(
            hintText: '搜索当前目录',
            prefixIcon: const Icon(Icons.search_rounded),
            isDense: true,
            filled: true,
            fillColor: colors.surface2,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTransfers() {
    return ListenableBuilder(
      listenable: widget.transfers,
      builder: (context, child) {
        if (widget.transfers.tasks.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '传输',
                style: TextStyle(
                  color: context.shelly.onSurface2,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              for (final task in widget.transfers.tasks)
                _TransferTile(task: task, transfers: widget.transfers),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openEntry(RemoteFileEntry entry) async {
    if (entry.isDirectory) {
      await _browser.openDirectory(entry);
      return;
    }
    await _showFileActions(entry);
  }

  Future<void> _showFileActions(RemoteFileEntry entry) async {
    HapticFeedback.mediumImpact();
    final action = await showModalBottomSheet<_FileAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.78,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (entry.isFile)
                  ListTile(
                    leading: const Icon(Icons.download_rounded),
                    title: const Text('下载'),
                    onTap: () => Navigator.pop(context, _FileAction.download),
                  ),
                if (entry.isFile)
                  ListTile(
                    leading: const Icon(Icons.preview_rounded),
                    title: const Text('文本预览'),
                    onTap: () => Navigator.pop(context, _FileAction.preview),
                  ),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('属性'),
                  onTap: () => Navigator.pop(context, _FileAction.properties),
                ),
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('复制路径'),
                  onTap: () => Navigator.pop(context, _FileAction.copyPath),
                ),
                ListTile(
                  leading: const Icon(Icons.drive_file_rename_outline_rounded),
                  title: const Text('重命名'),
                  onTap: () => Navigator.pop(context, _FileAction.rename),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('删除'),
                  onTap: () => Navigator.pop(context, _FileAction.delete),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _FileAction.download:
        await _download(entry);
        return;
      case _FileAction.preview:
        await _preview(entry);
        return;
      case _FileAction.properties:
        await _showProperties(entry);
        return;
      case _FileAction.copyPath:
        await Clipboard.setData(ClipboardData(text: entry.path));
        if (mounted) _message('已复制路径');
        return;
      case _FileAction.rename:
        await _rename(entry);
        return;
      case _FileAction.delete:
        await _delete(entry);
        return;
    }
  }

  Future<void> _pickUpload() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(withData: false);
    } on Object {
      if (mounted) _message('打开文件选择器失败，请重试。');
      return;
    }
    if (!mounted || result == null || result.files.single.path == null) return;
    final localPath = result.files.single.path!;
    var remoteName = result.files.single.name;
    if (_browser.containsName(remoteName)) {
      final choice = await _resolveConflict(context, remoteName);
      if (!mounted || choice == null || choice == _ConflictChoice.skip) return;
      if (choice == _ConflictChoice.rename) {
        final renamed = await _promptName(
          context,
          title: '上传为',
          initial: remoteName,
        );
        if (!mounted || renamed == null) return;
        remoteName = renamed;
      }
    }
    final remotePath = joinRemotePath(_browser.path, remoteName);
    widget.transfers.enqueueUpload(
      localPath: localPath,
      remotePath: remotePath,
    );
    _message('已加入上传队列');
  }

  Future<void> _download(RemoteFileEntry entry) async {
    String? directory;
    try {
      directory = await FilePicker.getDirectoryPath();
    } on Object {
      if (mounted) _message('打开保存位置失败，请重试。');
      return;
    }
    if (!mounted || directory == null) return;
    var result = path.join(directory, entry.name);
    final exists = await File(result).exists();
    if (!mounted) return;
    if (exists) {
      final choice = await _resolveConflict(context, path.basename(result));
      if (!mounted || choice == null || choice == _ConflictChoice.skip) return;
      if (choice == _ConflictChoice.rename) {
        final renamed = await _promptName(
          context,
          title: '保存为',
          initial: path.basename(result),
        );
        if (!mounted || renamed == null) return;
        result = path.join(path.dirname(result), renamed);
      }
    }
    widget.transfers.enqueueDownload(remotePath: entry.path, localPath: result);
    _message('已加入下载队列');
  }

  Future<void> _preview(RemoteFileEntry entry) async {
    try {
      final content = await _browser.preview(entry);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(entry.name),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(
                content,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
          ),
        ),
      );
    } on SftpFailure catch (error) {
      if (mounted) _message(error.message);
    }
  }

  Future<void> _showProperties(RemoteFileEntry entry) async {
    try {
      final details = await _browser.stat(entry);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(details.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(details.path),
              const SizedBox(height: 12),
              Text('类型：${_entryType(details.type)}'),
              Text('大小：${_formatSize(details.size)}'),
              Text('权限：${details.permissions ?? '未知'}'),
              Text('修改时间：${_formatDate(details.modifiedAt)}'),
            ],
          ),
        ),
      );
    } on SftpFailure catch (error) {
      if (mounted) _message(error.message);
    }
  }

  Future<void> _createDirectory() async {
    final name = await _promptName(context, title: '新建目录');
    if (name == null || !mounted) return;
    try {
      await _browser.createDirectory(name);
    } on SftpFailure catch (error) {
      _message(error.message);
    }
  }

  Future<void> _rename(RemoteFileEntry entry) async {
    final name = await _promptName(context, title: '重命名', initial: entry.name);
    if (name == null || !mounted) return;
    try {
      await _browser.rename(entry, name);
    } on SftpFailure catch (error) {
      _message(error.message);
    }
  }

  Future<void> _delete(RemoteFileEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${entry.name}？'),
        content: Text(entry.isDirectory ? '目录及其内容将被删除。' : '此操作无法撤销。'),
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
    if (confirmed != true || !mounted) return;
    try {
      await _browser.delete(entry, recursive: entry.isDirectory);
    } on SftpFailure catch (error) {
      _message(error.message);
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  void _onTransfersChanged() {
    for (final task in widget.transfers.tasks) {
      if (task.direction != SftpTransferDirection.upload ||
          task.status != SftpTransferStatus.completed ||
          !_refreshedUploads.add(task.id)) {
        continue;
      }
      if (parentRemotePath(task.remotePath) == _browser.path) {
        unawaited(_browser.load());
      }
    }
  }
}

enum _FileAction { download, preview, properties, copyPath, rename, delete }

enum _ConflictChoice { overwrite, rename, skip }

Future<_ConflictChoice?> _resolveConflict(BuildContext context, String name) {
  return showDialog<_ConflictChoice>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('$name 已存在'),
      content: const Text('目标文件已经存在。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, _ConflictChoice.skip),
          child: const Text('跳过'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _ConflictChoice.rename),
          child: const Text('重命名'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ConflictChoice.overwrite),
          child: const Text('覆盖'),
        ),
      ],
    ),
  );
}

Future<String?> _promptName(
  BuildContext context, {
  required String title,
  String initial = '',
}) async {
  final result = await showDialog<String>(
    context: context,
    builder: (context) => _NameDialog(title: title, initial: initial),
  );
  return result == null || result.isEmpty ? null : result;
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
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
      title: Text(widget.title),
      content: TextField(controller: _controller, autofocus: true),
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

class _TransferTile extends StatelessWidget {
  const _TransferTile({required this.task, required this.transfers});

  final SftpTransferTask task;
  final SftpTransferController transfers;

  @override
  Widget build(BuildContext context) {
    final active =
        task.status == SftpTransferStatus.running ||
        task.status == SftpTransferStatus.paused;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: context.shelly.surface2,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    task.direction == SftpTransferDirection.upload
                        ? Icons.upload_rounded
                        : Icons.download_rounded,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(task.name, overflow: TextOverflow.ellipsis),
                  ),
                  if (active)
                    IconButton(
                      icon: Icon(
                        task.status == SftpTransferStatus.paused
                            ? Icons.play_arrow_rounded
                            : Icons.pause_rounded,
                      ),
                      iconSize: 18,
                      onPressed: () => task.status == SftpTransferStatus.paused
                          ? transfers.resume(task.id)
                          : transfers.pause(task.id),
                    ),
                  if (active || task.status == SftpTransferStatus.queued)
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      iconSize: 18,
                      onPressed: () => transfers.cancel(task.id),
                    ),
                  if (!active && task.status != SftpTransferStatus.queued)
                    IconButton(
                      tooltip: '移除记录',
                      icon: const Icon(Icons.close_rounded),
                      iconSize: 18,
                      onPressed: () => transfers.removeFinished(task.id),
                    ),
                ],
              ),
              if (task.progress != null)
                LinearProgressIndicator(value: task.progress)
              else if (task.status == SftpTransferStatus.running)
                const LinearProgressIndicator(),
              const SizedBox(height: 4),
              Text(
                task.errorMessage ?? _transferSummary(task),
                style: TextStyle(
                  color: context.shelly.onSurface3,
                  fontSize: 10,
                ),
              ),
              if (task.status == SftpTransferStatus.failed ||
                  task.status == SftpTransferStatus.cancelled)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => transfers.retry(task.id),
                    child: const Text('重试'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _transferStatus(SftpTransferStatus status) => switch (status) {
    SftpTransferStatus.queued => '排队中',
    SftpTransferStatus.running => '传输中',
    SftpTransferStatus.paused => '已暂停',
    SftpTransferStatus.completed => '已完成',
    SftpTransferStatus.failed => '失败',
    SftpTransferStatus.cancelled => '已取消',
  };

  String _transferSummary(SftpTransferTask task) {
    final status = _transferStatus(task.status);
    if (task.status == SftpTransferStatus.queued) return status;
    final progress = task.totalBytes == null
        ? _formatSize(task.transferredBytes)
        : '${_formatSize(task.transferredBytes)} / ${_formatSize(task.totalBytes)}';
    final speed =
        task.bytesPerSecond == null ||
            task.status == SftpTransferStatus.completed
        ? ''
        : ' · ${_formatSize(task.bytesPerSecond!.round())}/s';
    return '$status · $progress$speed';
  }
}

String _formatSize(int? size) {
  if (size == null) return '—';
  if (size < 1024) return '$size B';
  if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
  if (size < 1024 * 1024 * 1024) {
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String _entryType(RemoteEntryType type) => switch (type) {
  RemoteEntryType.file => '文件',
  RemoteEntryType.directory => '目录',
  RemoteEntryType.symbolicLink => '符号链接',
  RemoteEntryType.other => '其他',
};

String _formatDate(DateTime? value) {
  if (value == null) return '未知';
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
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
