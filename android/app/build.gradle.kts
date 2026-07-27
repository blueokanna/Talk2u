import groovy.json.JsonSlurper
import java.security.MessageDigest

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

val qnnOrtAar = providers
    .gradleProperty("talk2u.qnnOrtAar")
    .orElse(providers.environmentVariable("TALK2U_QNN_ORT_AAR"))
    .orNull
    ?.trim()
    ?.takeIf(String::isNotEmpty)
    ?.let(::file)
    ?.canonicalFile
val qnnSdkRoot = providers
    .gradleProperty("talk2u.qnnSdkRoot")
    .orElse(providers.environmentVariable("TALK2U_QNN_SDK_ROOT"))
    .orNull
    ?.trim()
    ?.takeIf(String::isNotEmpty)
    ?.let(::file)
    ?.canonicalFile
val qnnHtpArch = providers
    .gradleProperty("talk2u.qnnHtpArch")
    .orElse(providers.environmentVariable("TALK2U_QNN_HTP_ARCH"))
    .getOrElse("v81")
    .trim()
    .lowercase()
val qnnJniDirectory = providers
    .gradleProperty("talk2u.qnnJniDir")
    .orElse(providers.environmentVariable("TALK2U_QNN_JNI_DIR"))
    .orNull
    ?.trim()
    ?.takeIf(String::isNotEmpty)
    ?.let(::file)
    ?.canonicalFile

require(Regex("v[0-9]+").matches(qnnHtpArch)) {
    "TALK2U_QNN_HTP_ARCH must look like v81: $qnnHtpArch"
}
require(qnnSdkRoot == null || qnnJniDirectory == null) {
    "Configure TALK2U_QNN_SDK_ROOT or TALK2U_QNN_JNI_DIR, not both"
}

qnnOrtAar?.let {
    require(it.isFile && it.extension.equals("aar", ignoreCase = true)) {
        "TALK2U_QNN_ORT_AAR must point to a QNN-enabled ONNX Runtime Android AAR: $it"
    }
}
qnnJniDirectory?.let {
    val arm64 = it.resolve("arm64-v8a")
    require(arm64.resolve("libQnnHtp.so").isFile) {
        "TALK2U_QNN_JNI_DIR is missing arm64-v8a/libQnnHtp.so: $it"
    }
    require(arm64.resolve("libQnnSystem.so").isFile) {
        "TALK2U_QNN_JNI_DIR is missing arm64-v8a/libQnnSystem.so: $it"
    }
    require(
        arm64.listFiles()?.any {
            it.isFile && Regex("libQnnHtpV[0-9]+Stub\\.so").matches(it.name)
        } == true,
    ) {
        "TALK2U_QNN_JNI_DIR is missing an arm64-v8a/libQnnHtpV*Stub.so: $it"
    }
}

val qnnSdkHostDirectory = qnnSdkRoot?.resolve("lib/aarch64-android")
val qnnSdkSkelFile = qnnSdkRoot?.resolve(
    "lib/hexagon-$qnnHtpArch/unsigned/libQnnHtp${qnnHtpArch.uppercase()}Skel.so",
)
qnnSdkRoot?.let {
    require(it.isDirectory) { "TALK2U_QNN_SDK_ROOT is not a QAIRT SDK directory: $it" }
    val host = requireNotNull(qnnSdkHostDirectory)
    listOf(
        "libGenie.so",
        "libQnnCpu.so",
        "libQnnGenAiTransformer.so",
        "libQnnGenAiTransformerModel.so",
        "libQnnGpu.so",
        "libQnnHtp.so",
        "libQnnSystem.so",
        "libQnnHtpPrepare.so",
        "libQnnHtp${qnnHtpArch.uppercase()}Stub.so",
    ).forEach { library ->
        require(host.resolve(library).isFile) { "QAIRT SDK is missing $library: $host" }
    }
    require(requireNotNull(qnnSdkSkelFile).isFile) {
        "QAIRT SDK is missing the $qnnHtpArch HTP skel: $qnnSdkSkelFile"
    }
}

fun File.sha256(): String {
    val digest = MessageDigest.getInstance("SHA-256")
    inputStream().buffered().use { input ->
        val buffer = ByteArray(1024 * 1024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
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
    if (qnnOrtAar == null) {
        implementation("com.microsoft.onnxruntime:onnxruntime-android:1.27.0")
        mossOnnxRuntime("com.microsoft.onnxruntime:onnxruntime-android:1.27.0@aar")
    } else {
        implementation(files(qnnOrtAar))
        mossOnnxRuntime(files(qnnOrtAar))
    }
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
val qnnSdkJniDirectory = layout.buildDirectory.dir("generated/qnn/jniLibs")
val prepareQnnSdkJni by tasks.registering(Sync::class) {
    qnnSdkHostDirectory?.let { host ->
        from(host) {
            include(
                "libGenie.so",
                "libQnnCpu.so",
                "libQnnGenAiTransformer.so",
                "libQnnGenAiTransformerModel.so",
                "libQnnGpu.so",
                "libQnnHtp.so",
                "libQnnSystem.so",
                "libQnnHtpPrepare.so",
                "libQnnHtp${qnnHtpArch.uppercase()}Stub.so",
            )
            into("arm64-v8a")
        }
    }
    into(qnnSdkJniDirectory)
}
val qnnSdkAssetDirectory = layout.buildDirectory.dir("generated/qnn/assets")
val prepareQnnSdkAssets by tasks.registering(Sync::class) {
    qnnSdkSkelFile?.let { skel ->
        from(skel) {
            into("qnn/htp/$qnnHtpArch")
        }
    }
    into(qnnSdkAssetDirectory)
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
        buildConfigField(
            "boolean",
            "QNN_BUNDLED",
            (qnnSdkRoot != null || qnnJniDirectory != null).toString(),
        )
        buildConfigField("boolean", "GENIE_BUNDLED", (qnnSdkRoot != null).toString())
        buildConfigField("String", "QNN_HTP_ARCH", "\"$qnnHtpArch\"")
        buildConfigField(
            "String",
            "QNN_SKEL_SHA256",
            "\"${qnnSdkSkelFile?.sha256().orEmpty()}\"",
        )
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++17")
            }
        }
    }

    buildFeatures {
        buildConfig = true
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    sourceSets.getByName("main").jniLibs.srcDir(mossOnnxJniDirectory)
    if (qnnSdkRoot != null) {
        sourceSets.getByName("main").jniLibs.srcDir(qnnSdkJniDirectory)
        sourceSets.getByName("main").assets.srcDir(qnnSdkAssetDirectory)
    }
    if (qnnJniDirectory != null) {
        sourceSets.getByName("main").jniLibs.srcDir(qnnJniDirectory)
    }

    packaging {
        jniLibs {
            useLegacyPackaging = qnnSdkRoot != null || qnnJniDirectory != null
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
    if (qnnSdkRoot != null) {
        dependsOn(prepareQnnSdkJni, prepareQnnSdkAssets)
    }
}
