import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val playSigning = System.getenv("ADI2_PLAY_SIGNING") == "1"
val playUploadFile = rootProject.file("play-upload.properties")
val playUpload = Properties()
if (playSigning) {
    check(playUploadFile.isFile) {
        "ADI2_PLAY_SIGNING=1: android/play-upload.properties fehlt. Play-Build abgebrochen."
    }
    playUploadFile.inputStream().use { playUpload.load(it) }
    for (key in listOf("storeFile", "storePassword", "keyAlias", "keyPassword")) {
        check(!playUpload.getProperty(key).isNullOrBlank()) {
            "Play-Signatur: Eintrag '$key' fehlt in android/play-upload.properties."
        }
    }
    check(rootProject.file(playUpload.getProperty("storeFile")).isFile) {
        "Play-Signatur: storeFile aus android/play-upload.properties existiert nicht."
    }
}

android {
    namespace = "de.markus.adi2_remote"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "de.markus.adi2_remote"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (playSigning) {
            create("playUpload") {
                // Relative storeFile paths are resolved against android/.
                storeFile = rootProject.file(playUpload.getProperty("storeFile"))
                storePassword = playUpload.getProperty("storePassword")
                keyAlias = playUpload.getProperty("keyAlias")
                keyPassword = playUpload.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Keep the existing GitHub APK signature unless Play signing is explicit.
            signingConfig = signingConfigs.getByName(if (playSigning) "playUpload" else "debug")
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
