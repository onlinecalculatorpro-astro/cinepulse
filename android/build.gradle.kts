// android/build.gradle.kts (project-level)

plugins {
    id("com.android.application") version "8.6.1" apply false
    id("com.android.library") version "8.6.1" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("com.google.gms.google-services") version "4.4.2" apply false
    // Flutter Gradle integration; applied in :app
    id("dev.flutter.flutter-plugin-loader") version "1.0.0" apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Put all Gradle outputs under the repo root /build (your original intent)
val newBuildDir = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.set(newBuildDir)

subprojects {
    // Each subproject writes into /build/<moduleName>
    val newSubBuildDir = newBuildDir.dir(project.name)
    layout.buildDirectory.set(newSubBuildDir)

    // Ensure :app is configured first (Flutter projects often rely on this)
    evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
