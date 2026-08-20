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

# Keep stack traces readable in release crash reports. Only file names and line
# numbers are kept; no secret material is ever written to logs or crash text.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
