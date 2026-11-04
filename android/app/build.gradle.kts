plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val legalAndroidApplicationId =
    providers.gradleProperty("legalAndroidApplicationId").orNull?.trim()
        ?.takeIf { it.isNotEmpty() } ?: "com.example.legal_app"
val authCallbackScheme =
    providers.gradleProperty("authCallbackScheme").orNull?.trim()
        ?.takeIf { it.isNotEmpty() } ?: "unconfigured"
val authCallbackHost =
    providers.gradleProperty("authCallbackHost").orNull?.trim()
        ?.takeIf { it.isNotEmpty() } ?: "unconfigured"
val authCallbackPath =
    providers.gradleProperty("authCallbackPath").orNull?.trim()
        ?.takeIf { it.isNotEmpty() } ?: "/unconfigured"

val isReleaseTask = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
if (isReleaseTask) {
    check(legalAndroidApplicationId != "com.example.legal_app") {
        "Set -PlegalAndroidApplicationId to the operator-approved Android application ID."
    }
    check(authCallbackScheme != "unconfigured" && authCallbackHost != "unconfigured" &&
        authCallbackPath != "/unconfigured") {
        "Set -PauthCallbackScheme, -PauthCallbackHost, and -PauthCallbackPath to the approved callback URI components."
    }
}


android {
    namespace = legalAndroidApplicationId
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Keep the placeholder out of release by requiring the approved ID above.
        applicationId = legalAndroidApplicationId
        manifestPlaceholders["authCallbackScheme"] = authCallbackScheme
        manifestPlaceholders["authCallbackHost"] = authCallbackHost
        manifestPlaceholders["authCallbackPath"] = authCallbackPath
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
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
        }
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
