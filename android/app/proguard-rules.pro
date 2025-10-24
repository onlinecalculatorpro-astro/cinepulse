# --- Flutter / Firebase safe rules for release builds ---

# Keep annotations/inner classes so Firebase/Play Services reflection works
-keepattributes *Annotation*,InnerClasses,EnclosingMethod

# Firebase/Play Services (Messaging, IID, etc.)
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# Flutter plugins that may use reflection (messaging plugin)
-keep class io.flutter.plugins.firebase.messaging.** { *; }

# If you ever add WorkManager (used by some firebase libs), uncomment:
# -keep class androidx.work.** { *; }
# -dontwarn androidx.work.**

# (Optional) If you add OkHttp/Retrofit/Gson later, uncomment typical rules:
# -dontwarn okhttp3.**
# -dontwarn okio.**
# -dontwarn retrofit2.**
# -keep class okhttp3.** { *; }
# -keep class okio.** { *; }
# -keep class retrofit2.** { *; }
# -keep class com.google.gson.** { *; }
