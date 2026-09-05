plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
