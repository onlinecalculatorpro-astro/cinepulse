// android/app/build.gradle.kts (module-level)

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after Android/Kotlin.
    id("dev.flutter.flutter-gradle-plugin")
    // Google Services for FCM (reads google-services.json)
    id("com.google.gms.google-services")
}

android {
    namespace = "com.example.cinepulse_app" // TODO: replace with your real package; must match google-services.json
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "com.example.cinepulse_app" // TODO: keep in sync with namespace + Firebase project
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Required for flutter_local_notifications & modern Firebase libs
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildTypes {
        release {
            // TODO: replace with your real release signingConfig
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
        }
        debug {
            // keep defaults
        }
    }

    // (Optional) avoid occasional META-INF conflicts from transitive libs
    packaging {
        resources {
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/NOTICE",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/NOTICE.txt",
                "META-INF/ASL2.0"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Desugaring (when coreLibraryDesugaringEnabled = true)
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    // Firebase BoM keeps all Firebase libs in sync; add messaging without version
    implementation(platform("com.google.firebase:firebase-bom:33.6.0"))
    implementation("com.google.firebase:firebase-messaging")
    // (Optional) analytics if you need it:
    // implementation("com.google.firebase:firebase-analytics")
}
