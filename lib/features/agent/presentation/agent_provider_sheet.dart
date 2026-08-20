import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/app_theme.dart';
import '../../../ui/settings_tiles.dart';
import '../data/agent_settings_repository.dart';
import '../domain/agent_provider_config.dart';
import 'agent_form_sheet.dart';

/// Provider manager: list, add, edit, set default, delete.
///
/// API keys are typed here and handed straight to
/// [AgentSettingsRepository], which stores them in secure storage. The key is
/// never read back into the form — an existing key can only be replaced or
/// cleared.
Future<void> showAgentProviderSheet(
  BuildContext context,
  AgentSettingsRepository settings,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.8,
      child: _ProviderSheet(settings: settings),
    ),
  );
}

class _ProviderSheet extends StatefulWidget {
  const _ProviderSheet({required this.settings});

  final AgentSettingsRepository settings;

  @override
  State<_ProviderSheet> createState() => _ProviderSheetState();
}

class _ProviderSheetState extends State<_ProviderSheet> {
  List<AgentProviderConfig> _providers = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final providers = await widget.settings.listProviders();
      if (!mounted) return;
      setState(() {
        _providers = providers;
        _error = null;
        _loading = false;
      });
    } on AgentSettingsException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _add() async {
    final draft = await showAgentProviderEditor(context);
    if (draft == null) return;
    try {
      await widget.settings.createProvider(draft);
    } on AgentSettingsException catch (error) {
      _report(error.message);
      return;
    }
    await _load();
  }

  Future<void> _edit(AgentProviderConfig provider) async {
    final draft = await showAgentProviderEditor(context, existing: provider);
    if (draft == null) return;
    try {
      await widget.settings.updateProvider(provider, draft);
    } on AgentSettingsException catch (error) {
      _report(error.message);
      return;
    }
    await _load();
  }

  Future<void> _setDefault(AgentProviderConfig provider) async {
    try {
      await widget.settings.setDefaultProvider(provider);
    } on AgentSettingsException catch (error) {
      _report(error.message);
      return;
    }
    await _load();
  }

  Future<void> _delete(AgentProviderConfig provider) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除 Provider'),
        content: Text('「${provider.name}」及其保存在安全存储里的 API Key 都会被删除。'),
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
    if (confirmed != true) return;
    try {
      await widget.settings.deleteProvider(provider);
    } on AgentSettingsException catch (error) {
      _report(error.message);
      return;
    }
    await _load();
  }

  void _report(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        children: [
          SheetHeader(
            icon: Icons.cloud_outlined,
            title: 'Agent Provider',
            subtitle: 'API Key 只保存在系统安全存储中',
            actions: [
              IconButton(
                onPressed: () => unawaited(_add()),
                tooltip: '添加',
                icon: const Icon(Icons.add_rounded),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                tooltip: '关闭',
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          if (_error case final message?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 11.5,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          Expanded(child: _buildList(context)),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_providers.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 30,
                color: context.shelly.onSurface3,
              ),
              const SizedBox(height: 10),
              Text(
                '还没有 Provider，点右上角添加。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: context.shelly.onSurface3,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: _providers.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) => _buildRow(context, _providers[index]),
    );
  }

  Widget _buildRow(BuildContext context, AgentProviderConfig provider) {
    final colors = context.shelly;
    return ListTile(
      leading: Icon(
        provider.isDefault ? Icons.star_rounded : Icons.cloud_outlined,
        size: 19,
        color: provider.isDefault ? colors.primary : null,
      ),
      title: Text(provider.name, style: const TextStyle(fontSize: 13)),
      subtitle: Text(
        '${provider.summary}\n${provider.requestUri}\n'
        '${provider.hasApiKey ? '已保存 API Key' : '未配置 API Key'}'
        ' · 超时 ${provider.timeout.inSeconds}s · 最多 ${provider.maxLoops} 轮工具循环',
        style: const TextStyle(fontSize: 10.5, height: 1.5),
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<_ProviderAction>(
        tooltip: '更多',
        onSelected: (action) => unawaited(switch (action) {
          _ProviderAction.edit => _edit(provider),
          _ProviderAction.setDefault => _setDefault(provider),
          _ProviderAction.delete => _delete(provider),
        }),
        itemBuilder: (context) => [
          const PopupMenuItem(value: _ProviderAction.edit, child: Text('编辑')),
          if (!provider.isDefault)
            const PopupMenuItem(
              value: _ProviderAction.setDefault,
              child: Text('设为默认'),
            ),
          const PopupMenuItem(value: _ProviderAction.delete, child: Text('删除')),
        ],
      ),
      onTap: () => unawaited(_edit(provider)),
    );
  }
}

enum _ProviderAction { edit, setDefault, delete }

/// Opens the provider form. Returns the draft to persist, or null on cancel.
Future<AgentProviderDraft?> showAgentProviderEditor(
  BuildContext context, {
  AgentProviderConfig? existing,
}) {
  return showAgentFormSheet<AgentProviderDraft>(
    context,
    builder: (context) => _ProviderEditor(existing: existing),
  );
}

class _ProviderEditor extends StatefulWidget {
  const _ProviderEditor({this.existing});

  final AgentProviderConfig? existing;

  @override
  State<_ProviderEditor> createState() => _ProviderEditorState();
}

class _ProviderEditorState extends State<_ProviderEditor> {
  final _form = GlobalKey<FormState>();
  final _apiKey = TextEditingController();
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _model = TextEditingController(text: widget.existing?.model ?? '');
  late final _endpoint = TextEditingController(
    text: widget.existing?.endpoint ?? _defaultEndpoint(_protocol),
  );
  late final _timeout = TextEditingController(
    text: (widget.existing?.timeout ?? AgentProviderConfig.defaultTimeout)
        .inSeconds
        .toString(),
  );
  late final _maxLoops = TextEditingController(
    text: (widget.existing?.maxLoops ?? AgentProviderConfig.defaultMaxLoops)
        .toString(),
  );
  late final _maxOutputTokens = TextEditingController(
    text:
        (widget.existing?.maxOutputTokens ??
                AgentProviderConfig.defaultMaxOutputTokens)
            .toString(),
  );

  late AgentProviderProtocol _protocol =
      widget.existing?.protocol ?? AgentProviderProtocol.messages;
  bool _clearApiKey = false;
  bool _obscureApiKey = true;

  @override
  void dispose() {
    _name.dispose();
    _model.dispose();
    _endpoint.dispose();
    _apiKey.dispose();
    _timeout.dispose();
    _maxLoops.dispose();
    _maxOutputTokens.dispose();
    super.dispose();
  }

  /// Switching protocol only rewrites an endpoint the user has not customised.
  void _changeProtocol(AgentProviderProtocol protocol) {
    setState(() {
      final current = _endpoint.text.trim();
      final wasDefault =
          current.isEmpty ||
          AgentProviderProtocol.values.any(
            (candidate) => _defaultEndpoint(candidate) == current,
          );
      _protocol = protocol;
      if (wasDefault) _endpoint.text = _defaultEndpoint(protocol);
    });
  }

  void _submit() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final typed = _apiKey.text.trim();
    final apiKey = _clearApiKey
        ? ''
        : typed.isEmpty
        ? null
        : typed;
    Navigator.pop(
      context,
      AgentProviderDraft(
        name: _name.text.trim(),
        protocol: _protocol,
        endpoint: _endpoint.text.trim(),
        model: _model.text.trim(),
        timeout: Duration(seconds: int.parse(_timeout.text.trim())),
        maxLoops: int.parse(_maxLoops.text.trim()),
        maxOutputTokens: int.parse(_maxOutputTokens.text.trim()),
        apiKey: apiKey,
      ),
    );
  }

  String? _validateApiKey(String? value) {
    if (widget.existing != null || _clearApiKey) return null;
    return (value ?? '').trim().isEmpty ? '新建 Provider 需要填写 API Key。' : null;
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          SheetHeader(
            icon: Icons.tune_rounded,
            title: existing == null ? '添加 Provider' : '编辑 Provider',
            subtitle: _protocol.description,
            actions: [
              IconButton(
                onPressed: _submit,
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
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                children: [
                  SegmentedButton<AgentProviderProtocol>(
                    segments: [
                      for (final protocol in AgentProviderProtocol.values)
                        ButtonSegment(
                          value: protocol,
                          label: Text(protocol.label),
                        ),
                    ],
                    selected: {_protocol},
                    showSelectedIcon: false,
                    onSelectionChanged: (selection) =>
                        _changeProtocol(selection.first),
                  ),
                  const SizedBox(height: 16),
                  AgentFormField(
                    controller: _name,
                    label: '名称',
                    hint: '例如 Claude 生产 Key',
                    validator: (value) =>
                        (value ?? '').trim().isEmpty ? '名称不能为空。' : null,
                  ),
                  AgentFormField(
                    controller: _endpoint,
                    label: 'Endpoint',
                    helper: '填基地址即可，应用会补上协议路径；已经带 /v1 也不会重复拼接。',
                    keyboardType: TextInputType.url,
                    validator: _validateEndpoint,
                  ),
                  _RequestUrlPreview(endpoint: _endpoint, protocol: _protocol),
                  AgentFormField(
                    controller: _model,
                    label: '模型',
                    hint: _protocol == AgentProviderProtocol.messages
                        ? 'claude-sonnet-4-5'
                        : 'gpt-5',
                    validator: (value) =>
                        (value ?? '').trim().isEmpty ? '模型不能为空。' : null,
                  ),
                  AgentFormField(
                    controller: _apiKey,
                    label: 'API Key',
                    hint: existing == null ? null : '留空表示保留已保存的 Key',
                    helper: 'Key 只写入系统安全存储，不会进入数据库、日志或模型上下文。',
                    obscureText: _obscureApiKey,
                    enabled: !_clearApiKey,
                    suffix: IconButton(
                      onPressed: () =>
                          setState(() => _obscureApiKey = !_obscureApiKey),
                      tooltip: _obscureApiKey ? '显示' : '隐藏',
                      icon: Icon(
                        _obscureApiKey
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 18,
                      ),
                    ),
                    validator: _validateApiKey,
                  ),
                  if (existing?.hasApiKey ?? false)
                    SwitchListTile(
                      value: _clearApiKey,
                      onChanged: (value) =>
                          setState(() => _clearApiKey = value),
                      title: const Text(
                        '清除已保存的 API Key',
                        style: TextStyle(fontSize: 12.5),
                      ),
                      subtitle: const Text(
                        '打开后保存时会删除安全存储里的 Key。',
                        style: TextStyle(fontSize: 11),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  const SizedBox(height: 6),
                  AgentFormField(
                    controller: _timeout,
                    label: '单次请求超时（秒）',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (value) => _validateInt(value, 5, 600),
                  ),
                  AgentFormField(
                    controller: _maxLoops,
                    label: '每轮最多工具循环次数',
                    helper: '模型连续调用工具的上限，超过后本轮结束。',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (value) => _validateInt(value, 1, 64),
                  ),
                  AgentFormField(
                    controller: _maxOutputTokens,
                    label: '单次最大输出 tokens',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (value) => _validateInt(value, 256, 32768),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Live preview of the URL that will actually be POSTed, so a wrong base URL is
/// visible before the first 404 instead of after it.
class _RequestUrlPreview extends StatelessWidget {
  const _RequestUrlPreview({required this.endpoint, required this.protocol});

  final TextEditingController endpoint;
  final AgentProviderProtocol protocol;

  @override
  Widget build(BuildContext context) {
    final colors = context.shelly;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: endpoint,
      builder: (context, value, child) {
        final url = AgentProviderConfig.resolveRequestUrl(value.text, protocol);
        if (url.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.link_rounded, size: 13, color: colors.onSurface3),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'POST $url',
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.4,
                    fontFamily: 'monospace',
                    color: colors.onSurface2,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _defaultEndpoint(AgentProviderProtocol protocol) => switch (protocol) {
  AgentProviderProtocol.messages => 'https://api.anthropic.com',
  AgentProviderProtocol.responses => 'https://api.openai.com',
};

String? _validateEndpoint(String? value) {
  final text = (value ?? '').trim();
  if (text.isEmpty) return 'Endpoint 不能为空。';
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.isScheme('https') && !uri.isScheme('http')) {
    return '请填写以 http:// 或 https:// 开头的地址。';
  }
  if (uri.host.isEmpty) return '地址缺少主机名。';
  return null;
}

String? _validateInt(String? value, int min, int max) {
  final parsed = int.tryParse((value ?? '').trim());
  if (parsed == null) return '请填写数字。';
  if (parsed < min || parsed > max) return '请填写 $min ~ $max 之间的数字。';
  return null;
}
