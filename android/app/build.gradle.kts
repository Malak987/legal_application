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


// Release signing material. `android/key.properties` is git-ignored and is
// supplied by the release engineer or by CI secrets; it must never be
// committed. When it is absent the build still succeeds with the debug key so
// local `flutter build apk --release` keeps working, but it prints a loud
// warning because a debug-signed artifact cannot be uploaded to Google Play.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = java.util.Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
val hasReleaseSigningConfig = keystorePropertiesFile.exists()

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

    signingConfigs {
        if (hasReleaseSigningConfig) {
            create("release") {
                storeFile = keystoreProperties["storeFile"]?.let { rootProject.file(it as String) }
                storePassword = keystoreProperties["storePassword"] as String?
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigningConfig) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Debug keys keep local release builds working, but the output
                // is NOT publishable: Google Play rejects debug-signed bundles.
                logger.lifecycle(
                    "\n" + """
                    ************************************************************
                    WARNING: android/key.properties was not found.
                    This release artifact is signed with the DEBUG key and will
                    be REJECTED by Google Play. Create a release keystore and
                    supply key.properties before shipping:
                      storeFile, storePassword, keyAlias, keyPassword
                    ************************************************************
                    """.trimIndent() + "\n"
                )
                signingConfig = signingConfigs.getByName("debug")
            }
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
