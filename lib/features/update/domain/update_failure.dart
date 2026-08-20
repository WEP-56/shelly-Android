/// Why an update check could not produce a comparable release.
enum UpdateFailureKind {
  /// No usable network path to api.github.com.
  network,
  timeout,

  /// GitHub answered 403/429; the unauthenticated API is rate limited per IP.
  rateLimited,

  /// The repository has no published release yet.
  noRelease,

  /// GitHub answered with an unexpected status code.
  unexpectedStatus,

  /// The response was not the JSON object this client expects.
  malformedResponse,

  /// The release tag (or the installed version name) is not a version this app
  /// can compare.
  unrecognisedVersion,
}

/// A failed update check. Update checking is optional and manual, so every
/// failure carries a message the settings row can show without blocking use of
/// the app.
class UpdateCheckException implements Exception {
  const UpdateCheckException({
    required this.kind,
    required this.message,
    this.detail,
  });

  final UpdateFailureKind kind;

  /// User-facing, already localised.
  final String message;

  /// Extra technical context (status code, tag text). Never contains secrets:
  /// the update check is unauthenticated.
  final String? detail;

  /// Whether retrying the same check could plausibly succeed.
  bool get canRetry => switch (kind) {
    UpdateFailureKind.network ||
    UpdateFailureKind.timeout ||
    UpdateFailureKind.rateLimited ||
    UpdateFailureKind.unexpectedStatus => true,
    UpdateFailureKind.noRelease ||
    UpdateFailureKind.malformedResponse ||
    UpdateFailureKind.unrecognisedVersion => false,
  };

  @override
  String toString() =>
      'UpdateCheckException(${kind.name}: $message${detail == null ? '' : ' · $detail'})';
}
