import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui/settings_tiles.dart';
import '../data/agent_settings_repository.dart';
import '../domain/agent_provider_config.dart';
import 'agent_form_sheet.dart';

/// Web Search settings.
///
/// The app performs the search itself and injects the results as a tool result,
/// so the search key never reaches the model. The key is stored in secure
/// storage exactly like a provider key.
Future<WebSearchConfig?> showAgentWebSearchSheet(
  BuildContext context, {
  required AgentSettingsRepository settings,
  required WebSearchConfig config,
}) {
  return showAgentFormSheet<WebSearchConfig>(
    context,
    builder: (context) => _WebSearchSheet(settings: settings, config: config),
  );
}

class _WebSearchSheet extends StatefulWidget {
  const _WebSearchSheet({required this.settings, required this.config});

  final AgentSettingsRepository settings;
  final WebSearchConfig config;

  @override
  State<_WebSearchSheet> createState() => _WebSearchSheetState();
}

class _WebSearchSheetState extends State<_WebSearchSheet> {
  final _form = GlobalKey<FormState>();
  final _apiKey = TextEditingController();
  late final _endpoint = TextEditingController(text: widget.config.endpoint);
  late final _timeout = TextEditingController(
    text: widget.config.timeout.inSeconds.toString(),
  );
  late final _maxResults = TextEditingController(
    text: widget.config.maxResults.toString(),
  );
  late bool _enabled = widget.config.enabled;
  bool _clearApiKey = false;
  bool _obscureApiKey = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _endpoint.dispose();
    _apiKey.dispose();
    _timeout.dispose();
    _maxResults.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final typed = _apiKey.text.trim();
    final apiKey = _clearApiKey
        ? ''
        : typed.isEmpty
        ? null
        : typed;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.settings.saveWebSearch(
        WebSearchConfig(
          enabled: _enabled,
          endpoint: _endpoint.text.trim(),
          credentialRef: widget.config.credentialRef,
          timeout: Duration(seconds: int.parse(_timeout.text.trim())),
          maxResults: int.parse(_maxResults.text.trim()),
        ),
        apiKey: apiKey,
      );
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

  String? _validateEndpoint(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return _enabled ? '启用后必须填写接口地址。' : null;
    final uri = Uri.tryParse(text);
    if (uri == null || (!uri.isScheme('https') && !uri.isScheme('http'))) {
      return '请填写以 http:// 或 https:// 开头的地址。';
    }
    if (uri.host.isEmpty) return '地址缺少主机名。';
    return null;
  }

  String? _validateApiKey(String? value) {
    if (!_enabled || _clearApiKey) return null;
    if (widget.config.credentialRef != null) return null;
    return (value ?? '').trim().isEmpty ? '启用后必须填写 API Key。' : null;
  }

  String? _validateInt(String? value, int min, int max) {
    final parsed = int.tryParse((value ?? '').trim());
    if (parsed == null) return '请填写数字。';
    if (parsed < min || parsed > max) return '请填写 $min ~ $max 之间的数字。';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = widget.config.credentialRef != null;
    return SafeArea(
      top: false,
      child: Column(
        children: [
          SheetHeader(
            icon: Icons.travel_explore_outlined,
            title: 'Web Search',
            subtitle: '由应用发起搜索并注入结果，模型看不到搜索 Key',
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
            child: Form(
              key: _form,
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
                  SwitchListTile(
                    value: _enabled,
                    onChanged: (value) => setState(() => _enabled = value),
                    title: const Text(
                      '启用 web_search 工具',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      '关闭后模型看不到这个工具。',
                      style: TextStyle(fontSize: 11),
                    ),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 10),
                  AgentFormField(
                    controller: _endpoint,
                    label: '搜索接口地址',
                    hint: 'https://api.tavily.com/search',
                    helper:
                        '应用以 POST + Bearer 鉴权发送 {"query", "max_results"}，'
                        '期望返回 Tavily 形状的 results 数组。',
                    keyboardType: TextInputType.url,
                    validator: _validateEndpoint,
                  ),
                  AgentFormField(
                    controller: _apiKey,
                    label: 'API Key',
                    hint: hasKey ? '留空表示保留已保存的 Key' : null,
                    helper: 'Key 只写入系统安全存储，模型永远看不到它。',
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
                  if (hasKey)
                    SwitchListTile(
                      value: _clearApiKey,
                      onChanged: (value) =>
                          setState(() => _clearApiKey = value),
                      title: const Text(
                        '清除已保存的 API Key',
                        style: TextStyle(fontSize: 12.5),
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  const SizedBox(height: 6),
                  AgentFormField(
                    controller: _timeout,
                    label: '搜索超时（秒）',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (value) => _validateInt(value, 5, 120),
                  ),
                  AgentFormField(
                    controller: _maxResults,
                    label: '每次最多返回条数',
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    validator: (value) => _validateInt(value, 1, 10),
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
