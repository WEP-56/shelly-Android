/// A published GitHub release, reduced to the fields the update prompt shows.
///
/// The app never downloads or installs an artifact: [pageUrl] is opened in the
/// system browser and the user picks an APK there.
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.title,
    required this.pageUrl,
    required this.notes,
    this.publishedAt,
  });

  final String tag;

  /// Release name when GitHub has one, otherwise the tag.
  final String title;
  final Uri pageUrl;

  /// Release body as written on GitHub; may be empty.
  final String notes;
  final DateTime? publishedAt;

  /// Release notes capped for a dialog, so a long changelog cannot push the
  /// action buttons off screen on a phone.
  String notesPreview({int maxChars = 1200}) {
    final trimmed = notes.trim();
    if (trimmed.length <= maxChars) return trimmed;
    return '${trimmed.substring(0, maxChars)}…';
  }
}
