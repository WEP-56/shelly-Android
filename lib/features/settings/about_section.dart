import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/settings_tiles.dart';
import '../update/application/update_controller.dart';
import '../update/presentation/update_release_dialog.dart';

/// About section of the settings page: installed version plus the manual
/// GitHub release check.
class AboutSection extends StatefulWidget {
  const AboutSection({super.key});

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection> {
  final UpdateController _controller = UpdateController();
  bool _versionUnavailable = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadVersion());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadVersion() async {
    try {
      await _controller.loadInstalledVersion();
    } on Object {
      // Reading the package version goes through a platform channel. Losing it
      // only blanks this row; the rest of settings keeps working.
      if (mounted) setState(() => _versionUnavailable = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, child) => SettingsSection(
        label: '关于',
        children: [
          SettingsRow(
            icon: Icons.info_outline_rounded,
            label: '版本',
            hint: _versionHint(),
          ),
          SettingsRow(
            icon: Icons.system_update_rounded,
            label: '检查更新',
            hint: _updateHint(),
            trailing: _controller.status == UpdateCheckStatus.checking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _controller.status == UpdateCheckStatus.checking
                ? null
                : _handleTap,
          ),
          const SettingsRow(
            icon: Icons.balance_rounded,
            label: '开源许可',
            hint: 'MIT',
          ),
        ],
      ),
    );
  }

  String _versionHint() {
    if (_versionUnavailable) return '版本信息不可用';
    final installed = _controller.installed;
    return installed == null ? '读取中…' : 'Shelly ${installed.display}';
  }

  String _updateHint() => switch (_controller.status) {
    UpdateCheckStatus.idle => '从 GitHub Releases 手动检查',
    UpdateCheckStatus.checking => '正在检查…',
    UpdateCheckStatus.upToDate => '已是最新版本',
    UpdateCheckStatus.updateAvailable =>
      '有新版本 ${_controller.latest?.tag ?? ''}',
    UpdateCheckStatus.failed => _controller.message ?? '检查更新失败',
  };

  Future<void> _handleTap() async {
    if (!mounted) return;
    final release = _controller.latest;
    if (_controller.status == UpdateCheckStatus.updateAvailable &&
        release != null) {
      await showUpdateReleaseDialog(
        context,
        release: release,
        currentVersion: _controller.installed?.versionName ?? '当前版本',
      );
      return;
    }
    await _controller.check();
    if (!mounted) return;
    switch (_controller.status) {
      case UpdateCheckStatus.updateAvailable:
        final latest = _controller.latest;
        if (latest == null) return;
        await showUpdateReleaseDialog(
          context,
          release: latest,
          currentVersion: _controller.installed?.versionName ?? '当前版本',
        );
      case UpdateCheckStatus.upToDate:
        _showSnackBar('已是最新版本（${_controller.installed?.versionName ?? ''}）');
      case UpdateCheckStatus.failed:
        _showSnackBar(
          _controller.message ?? '检查更新失败，请稍后重试。',
          onRetry: _controller.canRetry ? _handleTap : null,
        );
      case UpdateCheckStatus.idle:
      case UpdateCheckStatus.checking:
        break;
    }
  }

  void _showSnackBar(String message, {Future<void> Function()? onRetry}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: onRetry == null
            ? null
            : SnackBarAction(
                label: '重试',
                onPressed: () => unawaited(onRetry()),
              ),
      ),
    );
  }
}
