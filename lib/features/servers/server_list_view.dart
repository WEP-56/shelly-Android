import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_theme.dart';
import '../../app/models.dart';
import '../../core/security/app_lock_settings.dart';
import '../security/application/app_lock_controller.dart';
import '../security/presentation/app_lock_gate.dart';

typedef HostSaveCallback = Future<String?> Function(HostSaveRequest request);

class ServerListView extends StatelessWidget {
  const ServerListView({
    required this.servers,
    required this.onConnect,
    required this.onSave,
    required this.onDelete,
    required this.appLock,
    super.key,
  });

  final List<HostProfile> servers;
  final ValueChanged<HostProfile> onConnect;
  final HostSaveCallback onSave;
  final ValueChanged<HostProfile> onDelete;

  /// Guards the editor of an already saved host, where the stored password or
  /// private key can be replaced. Adding a new host is not guarded.
  final AppLockController appLock;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return ListView(
      padding: const EdgeInsets.fromLTRB(15, 3, 15, 150),
      children: [
        for (var index = 0; index < servers.length; index++) ...[
          _ServerCard(
            server: servers[index],
            onTap: () => onConnect(servers[index]),
            onLongPress: () => _showActions(context, servers[index]),
          ),
          if (index != servers.length - 1) const SizedBox(height: 10),
        ],
        if (servers.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 72),
            child: Column(
              children: [
                Icon(Icons.cloud_outlined, color: colors.onSurface3, size: 30),
                const SizedBox(height: 12),
                Text(
                  '还没有设备',
                  style: TextStyle(color: colors.onSurface3, fontSize: 12),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              '点击进入终端 · 长按管理设备',
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurface3, fontSize: 10.5),
            ),
          ),
      ],
    );
  }

  Future<void> _showActions(BuildContext context, HostProfile server) async {
    HapticFeedback.mediumImpact();
    final action = await showModalBottomSheet<_ServerAction>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded),
                title: const Text('连接'),
                onTap: () => Navigator.pop(context, _ServerAction.connect),
              ),
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('编辑'),
                onTap: () => Navigator.pop(context, _ServerAction.edit),
              ),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('复制地址'),
                onTap: () => Navigator.pop(context, _ServerAction.copy),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('删除'),
                onTap: () => Navigator.pop(context, _ServerAction.delete),
              ),
            ],
          ),
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case _ServerAction.connect:
        onConnect(server);
      case _ServerAction.edit:
        await _editServer(context, server);
      case _ServerAction.copy:
        await Clipboard.setData(
          ClipboardData(text: '${server.host}:${server.port}'),
        );
        if (context.mounted) _message(context, '已复制');
      case _ServerAction.delete:
        final confirmed = await _confirmDelete(context, server);
        if (confirmed && context.mounted) onDelete(server);
    }
  }

  /// Opening a saved host's editor is a credential surface: it can overwrite the
  /// stored password or private key, so it goes through the app lock.
  Future<void> _editServer(BuildContext context, HostProfile server) async {
    final unlocked = await ensureAppLockUnlocked(
      context,
      appLock,
      AppLockScope.hostCredentials,
    );
    if (!unlocked || !context.mounted) return;
    appLock.markSurfaceOpen(AppLockScope.hostCredentials);
    try {
      await showServerEditor(context, server: server, onSave: onSave);
    } finally {
      appLock.markSurfaceClosed(AppLockScope.hostCredentials);
    }
  }

  Future<bool> _confirmDelete(BuildContext context, HostProfile server) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('删除设备？'),
            content: Text('将删除 ${server.name} 及其保存的认证资料。'),
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
        ) ??
        false;
  }

  void _message(BuildContext context, String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

enum _ServerAction { connect, edit, copy, delete }

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.onTap,
    required this.onLongPress,
  });

  final HostProfile server;
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
        child: SizedBox(
          height: 68,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.surface2,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.cloud_rounded,
                    size: 20,
                    color: colors.onSurface2,
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        server.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${server.host}:${server.port}  ·  ${server.username}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.onSurface3,
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    shape: BoxShape.circle,
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

Future<void> showServerEditor(
  BuildContext context, {
  HostProfile? server,
  required HostSaveCallback onSave,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _ServerEditor(server: server, onSave: onSave),
  );
}

class _ServerEditor extends StatefulWidget {
  const _ServerEditor({required this.onSave, this.server});

  final HostProfile? server;
  final HostSaveCallback onSave;

  @override
  State<_ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<_ServerEditor> {
  late final _name = TextEditingController(text: widget.server?.name);
  late final _host = TextEditingController(text: widget.server?.host);
  late final _port = TextEditingController(
    text: '${widget.server?.port ?? 22}',
  );
  late final _user = TextEditingController(
    text: widget.server?.username ?? 'root',
  );
  late final _password = TextEditingController();
  late final _privateKey = TextEditingController();
  late final _passphrase = TextEditingController();
  late HostAuthType _authType =
      widget.server?.authType ?? HostAuthType.password;
  String? _nameError;
  String? _hostError;
  String? _portError;
  String? _userError;
  String? _credentialError;
  String? _saveError;
  bool _isSaving = false;

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    _privateKey.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    widget.server == null
                        ? Icons.add_rounded
                        : Icons.edit_rounded,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    widget.server == null ? '添加设备' : '编辑设备',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _isSaving ? null : _submit,
                    tooltip: '保存',
                    icon: _isSaving
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                  ),
                ],
              ),
              if (_saveError != null) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _saveError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              _field(_name, '名称', errorText: _nameError),
              const SizedBox(height: 10),
              _field(_host, '主机地址', autofocus: true, errorText: _hostError),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _field(
                      _port,
                      '端口',
                      number: true,
                      errorText: _portError,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: _field(_user, '用户名', errorText: _userError)),
                ],
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<HostAuthType>(
                initialValue: _authType,
                decoration: InputDecoration(
                  labelText: '认证方式',
                  filled: true,
                  border: OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                items: const [
                  DropdownMenuItem(
                    value: HostAuthType.password,
                    child: Text('密码'),
                  ),
                  DropdownMenuItem(
                    value: HostAuthType.privateKey,
                    child: Text('私钥'),
                  ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _authType = value;
                    _credentialError = null;
                  });
                },
              ),
              const SizedBox(height: 10),
              if (_authType == HostAuthType.password)
                _field(
                  _password,
                  widget.server == null ? '密码' : '密码（留空保持不变）',
                  obscure: true,
                  errorText: _credentialError,
                )
              else ...[
                _field(
                  _privateKey,
                  widget.server == null ? '私钥内容' : '私钥内容（留空保持不变）',
                  maxLines: 4,
                  sensitive: true,
                  errorText: _credentialError,
                ),
                const SizedBox(height: 10),
                _field(_passphrase, '私钥口令（可选）', obscure: true),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String hint, {
    bool autofocus = false,
    bool number = false,
    bool obscure = false,
    bool sensitive = false,
    int maxLines = 1,
    String? errorText,
  }) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: obscure,
      autocorrect: !obscure && !sensitive,
      enableSuggestions: !obscure && !sensitive,
      enableIMEPersonalizedLearning: !obscure && !sensitive,
      smartDashesType: obscure || sensitive
          ? SmartDashesType.disabled
          : SmartDashesType.enabled,
      smartQuotesType: obscure || sensitive
          ? SmartQuotesType.disabled
          : SmartQuotesType.enabled,
      maxLines: obscure ? 1 : maxLines,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        hintText: hint,
        errorText: errorText,
        filled: true,
        border: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final user = _user.text.trim();
    final secret = _secret();
    setState(() {
      _nameError = name.isEmpty ? '请输入名称' : null;
      _hostError = host.isEmpty ? '请输入主机地址' : null;
      _portError = port == null || port < 1 || port > 65535 ? '端口无效' : null;
      _userError = user.isEmpty ? '请输入用户名' : null;
      _credentialError = _needsCredential(secret)
          ? (_authType == HostAuthType.password ? '请输入密码' : '请输入私钥')
          : null;
    });
    if (_nameError != null ||
        _hostError != null ||
        _portError != null ||
        _userError != null ||
        _credentialError != null) {
      return;
    }
    final request = HostSaveRequest(
      existing: widget.server,
      draft: HostDraft(
        name: name,
        host: host,
        port: port!,
        username: user,
        authType: _authType,
        secret: secret,
      ),
    );
    setState(() {
      _isSaving = true;
      _saveError = null;
    });
    final error = await widget.onSave(request);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _isSaving = false;
      _saveError = error;
    });
  }

  String? _secret() {
    if (_authType == HostAuthType.password) {
      final value = _password.text;
      return value.isEmpty ? null : value;
    }
    final key = _privateKey.text.trim();
    if (key.isEmpty) return null;
    return jsonEncode({'privateKey': key, 'passphrase': _passphrase.text});
  }

  bool _needsCredential(String? secret) {
    return secret == null &&
        (widget.server == null || widget.server!.authType != _authType);
  }
}
