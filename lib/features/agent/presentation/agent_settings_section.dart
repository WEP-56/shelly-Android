import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/settings_tiles.dart';
import '../data/agent_session_repository.dart';
import '../data/agent_settings_repository.dart';
import '../domain/agent_provider_config.dart';
import 'agent_provider_sheet.dart';
import 'agent_sessions_admin_sheet.dart';
import 'agent_web_search_sheet.dart';
import 'agent_work_spec_sheet.dart';

/// The Agent block of the settings page: provider管理, work spec, Web Search and
/// cross-host session管理.
///
/// Summaries are read on mount and after every sheet closes. No API key is read
/// back here — only whether one is stored.
class AgentSettingsSection extends StatefulWidget {
  const AgentSettingsSection({
    required this.settings,
    required this.sessions,
    required this.hostNames,
    super.key,
  });

  final AgentSettingsRepository settings;
  final AgentSessionRepository sessions;

  /// Host id → display name, used to group the session list.
  final Map<String, String> hostNames;

  @override
  State<AgentSettingsSection> createState() => _AgentSettingsSectionState();
}

class _AgentSettingsSectionState extends State<AgentSettingsSection> {
  AgentProviderConfig? _provider;
  int _providerCount = 0;
  WebSearchConfig _webSearch = const WebSearchConfig();
  String _workSpec = '';
  int _sessionCount = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final providers = await widget.settings.listProviders();
      final webSearch = await widget.settings.loadWebSearch();
      final workSpec = await widget.settings.loadWorkSpec();
      final sessions = await widget.sessions.list();
      if (!mounted) return;
      setState(() {
        _providerCount = providers.length;
        _provider = providers.isEmpty
            ? null
            : providers.firstWhere(
                (provider) => provider.isDefault,
                orElse: () => providers.first,
              );
        _webSearch = webSearch;
        _workSpec = workSpec;
        _sessionCount = sessions.length;
        _error = null;
        _loading = false;
      });
    } on AgentSettingsException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } on AgentSessionException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _openProviders() async {
    await showAgentProviderSheet(context, widget.settings);
    await _load();
  }

  Future<void> _openWorkSpec() async {
    final saved = await showAgentWorkSpecSheet(
      context,
      settings: widget.settings,
      spec: _workSpec,
    );
    if (saved == null || !mounted) return;
    setState(() => _workSpec = saved);
  }

  Future<void> _openWebSearch() async {
    final saved = await showAgentWebSearchSheet(
      context,
      settings: widget.settings,
      config: _webSearch,
    );
    if (saved == null || !mounted) return;
    setState(() => _webSearch = saved);
  }

  Future<void> _openSessions() async {
    await showAgentSessionsAdminSheet(
      context,
      sessions: widget.sessions,
      hostNames: widget.hostNames,
    );
    await _load();
  }

  String get _providerHint {
    if (_loading) return '读取中…';
    if (_error case final message?) return message;
    if (_provider case final provider?) {
      final suffix = _providerCount > 1 ? ' · 共 $_providerCount 个' : '';
      return '${provider.name} · ${provider.summary}'
          '${provider.hasApiKey ? '' : ' · 缺少 API Key'}$suffix';
    }
    return '未配置，Agent 面板不可用';
  }

  String get _workSpecHint {
    if (_loading) return '读取中…';
    return _workSpec.trim().isEmpty ? '未填写' : '已填写 ${_workSpec.length} 字';
  }

  String get _webSearchHint {
    if (_loading) return '读取中…';
    if (!_webSearch.enabled) return '已关闭';
    return _webSearch.isUsable ? '已开启 · ${_webSearch.endpoint}' : '已开启但配置不完整';
  }

  String get _sessionHint {
    if (_loading) return '读取中…';
    return _sessionCount == 0 ? '还没有对话记录' : '$_sessionCount 个会话';
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSection(
      label: 'Agent',
      children: [
        SettingsRow(
          icon: Icons.cloud_outlined,
          label: 'Provider',
          hint: _providerHint,
          onTap: () => unawaited(_openProviders()),
        ),
        SettingsRow(
          icon: Icons.description_outlined,
          label: '工作规范',
          hint: _workSpecHint,
          onTap: () => unawaited(_openWorkSpec()),
        ),
        SettingsRow(
          icon: Icons.travel_explore_outlined,
          label: 'Web Search',
          hint: _webSearchHint,
          onTap: () => unawaited(_openWebSearch()),
        ),
        SettingsRow(
          icon: Icons.forum_outlined,
          label: '会话管理',
          hint: _sessionHint,
          onTap: () => unawaited(_openSessions()),
        ),
      ],
    );
  }
}
