import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/agent_failure.dart';
import '../domain/agent_tool.dart';
import 'agent_json.dart';
import 'agent_retry.dart';
import 'sse_decoder.dart';

/// Streaming SSE transport for provider requests.
///
/// Owns exactly one [http.Client] per request so cancellation is real: closing
/// the client tears down the in-flight socket instead of leaving a detached
/// stream writing into a dropped listener.
class ProviderTransport {
  ProviderTransport({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;

  /// Idle gap allowed between two SSE chunks before the stream is treated as
  /// dead. Providers send keep-alive comments well inside this window.
  static const idleTimeout = Duration(seconds: 90);

  final http.Client Function() _clientFactory;

  /// Opens the stream, retrying only while no bytes have been delivered.
  ///
  /// Once the first event is emitted a retry would duplicate partial output, so
  /// the caller (the loop) owns retrying from that point on.
  Stream<SseEvent> stream({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    required Duration timeout,
    required AgentCancellationToken cancellation,
    AgentRetryPolicy retryPolicy = const AgentRetryPolicy(),
  }) {
    final controller = StreamController<SseEvent>();
    var attempt = 0;

    Future<void> run() async {
      while (true) {
        try {
          await _streamOnce(
            url: url,
            headers: headers,
            body: body,
            timeout: timeout,
            cancellation: cancellation,
            sink: controller,
          );
          return;
        } on AgentFailure catch (failure) {
          final retriable =
              !failure.isCancelled &&
              attempt < retryPolicy.maxRetries &&
              retryPolicy.enabled &&
              AgentRetryClassifier.isRetryable(failure);
          if (!retriable) {
            controller.addError(failure);
            return;
          }
          attempt += 1;
          final delay = retryPolicy.delayFor(
            attempt,
            serverRequested: failure.retryAfter,
          );
          if (!await _sleep(delay, cancellation)) {
            controller.addError(
              const AgentFailure(
                stage: AgentFailureStage.cancelled,
                message: '已取消。',
              ),
            );
            return;
          }
        }
      }
    }

    controller.onListen = () {
      unawaited(run().whenComplete(controller.close));
    };
    return controller.stream;
  }

  Future<void> _streamOnce({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
    required Duration timeout,
    required AgentCancellationToken cancellation,
    required EventSink<SseEvent> sink,
  }) async {
    cancellation.throwIfCancelled();
    final client = _clientFactory();
    var closed = false;
    var timedOut = false;
    void closeClient() {
      if (closed) return;
      closed = true;
      client.close();
    }

    cancellation.addListener(closeClient);
    final deadline = Timer(timeout, () {
      timedOut = true;
      closeClient();
    });
    try {
      final request = http.Request('POST', url)
        ..headers.addAll(headers)
        ..bodyBytes = utf8.encode(jsonEncode(body));
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final text = await response.stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .take(64)
            .join();
        throw AgentFailure(
          stage: AgentFailureStage.providerStatus,
          message: _statusMessage(response.statusCode),
          detail: _statusDetail(url, text),
          statusCode: response.statusCode,
          retryAfter: AgentRetryClassifier.serverRequestedDelay(
            response.headers,
          ),
        );
      }
      final events = response.stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const SseDecoder())
          .timeout(
            idleTimeout,
            onTimeout: (sink) => sink.addError(
              const AgentFailure(
                stage: AgentFailureStage.transport,
                message: '模型响应超时，请重试。',
                detail: 'stream idle timeout',
              ),
            ),
          );
      await for (final event in events) {
        cancellation.throwIfCancelled();
        sink.add(event);
      }
      cancellation.throwIfCancelled();
    } on AgentFailure {
      rethrow;
    } on Object catch (error) {
      if (cancellation.isCancelled) {
        throw const AgentFailure(
          stage: AgentFailureStage.cancelled,
          message: '已取消。',
        );
      }
      if (timedOut) {
        throw AgentFailure(
          stage: AgentFailureStage.transport,
          message: '模型请求超时，请重试或调高超时设置。',
          detail: 'request timeout after ${timeout.inSeconds}s',
          cause: error,
        );
      }
      throw AgentFailure(
        stage: AgentFailureStage.transport,
        message: _transportMessage(error),
        detail: error.toString(),
        cause: error,
      );
    } finally {
      deadline.cancel();
      closeClient();
    }
  }

  Future<bool> _sleep(
    Duration duration,
    AgentCancellationToken cancellation,
  ) async {
    if (cancellation.isCancelled) return false;
    final completer = Completer<bool>();
    final timer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete(true);
    });
    cancellation.addListener(() {
      timer.cancel();
      if (!completer.isCompleted) completer.complete(false);
    });
    return completer.future;
  }

  /// Detail line for a non-2xx response: the exact URL that was called plus the
  /// provider's own message. The API key travels in a header, never in the URL,
  /// but the query string is dropped anyway in case the user typed a key into the
  /// endpoint.
  String _statusDetail(Uri url, String body) {
    final target = Uri(
      scheme: url.scheme,
      host: url.host,
      port: url.hasPort ? url.port : null,
      path: url.path,
    );
    final described = AgentJson.describeErrorBody(body);
    final suffix = described == null || described.isEmpty
        ? ''
        : ' · $described';
    return 'POST $target$suffix';
  }

  String _statusMessage(int status) => switch (status) {
    400 => '模型请求被拒绝（400），请检查模型名称和参数。',
    401 => 'API Key 无效或已过期（401）。',
    403 => '没有访问该模型的权限（403）。',
    404 => '接口地址或模型不存在（404），请核对下方请求地址和模型名。',
    413 => '请求内容过大（413），请缩短对话或减少上下文。',
    429 => '请求过于频繁或额度不足（429）。',
    _ when status >= 500 => '模型服务暂时不可用（$status），请重试。',
    _ => '模型请求失败（$status）。',
  };

  String _transportMessage(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('failed host lookup')) {
      return '无法解析接口域名，请检查网络和 endpoint。';
    }
    if (text.contains('connection refused')) {
      return '接口拒绝连接，请检查 endpoint 和端口。';
    }
    if (text.contains('handshake')) {
      return 'TLS 握手失败，请检查接口证书或代理设置。';
    }
    if (text.contains('timeout') || text.contains('timed out')) {
      return '模型请求超时，请重试。';
    }
    return '无法连接模型服务，请检查网络后重试。';
  }
}
