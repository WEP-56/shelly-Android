import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material never enters the repository. It comes from CI
// environment variables or, on a developer machine, from android/key.properties.
// Both are gitignored; nothing here is printed except which mode was selected.
val keystoreProperties = Properties().apply {
    val propertiesFile = rootProject.file("key.properties")
    if (propertiesFile.exists()) {
        propertiesFile.inputStream().use { load(it) }
    }
}

fun signingValue(environmentKey: String, propertyKey: String): String? {
    val fromEnvironment = System.getenv(environmentKey)
    if (!fromEnvironment.isNullOrBlank()) return fromEnvironment
    return keystoreProperties.getProperty(propertyKey)?.takeIf { it.isNotBlank() }
}

val releaseStorePath = signingValue("SHELLY_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = signingValue("SHELLY_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("SHELLY_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("SHELLY_KEY_PASSWORD", "keyPassword")
val releaseStoreFile = releaseStorePath?.let { file(it) }
val hasReleaseSigning = releaseStoreFile != null &&
    releaseStoreFile.exists() &&
    !releaseStorePassword.isNullOrBlank() &&
    !releaseKeyAlias.isNullOrBlank() &&
    !releaseKeyPassword.isNullOrBlank()

android {
    namespace = "com.wep56.shelly_android"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.wep56.shelly_android"
        // minSdk 24 is the floor for the SSH, secure storage and SAF behaviour
        // this app depends on; targetSdk and versionName/Code follow the Flutter
        // tool, which reads the version from pubspec.yaml.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // Keeps `flutter build apk --release` usable without a keystore.
                // The workflow reports this as a debug-signed build instead of
                // failing silently.
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

dependencies {
    // local_auth's Android implementation pulls androidx.biometric but not
    // appcompat, while the biometric prompt needs an AppCompat theme (see
    // res/values/styles.xml). Pinned so a transitive bump cannot change it.
    implementation("androidx.appcompat:appcompat:1.7.0")
}

gradle.taskGraph.whenReady {
    if (!hasReleaseSigning && allTasks.any { it.name.contains("Release") }) {
        logger.warn(
            "Shelly: no release keystore configured; the release APK will be signed " +
                "with the debug key. Set SHELLY_KEYSTORE_PATH, SHELLY_KEYSTORE_PASSWORD, " +
                "SHELLY_KEY_ALIAS and SHELLY_KEY_PASSWORD to sign it properly."
        )
    }
}

flutter {
    source = "../.."
}
