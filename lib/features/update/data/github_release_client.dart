import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/app_release.dart';
import '../domain/update_failure.dart';

/// Repository the released APKs are published from.
const String shellyRepositoryOwner = 'WEP-56';
const String shellyRepositoryName = 'shelly-Android';

/// Reads the latest published release from the public GitHub API.
///
/// Unauthenticated on purpose: the app holds no GitHub token, so nothing here
/// can leak one. Only release metadata is read; the APK itself is downloaded by
/// the user in a browser.
class GithubReleaseClient {
  GithubReleaseClient({
    this.owner = shellyRepositoryOwner,
    this.repo = shellyRepositoryName,
    this.timeout = const Duration(seconds: 15),
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  final String owner;
  final String repo;
  final Duration timeout;
  final http.Client Function() _clientFactory;

  Uri get releasesPageUrl =>
      Uri.https('github.com', '/$owner/$repo/releases/latest');

  /// Throws [UpdateCheckException] for every expected failure; the caller shows
  /// [UpdateCheckException.message] and keeps working.
  Future<AppRelease> fetchLatestRelease() async {
    final url = Uri.https(
      'api.github.com',
      '/repos/$owner/$repo/releases/latest',
    );
    final client = _clientFactory();
    try {
      final response = await client
          .get(
            url,
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'Shelly-Android',
            },
          )
          .timeout(timeout);
      return _parseResponse(response);
    } on TimeoutException {
      throw UpdateCheckException(
        kind: UpdateFailureKind.timeout,
        message: '连接 GitHub 超时，请稍后重试。',
        detail: 'timeout after ${timeout.inSeconds}s',
      );
    } on SocketException catch (error) {
      throw UpdateCheckException(
        kind: UpdateFailureKind.network,
        message: '无法连接 GitHub，请检查网络后重试。',
        detail: error.message,
      );
    } on http.ClientException catch (error) {
      throw UpdateCheckException(
        kind: UpdateFailureKind.network,
        message: '无法连接 GitHub，请检查网络后重试。',
        detail: error.message,
      );
    } on HandshakeException catch (error) {
      throw UpdateCheckException(
        kind: UpdateFailureKind.network,
        message: 'GitHub TLS 握手失败，请检查网络或代理设置。',
        detail: error.message,
      );
    } finally {
      client.close();
    }
  }

  AppRelease _parseResponse(http.Response response) {
    switch (response.statusCode) {
      case 200:
        break;
      case 404:
        throw const UpdateCheckException(
          kind: UpdateFailureKind.noRelease,
          message: '仓库还没有发布任何版本。',
        );
      case 403:
      case 429:
        throw UpdateCheckException(
          kind: UpdateFailureKind.rateLimited,
          message: 'GitHub 接口访问受限，请稍后再检查更新。',
          detail: _rateLimitDetail(response),
        );
      default:
        throw UpdateCheckException(
          kind: UpdateFailureKind.unexpectedStatus,
          message: 'GitHub 返回 ${response.statusCode}，请稍后重试。',
          detail: 'GET ${response.request?.url}',
        );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException catch (error) {
      throw UpdateCheckException(
        kind: UpdateFailureKind.malformedResponse,
        message: '无法解析 GitHub 返回的发布信息。',
        detail: error.message,
      );
    }
    if (decoded is! Map) {
      throw const UpdateCheckException(
        kind: UpdateFailureKind.malformedResponse,
        message: '无法解析 GitHub 返回的发布信息。',
        detail: 'response is not a JSON object',
      );
    }
    final payload = Map<String, Object?>.from(decoded);

    final tag = _stringOrNull(payload['tag_name']);
    if (tag == null) {
      throw const UpdateCheckException(
        kind: UpdateFailureKind.malformedResponse,
        message: 'GitHub 返回的发布信息缺少版本 tag。',
        detail: 'missing tag_name',
      );
    }
    final page = _stringOrNull(payload['html_url']);
    final published = _stringOrNull(payload['published_at']);
    return AppRelease(
      tag: tag,
      title: _stringOrNull(payload['name']) ?? tag,
      pageUrl: page == null
          ? Uri.https('github.com', '/$owner/$repo/releases/tag/$tag')
          : Uri.parse(page),
      notes: _stringOrNull(payload['body']) ?? '',
      publishedAt: published == null ? null : DateTime.tryParse(published),
    );
  }

  /// GitHub sends `x-ratelimit-remaining: 0` when the per-IP budget is spent;
  /// a 403 without it is a different refusal and is reported as such.
  String _rateLimitDetail(http.Response response) {
    final remaining = response.headers['x-ratelimit-remaining'];
    if (remaining == '0') {
      final reset = response.headers['x-ratelimit-reset'];
      return reset == null
          ? 'rate limit exhausted'
          : 'rate limit exhausted, resets at $reset';
    }
    return 'HTTP ${response.statusCode}';
  }

  static String? _stringOrNull(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
