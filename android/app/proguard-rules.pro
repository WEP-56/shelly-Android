# R8 rules for the Shelly release build.
#
# The Dart code is compiled AOT and is not affected by R8; these rules only
# cover the Android side. Keep them narrow: every blanket -keep silently grows
# the APK and hides real dead code.

# Flutter embedding and the generated plugin registrant are entered through
# reflection from the engine, not from Java call sites.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# flutter_secure_storage reaches Android Keystore through androidx.security,
# which loads Tink primitives by name.
-keep class com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**
-dontwarn androidx.security.crypto.**

# Build-time-only annotations referenced by transitive dependencies.
-dontwarn javax.annotation.**
-dontwarn com.google.errorprone.annotations.**

# The Flutter embedding ships Play Store split-install support
# (FlutterPlayStoreSplitApplication, PlayStoreDeferredComponentManager) that
# references the Play Core library. This app has no deferred components and does
# not depend on Play Core, so those classes are unreachable at runtime: the
# application class is FlutterApplication and nothing installs a split. Without
# this rule R8 turns the dangling references into "Missing class" errors and
# fails :app:minifyReleaseWithR8. Do not add the Play Core dependency to silence
# it; the app must not gain a Play Store dependency it never uses.
-dontwarn com.google.android.play.core.**

# Keep stack traces readable in release crash reports. Only file names and line
# numbers are kept; no secret material is ever written to logs or crash text.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
