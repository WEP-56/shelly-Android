import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/app_theme.dart';
import '../domain/app_release.dart';

/// Shows the release the check found and offers to open its GitHub page.
///
/// The app deliberately stops here: it never downloads or installs an APK, so
/// it needs no install permission and the user stays in control of the file
/// they run.
Future<void> showUpdateReleaseDialog(
  BuildContext context, {
  required AppRelease release,
  required String currentVersion,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final colors = dialogContext.shelly;
      final notes = release.notesPreview();
      final published = release.publishedAt;
      return AlertDialog(
        title: const Text('发现新版本'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$currentVersion → ${release.tag}',
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                published == null
                    ? release.title
                    : '${release.title} · ${_formatDate(published)}',
                style: TextStyle(fontSize: 12, color: colors.onSurface2),
              ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.surface2,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.line),
                  ),
                  child: Text(
                    notes,
                    style: TextStyle(fontSize: 12, color: colors.onSurface2),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                '打开后请在 Release 页面手动下载对应 ABI 的 APK；应用不会自动下载或安装。',
                style: TextStyle(fontSize: 11, color: colors.onSurface3),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(dialogContext);
              Navigator.pop(dialogContext);
              await openReleasePage(release.pageUrl, messenger);
            },
            child: const Text('打开 Release 页面'),
          ),
        ],
      );
    },
  );
}

/// Hands the release page to the system browser. A device with no browser that
/// can handle the link is reported, not silently ignored, and the URL is put on
/// the clipboard so the user can still reach it.
Future<void> openReleasePage(Uri url, ScaffoldMessengerState messenger) async {
  var opened = false;
  String? failure;
  try {
    opened = await launchUrl(url, mode: LaunchMode.externalApplication);
  } on PlatformException catch (error) {
    failure = error.message;
  }
  if (opened) return;
  await Clipboard.setData(ClipboardData(text: url.toString()));
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        failure == null
            ? '没有可用的浏览器，链接已复制到剪贴板。'
            : '无法打开浏览器（$failure），链接已复制到剪贴板。',
      ),
    ),
  );
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}
