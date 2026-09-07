allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// opus_flutter_android 3.0.1 is compiled against android-33, but the AndroidX artifacts it
// pulls in require compileSdk 34 or later, so `checkDebugAarMetadata` fails the build. The
// plugin version is pinned (AGENTS.md), so raise that one module's compile SDK to match the
// app's. Deliberately scoped to the single offending module: if another plugin ever needs
// the same treatment, the build should fail loudly rather than have it applied silently.
// Only the compile SDK changes; minSdk/targetSdk are untouched and the merged manifest
// still comes from `:app`.
subprojects {
    if (name == "opus_flutter_android") {
        afterEvaluate {
            val android = extensions.findByType(com.android.build.api.dsl.LibraryExtension::class.java)
            if (android != null && (android.compileSdk ?: 0) < 36) {
                android.compileSdk = 36
            }
        }
    }
}

// file_picker 11.0.3 (LO-61) skips applying `org.jetbrains.kotlin.android` when it detects
// AGP 9, expecting AGP's built-in Kotlin support to compile its `src/main/kotlin` instead.
// This project runs AGP 9.1.0 with `android.builtInKotlin=false` (the Flutter template's
// default), so nothing compiles those sources and `GeneratedPluginRegistrant` then fails
// with `cannot find symbol: FilePickerPlugin`. Applying the Kotlin plugin to that one module
// restores the pre-AGP-9 behaviour; the jvmTarget has to be set here too, because the
// plugin's own `kotlinOptions` block is inside the same AGP-9 branch it skips.
//
// Scoped to `file_picker` on purpose, like the `opus_flutter_android` hook above: another
// plugin hitting this should fail loudly rather than be fixed silently. Remove it when
// file_picker is unpinned to a version that applies the plugin unconditionally again.
subprojects {
    if (name == "file_picker") {
        plugins.withId("com.android.library") {
            apply(plugin = "org.jetbrains.kotlin.android")
            tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>()
                .configureEach {
                    compilerOptions.jvmTarget.set(
                        org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17,
                    )
                }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
