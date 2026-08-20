/// A release version, parsed either from the installed package version name or
/// from a GitHub release tag.
///
/// Only the shapes this project actually produces are accepted: `1.2`, `1.2.3`,
/// an optional leading `v`, an optional `-beta.1` pre-release suffix and an
/// optional `+build` suffix. Anything else is reported to the user as an
/// unrecognisable tag instead of being guessed at.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.preRelease = '',
  });

  static final RegExp _pattern = RegExp(
    r'^v?(\d{1,9})\.(\d{1,9})(?:\.(\d{1,9}))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  factory AppVersion.parse(String raw) {
    final version = tryParse(raw);
    if (version == null) {
      throw FormatException('Unrecognised version', raw);
    }
    return version;
  }

  /// Returns null when [raw] is not a version this app can compare.
  static AppVersion? tryParse(String raw) {
    final match = _pattern.firstMatch(raw.trim());
    if (match == null) return null;
    return AppVersion(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      patch: int.parse(match.group(3) ?? '0'),
      preRelease: match.group(4) ?? '',
    );
  }

  final int major;
  final int minor;
  final int patch;

  /// Pre-release identifier without the leading `-`; empty for a final release.
  final String preRelease;

  bool get isPreRelease => preRelease.isNotEmpty;

  bool isNewerThan(AppVersion other) => compareTo(other) > 0;

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    if (preRelease == other.preRelease) return 0;
    // A final release outranks any pre-release of the same core version. Two
    // different pre-releases only need a stable order, not semver identifier
    // precedence: this comparison decides "is the remote newer", and GitHub's
    // `releases/latest` never returns a pre-release.
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;
    return preRelease.compareTo(other.preRelease);
  }

  @override
  String toString() {
    final core = '$major.$minor.$patch';
    return isPreRelease ? '$core-$preRelease' : core;
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersion &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.preRelease == preRelease;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);
}
