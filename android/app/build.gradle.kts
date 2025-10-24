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
    // MUST match google-services.json
    namespace = "api.onlinecalculatorpro.cinepulse"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "api.onlinecalculatorpro.cinepulse" // keep in sync with namespace
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
            // TODO: replace with your real release signing config when ready
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
        }
        debug { /* defaults */ }
    }

    // Avoid occasional META-INF conflicts from transitive libs
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
    // Optional analytics:
    // implementation("com.google.firebase:firebase-analytics")
}
