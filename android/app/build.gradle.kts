import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

data class RustlsAndroidArtifact(val repository: File, val version: String)

val mossOnnxRuntime by configurations.creating {
    isCanBeConsumed = false
    isCanBeResolved = true
}

val rustlsAndroidArtifact = run {
    val metadataJson = providers.exec {
        workingDir = rootProject.projectDir
        commandLine(
            "cargo",
            "metadata",
            "--format-version",
            "1",
            "--filter-platform",
            "aarch64-linux-android",
            "--manifest-path",
            file("../../rust/Cargo.toml").absolutePath,
        )
    }.standardOutput.asText.get()
    val metadata = JsonSlurper().parseText(metadataJson) as Map<*, *>
    val rustlsPackage = (metadata["packages"] as List<*>)
        .map { it as Map<*, *> }
        .first { it["name"] == "rustls-platform-verifier-android" }
    val manifest = file(rustlsPackage["manifest_path"].toString())
    RustlsAndroidArtifact(
        repository = File(manifest.parentFile, "maven"),
        version = rustlsPackage["version"].toString(),
    )
}

repositories {
    maven {
        url = uri(rustlsAndroidArtifact.repository)
    }
}

dependencies {
    implementation("androidx.webkit:webkit:1.14.0")
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.27.0")
    mossOnnxRuntime("com.microsoft.onnxruntime:onnxruntime-android:1.27.0@aar")
    implementation(
        "rustls:rustls-platform-verifier:${rustlsAndroidArtifact.version}",
    )
}

val mossOnnxJniDirectory = layout.buildDirectory.dir("generated/moss-onnx/jniLibs")
val prepareMossOnnxJni by tasks.registering(Sync::class) {
    from({ mossOnnxRuntime.files.map(::zipTree) }) {
        include("jni/arm64-v8a/libonnxruntime.so")
        eachFile { path = path.removePrefix("jni/") }
        includeEmptyDirs = false
    }
    into(mossOnnxJniDirectory)
}

android {
    namespace = "com.blue.talk2u"
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
        applicationId = "com.blue.talk2u"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++17")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    sourceSets.getByName("main").jniLibs.srcDir(mossOnnxJniDirectory)

    packaging {
        jniLibs {
            pickFirsts += "lib/arm64-v8a/libonnxruntime.so"
            excludes += setOf(
                "lib/armeabi-v7a/**",
                "lib/x86/**",
                "lib/x86_64/**",
            )
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

tasks.named("preBuild").configure {
    dependsOn(prepareMossOnnxJni)
}
