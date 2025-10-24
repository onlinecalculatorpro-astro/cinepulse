// android/settings.gradle.kts
import java.util.Properties
import java.io.FileInputStream

pluginManagement {
    // Resolve Flutter SDK path from local.properties or env
    val props = Properties()
    val localProps = File(rootDir, "local.properties")
    val flutterSdkPath: String? = if (localProps.exists()) {
        FileInputStream(localProps).use { props.load(it) }
        props.getProperty("flutter.sdk")
    } else {
        System.getenv("FLUTTER_SDK") ?: System.getenv("FLUTTER_HOME")
    }
    require(!flutterSdkPath.isNullOrBlank()) {
        "flutter.sdk not set. Add it to android/local.properties or set FLUTTER_SDK."
    }

    // Put Flutter's Gradle integration on the classpath
    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        gradlePluginPortal()
        google()
        mavenCentral()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}

include(":app")
