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

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
