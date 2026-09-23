import java.util.Properties

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
        manifestPlaceholders["conestAppLabel"] = "Conest"
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
        debug {
            // Debug battle-test builds install alongside stable/nightly and
            // use a separate Android sandbox, identity, cache, and updater
            // state. They can therefore be installed on physical devices
            // without overwriting a user's real Conest installation.
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
            manifestPlaceholders["conestAppLabel"] = "Conest Debug"
        }
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }

    sourceSets.getByName("main").jniLibs.srcDir(
        layout.buildDirectory.dir("conestNativeJniLibs")
    )
}

val conestAndroidTargets =
    (System.getenv("CON_ANDROID_TARGETS")
        ?: "arm64-v8a,armeabi-v7a,x86,x86_64")
        .split(',')
        .map { it.trim() }
        .filter { it.isNotEmpty() }

val conestAndroidSdk =
    providers.environmentVariable("ANDROID_SDK_ROOT").orNull
        ?: providers.environmentVariable("ANDROID_HOME").orNull
        ?: run {
            val localPropertiesFile = rootProject.file("local.properties")
            if (!localPropertiesFile.isFile) {
                null
            } else {
                val localProperties = Properties()
                localPropertiesFile.inputStream().use { input ->
                    localProperties.load(input)
                }
                localProperties.getProperty("sdk.dir")
            }
        }
val conestAndroidNdkHome =
    providers.environmentVariable("ANDROID_NDK_HOME").orNull
        ?: providers.environmentVariable("ANDROID_NDK_ROOT").orNull
        ?: conestAndroidSdk?.let { sdk ->
            File(sdk, "ndk/${android.ndkVersion}").takeIf { it.isDirectory }?.absolutePath
        }

val buildConestNative by tasks.registering(Exec::class) {
    val repositoryRoot = rootProject.projectDir.parentFile
    val outputDirectory = layout.buildDirectory.dir("conestNativeJniLibs")
    workingDir(repositoryRoot)
    if (conestAndroidNdkHome != null) {
        // opusic-sys needs the NDK root for its bundled CMake build. cargo-ndk
        // can locate the NDK independently but does not expose this variable
        // to dependency build scripts on every supported version.
        environment("ANDROID_NDK_HOME", conestAndroidNdkHome)
    }
    commandLine(
        buildList {
            add("cargo")
            add("ndk")
            for (target in conestAndroidTargets) {
                add("-t")
                add(target)
            }
            add("-o")
            add(outputDirectory.get().asFile.absolutePath)
            add("build")
            add("--manifest-path")
            add(File(repositoryRoot, "native/conest_native/Cargo.toml").absolutePath)
            add("--release")
        }
    )
    inputs.files(
        fileTree(File(repositoryRoot, "native/conest_native/src")),
        File(repositoryRoot, "native/conest_native/Cargo.toml"),
    )
    outputs.dir(outputDirectory)
}

tasks.named("preBuild").configure {
    dependsOn(buildConestNative)
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
