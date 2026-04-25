plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun conestSecret(propertyName: String, envName: String): String? {
    return (providers.gradleProperty(propertyName).orNull ?: System.getenv(envName))
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
}

val conestReleaseStoreFile = conestSecret("conest.android.storeFile", "CONEST_ANDROID_KEYSTORE")
val conestReleaseStorePassword =
    conestSecret("conest.android.storePassword", "CONEST_ANDROID_KEYSTORE_PASSWORD")
val conestReleaseKeyAlias = conestSecret("conest.android.keyAlias", "CONEST_ANDROID_KEY_ALIAS")
val conestReleaseKeyPassword =
    conestSecret("conest.android.keyPassword", "CONEST_ANDROID_KEY_PASSWORD")
val conestReleaseSigningConfigured =
    conestReleaseStoreFile != null &&
        conestReleaseStorePassword != null &&
        conestReleaseKeyAlias != null &&
        conestReleaseKeyPassword != null

android {
    namespace = "dev.conest.conest"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.conest.conest"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (conestReleaseSigningConfigured) {
                storeFile = file(conestReleaseStoreFile!!)
                storePassword = conestReleaseStorePassword
                keyAlias = conestReleaseKeyAlias
                keyPassword = conestReleaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

gradle.taskGraph.whenReady {
    val releaseTaskRequested = allTasks.any { task ->
        task.path.startsWith(":app:") &&
            (task.name.startsWith("assembleRelease") ||
                task.name.startsWith("bundleRelease") ||
                task.name.startsWith("packageRelease") ||
                task.name.startsWith("validateSigningRelease"))
    }
    if (releaseTaskRequested && !conestReleaseSigningConfigured) {
        throw GradleException(
            "Conest release signing is not configured. Set Gradle properties " +
                "conest.android.storeFile, conest.android.storePassword, " +
                "conest.android.keyAlias, conest.android.keyPassword or the " +
                "CONEST_ANDROID_KEYSTORE, CONEST_ANDROID_KEYSTORE_PASSWORD, " +
                "CONEST_ANDROID_KEY_ALIAS, CONEST_ANDROID_KEY_PASSWORD environment variables."
        )
    }
}
