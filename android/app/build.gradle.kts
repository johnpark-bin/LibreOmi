import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material, resolved in this order (LO-63, docs/08 §7):
//   1. LIBREOMI_KEYSTORE_PATH / _PASSWORD / _ALIAS / _KEY_PASSWORD environment variables
//      (this is how CI injects the key from repository secrets),
//   2. android/key.properties, which is git-ignored and is what a local release build uses,
//   3. nothing -> the release build falls back to the debug key with a warning.
// The fallback keeps `flutter build apk --release` working for contributors and for the CI
// compile check, neither of which has the signing key.
val keyPropertiesFile = rootProject.file("key.properties")
val keyProperties = Properties().apply {
    if (keyPropertiesFile.exists()) {
        keyPropertiesFile.inputStream().use { load(it) }
    }
}

fun signingValue(envName: String, propertyName: String): String? =
    (System.getenv(envName) ?: keyProperties.getProperty(propertyName))?.trim()?.takeIf { it.isNotEmpty() }

val keystorePath = signingValue("LIBREOMI_KEYSTORE_PATH", "storeFile")
val keystorePassword = signingValue("LIBREOMI_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("LIBREOMI_KEYSTORE_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("LIBREOMI_KEY_PASSWORD", "keyPassword")

// A relative storeFile in key.properties is resolved against android/, so the file can sit
// next to key.properties without the path depending on where Gradle was invoked from.
val keystoreFile = keystorePath?.let { path ->
    // Deliberately java.io.File, not Gradle's file(): the latter always returns an absolute
    // path resolved against the *module* directory (android/app), which would make the
    // relative-path branch below unreachable and resolve key.properties entries one level
    // deeper than the file they are written in.
    val candidate = File(path)
    if (candidate.isAbsolute) candidate else rootProject.file(path)
}

val hasReleaseSigning =
    keystoreFile != null &&
        keystoreFile.exists() &&
        keystorePassword != null &&
        releaseKeyAlias != null &&
        releaseKeyPassword != null

// Explain *which* piece is missing: "release is unsigned" is a slow thing to debug from a
// build log that only says the fallback happened. `flutter build` filters Gradle's own output,
// though - neither `logger.warn` nor `logger.lifecycle` reaches its console (measured), so this
// line only appears under a direct Gradle invocation. What actually protects a release is
// scripts/release.sh: it prints the signing certificate on every run and refuses to create a
// GitHub Release from debug-signed artifacts.
if (!hasReleaseSigning) {
    val reason = when {
        keystorePath == null -> "no keystore configured (set LIBREOMI_KEYSTORE_PATH or android/key.properties)"
        keystoreFile == null || !keystoreFile.exists() -> "keystore file not found at ${keystoreFile?.absolutePath ?: keystorePath}"
        keystorePassword == null -> "missing store password"
        releaseKeyAlias == null -> "missing key alias"
        else -> "missing key password"
    }
    logger.warn("LibreOmi: release builds will be signed with the DEBUG key - $reason. See docs/08-dev-workflow.md §7.")
}

android {
    namespace = "org.libreomi.app"
    // Flutter 3.47.2's Gradle plugin compiles against 36; see docs/04 §2.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Placeholder until the owner registers a final application id.
        applicationId = "org.libreomi.app"
        // SDK levels are fixed by docs/04 §2, not taken from the Flutter template.
        minSdk = 26
        targetSdk = 35
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            // The names below are the SigningConfig properties; the values come from the
            // `release*` vals above, because an unqualified `keyAlias` inside this block would
            // resolve to the property itself and silently assign null.
            create("release") {
                storeFile = keystoreFile
                storePassword = keystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Signed with the real release key when one is configured above; otherwise the
            // debug key, so that a release build still succeeds without the secret.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // v1 keeps R8 off: minifying would need keep rules for the sherpa-onnx and opus JNI
            // entry points, and a stripped native path fails silently at runtime. See docs/04 §7.
            isMinifyEnabled = false
            isShrinkResources = false
            // Release deliberately keeps every ABI; per-ABI release artifacts come from
            // `flutter build apk --split-per-abi` in LO-63, not from an abiFilters here.
        }
    }
}

// sherpa_onnx_android ships native libraries for three ABIs, which puts an all-ABI debug APK at
// 215.8 MiB. Development phones are arm64, so debug packages that ABI only: 109.4 MiB.
//
// This deliberately does NOT use `ndk { abiFilters }`. The Flutter Gradle plugin resets
// `defaultConfig.ndk.abiFilters` to all three supported ABIs while it is being applied
// (FlutterPlugin.configureAbiWithoutSplits), and AGP merges the defaultConfig and build-type
// filter sets as a union, so a narrower filter on `buildTypes.debug` can never remove an ABI.
// Per-variant packaging is the one hook that is both build-type scoped and applied after the
// plugin. See docs/04 §7.
androidComponents {
    onVariants(selector().withBuildType("debug")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(
            "**/armeabi-v7a/**",
            "**/x86_64/**"
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
