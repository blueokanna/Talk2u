import groovy.json.JsonSlurper
import java.security.MessageDigest
import java.util.zip.ZipFile
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

data class RustlsAndroidArtifact(val repository: File, val version: String)

val ortVersion = "1.26.0"
val qnnPluginVersion = "2.4.0"
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
val bundledQnnDirectory = file("src/main/jniLibs").canonicalFile
val bundledQnnArm64Directory = bundledQnnDirectory.resolve("arm64-v8a")
val bundledQnnReady = listOf(
    "libonnxruntime.so",
    "libonnxruntime_providers_qnn.so",
    "libQnnHtp.so",
    "libQnnHtpPrepare.so",
    "libQnnHtpV81Skel.so",
    "libQnnHtpV81CalculatorStub.so",
    "libQnnHtpV81Stub.so",
    "libQnnSystem.so",
).all { bundledQnnArm64Directory.resolve(it).isFile }
val qnnConfigured = qnnSdkRoot != null || qnnJniDirectory != null || bundledQnnReady
val hardwareRuntimeReady = qnnConfigured
val cubismSdkRoot = providers
    .gradleProperty("talk2u.cubismSdkRoot")
    .orElse(providers.environmentVariable("TALK2U_CUBISM_SDK_ROOT"))
    .getOrElse("D:/CubismSdkForNative-5")
    .trim()
    .let(::file)
    .canonicalFile

require(Regex("v[0-9]+").matches(qnnHtpArch)) {
    "TALK2U_QNN_HTP_ARCH must look like v81: $qnnHtpArch"
}
require(qnnSdkRoot == null || qnnJniDirectory == null) {
    "Configure TALK2U_QNN_SDK_ROOT or TALK2U_QNN_JNI_DIR, not both"
}
require(cubismSdkRoot.resolve("Core/include/Live2DCubismCore.h").isFile) {
    "Cubism SDK for Native 5 Core headers are missing: $cubismSdkRoot"
}
require(cubismSdkRoot.resolve("Core/lib/android/arm64-v8a/libLive2DCubismCore.a").isFile) {
    "Cubism SDK for Native 5 arm64 Core library is missing: $cubismSdkRoot"
}
require(cubismSdkRoot.resolve("Framework/CMakeLists.txt").isFile) {
    "Cubism SDK for Native 5 Framework is missing: $cubismSdkRoot"
}
require(cubismSdkRoot.resolve("Samples/OpenGL/thirdParty/stb/stb_image.h").isFile) {
    "Cubism SDK for Native 5 stb dependency is missing: $cubismSdkRoot"
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
            it.isFile && Regex("libQnnHtpV[0-9]+Skel\\.so").matches(it.name)
        } == true,
    ) {
        "TALK2U_QNN_JNI_DIR is missing an arm64-v8a/libQnnHtpV*Skel.so: $it"
    }
    require(
        arm64.listFiles()?.any {
            it.isFile && Regex("libQnnHtpV[0-9]+CalculatorStub\\.so").matches(it.name)
        } == true,
    ) {
        "TALK2U_QNN_JNI_DIR is missing an arm64-v8a/libQnnHtpV*CalculatorStub.so: $it"
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
val bundledQnnSkelFile = file(
    "src/main/assets/qnn/htp/$qnnHtpArch/libQnnHtp${qnnHtpArch.uppercase()}Skel.so",
).canonicalFile
val effectiveQnnSkelFile = qnnSdkSkelFile ?: bundledQnnSkelFile.takeIf(File::isFile)
val qnnSdkMetadata = qnnSdkRoot?.resolve("sdk.yaml")?.takeIf(File::isFile)?.readText().orEmpty()
fun sdkMetadataValue(name: String): String = Regex("(?m)^${Regex.escape(name)}:\\s*(\\S+)\\s*$")
    .find(qnnSdkMetadata)
    ?.groupValues
    ?.get(1)
    .orEmpty()
val qairtSdkVersion = sdkMetadataValue("version").ifEmpty {
    if (bundledQnnReady) "2.48.0" else ""
}
val qairtSdkBuildId = sdkMetadataValue("build_id")
qnnSdkRoot?.let {
    require(it.isDirectory) { "TALK2U_QNN_SDK_ROOT is not a QAIRT SDK directory: $it" }
    val host = requireNotNull(qnnSdkHostDirectory)
    listOf(
        "libQnnHtp.so",
        "libQnnSystem.so",
        "libQnnHtpPrepare.so",
        "libQnnHtp${qnnHtpArch.uppercase()}Skel.so",
        "libQnnHtp${qnnHtpArch.uppercase()}CalculatorStub.so",
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

fun ByteArray.containsAscii(value: String): Boolean {
    val marker = value.toByteArray(Charsets.US_ASCII)
    if (marker.isEmpty()) return true
    if (size < marker.size) return false
    outer@ for (offset in 0..size - marker.size) {
        for (index in marker.indices) {
            if (this[offset + index] != marker[index]) continue@outer
        }
        return true
    }
    return false
}

require(
    bundledQnnArm64Directory.resolve("libonnxruntime.so").sha256() ==
        "d3713857b9ba0e695875b6e8f958f431eb4b113dbe3f54b830ad63aa446b0c21",
) { "libonnxruntime.so does not match the QNN Plugin EP 2.4.0 build" }
require(
    bundledQnnArm64Directory.resolve("libonnxruntime_providers_qnn.so").sha256() ==
        "2fd72fb234ab08db037fca8458f495533512498598053709b947093ca9e8fb2c",
) { "libonnxruntime_providers_qnn.so is not the validated Plugin EP 2.4.0 build" }
require(
    file("src/main/cpp/third_party/onnxruntime/include/onnxruntime_c_api.h").sha256() ==
        "f09c0d8584aae94dced9bb05cff8579f4f6c5c4a2271413ea8ab27bd0bbf46aa",
) { "ONNX Runtime headers do not match the validated API 26 build" }
mapOf(
    "libQnnHtp.so" to "4eaa10f59fce051e32012d6b4399c0576f5332c23349b6cc7452f9dcf8f270c7",
    "libQnnHtpPrepare.so" to "3e408206c9f3f24f60991476efdff388a271ff06411c18d02660a6ceac24cd0a",
    "libQnnHtpV81.so" to "946dbf8e0a60ce3f1ef9a892ebb8f4f94a8392308a1187fa866a1fdb1c9ef010",
    "libQnnHtpV81CalculatorStub.so" to
        "47c772ad17b2426158cd28a148b3583ea072b9121caba30c9e983c2c6f04bc09",
    "libQnnHtpV81Skel.so" to "87e6463b4b4441eedb1b2ae889443510249eae4d6533278d3a5c798b8eea25d1",
    "libQnnHtpV81Stub.so" to "29d25ba60553f80210835f778854b6e6b542059e0c2296b99b65d2b0cb24cab6",
    "libQnnSystem.so" to "7ee62754b67a1f0f3b1defc1c441ff59d5ed4a02bb34f9437def7b7c8651062d",
).forEach { (library, expectedDigest) ->
    require(bundledQnnArm64Directory.resolve(library).sha256() == expectedDigest) {
        "$library does not match the validated QAIRT 2.48 HTP v81 deployment"
    }
}

val sherpaQnnAar = file("libs/sherpa-onnx-kotlin-qnn-1.13.4.aar")
require(
    sherpaQnnAar.sha256() ==
        "a36b7c4d7d1b0e303eff1eb324957ee22fdbaa496ec534ab227cb93400ae66ba",
) { "sherpa-onnx Kotlin QNN AAR failed integrity verification" }
ZipFile(sherpaQnnAar).use { archive ->
    val entries = archive.entries().asSequence().map { it.name }.toSet()
    require("classes.jar" in entries) { "sherpa-onnx Kotlin classes are missing" }
    require("jni/arm64-v8a/libsherpa-onnx-jni.so" in entries) {
        "sherpa-onnx arm64 JNI runtime is missing"
    }
    require("jni/arm64-v8a/libsherpa1_ort.so" in entries) {
        "sherpa-onnx isolated ONNX Runtime 1.27 dependency is missing"
    }
    require(entries.none { it.endsWith("/libonnxruntime.so") }) {
        "sherpa-onnx AAR must not bundle a conflicting ONNX Runtime"
    }
    require(entries.none { it.startsWith("jni/") && !it.startsWith("jni/arm64-v8a/") }) {
        "sherpa-onnx QNN AAR must contain arm64-v8a native libraries only"
    }
    val jni = archive.getInputStream(
        requireNotNull(archive.getEntry("jni/arm64-v8a/libsherpa-onnx-jni.so")),
    ).use { it.readBytes() }
    require(jni.containsAscii("QnnInterface_getProviders")) {
        "sherpa-onnx JNI was not linked with the QNN interface"
    }
    require(jni.containsAscii("offline-sense-voice-model-qnn.cc")) {
        "sherpa-onnx JNI is missing the SenseVoice QNN implementation"
    }
    require(
        !jni.containsAscii("Please rebuild sherpa-onnx with -DSHERPA_ONNX_ENABLE_QNN=ON"),
    ) { "sherpa-onnx JNI was compiled with SHERPA_ONNX_ENABLE_QNN=OFF" }
    require(jni.containsAscii("libsherpa1_ort.so") && !jni.containsAscii("libonnxruntime.so")) {
        "sherpa-onnx JNI must use its isolated ONNX Runtime dependency"
    }
}

val genieXAar = file("libs/geniex-android-aar-v0.3.17.aar")
require(
    genieXAar.sha256() ==
        "d794f80d9e171681f507a63cd2a71d3c416df59abdd6168ceffff1dba6e3f765",
) { "GenieX Android 0.3.17 AAR failed integrity verification" }
ZipFile(genieXAar).use { archive ->
    val entries = archive.entries().asSequence().map { it.name }.toSet()
    require("classes.jar" in entries) { "GenieX Kotlin API classes are missing" }
    listOf(
        "jni/arm64-v8a/libgeniex.so",
        "jni/arm64-v8a/libgeniex_core.so",
        "jni/arm64-v8a/libgeniex_plugin_qairt.so",
        "jni/arm64-v8a/libnpu_jni.so",
        "jni/arm64-v8a/libQnnHtp.so",
        "jni/arm64-v8a/libQnnHtpV81Stub.so",
        "jni/arm64-v8a/libQnnHtpV81CalculatorStub.so",
        "jni/arm64-v8a/libQnnHtpV81Skel.so",
    ).forEach { entry ->
        require(entry in entries) { "GenieX AAR is missing $entry" }
    }
}

// GenieX 0.3.17 bundles an older QAIRT runtime than the QNN 2.48 contexts
// used by MOSS and SenseVoice. Keep the SDK and plugins, but remove its
// process-global libQnn* copies so every hardware engine resolves one pinned
// and context-compatible runtime from src/main/jniLibs.
val prepareGenieXRuntimeAar by tasks.registering(Zip::class) {
    archiveFileName.set(genieXAar.name)
    destinationDirectory.set(layout.buildDirectory.dir("generated/geniex-aar"))
    from(zipTree(genieXAar)) {
        exclude("jni/**/libQnn*.so")
    }
}
val genieXRuntimeAar = files(prepareGenieXRuntimeAar.flatMap { it.archiveFile })
    .builtBy(prepareGenieXRuntimeAar)

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
    implementation(genieXRuntimeAar)
    implementation(files(sherpaQnnAar))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation(
        "rustls:rustls-platform-verifier:${rustlsAndroidArtifact.version}",
    )
}

val qnnSdkJniDirectory = layout.buildDirectory.dir("generated/qnn/jniLibs")
val prepareQnnSdkJni by tasks.registering(Sync::class) {
    qnnSdkHostDirectory?.let { host ->
        from(host) {
            include(
                "libQnnHtp.so",
                "libQnnSystem.so",
                "libQnnHtpPrepare.so",
                "libQnnHtp${qnnHtpArch.uppercase()}Skel.so",
                "libQnnHtp${qnnHtpArch.uppercase()}CalculatorStub.so",
                "libQnnHtp${qnnHtpArch.uppercase()}Stub.so",
            )
            into("arm64-v8a")
        }
    }
    into(qnnSdkJniDirectory)
}
val packagedVendorJniDirectory = layout.buildDirectory.dir("generated/vendor/jniLibs")
val preparePackagedVendorJni by tasks.registering(Sync::class) {
    // ORT, its QNN Plugin EP, and QAIRT 2.48 are a validated deployment set.
    // The sanitized GenieX AAR cannot replace these process-global libraries.
    from(bundledQnnDirectory)
    qnnJniDirectory?.let {
        from(it)
    }
    into(packagedVendorJniDirectory)
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

    defaultConfig {
        applicationId = "com.blue.talk2u"
        // Qualcomm QNN Plugin EP 2.4.0 requires Android API 27.
        minSdk = 27
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField(
            "boolean",
            "QNN_BUNDLED",
            qnnConfigured.toString(),
        )
        buildConfigField("String", "QNN_HTP_ARCH", "\"$qnnHtpArch\"")
        buildConfigField("String", "ORT_VERSION", "\"$ortVersion\"")
        buildConfigField("String", "QNN_PLUGIN_VERSION", "\"$qnnPluginVersion\"")
        buildConfigField("String", "QAIRT_SDK_VERSION", "\"$qairtSdkVersion\"")
        buildConfigField("String", "QAIRT_SDK_BUILD_ID", "\"$qairtSdkBuildId\"")
        buildConfigField(
            "String",
            "QNN_SKEL_SHA256",
            "\"${effectiveQnnSkelFile?.sha256().orEmpty()}\"",
        )
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++20", "-fexceptions", "-frtti")
                arguments += "-DTALK2U_CUBISM_SDK_ROOT=${cubismSdkRoot.invariantSeparatorsPath}"
                arguments += "-DANDROID_STL=c++_shared"
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

    sourceSets.getByName("main").assets.srcDir(
        cubismSdkRoot.resolve("Framework/src/Rendering/OpenGL/Shaders/StandardES"),
    )
    sourceSets.getByName("main").jniLibs.setSrcDirs(
        listOf(packagedVendorJniDirectory.get().asFile),
    )
    if (qnnSdkRoot != null) sourceSets.getByName("main").assets.srcDir(qnnSdkAssetDirectory)

    packaging {
        jniLibs {
            useLegacyPackaging = true
            excludes += setOf(
                "**/libcdsprpc.so",
                "lib/armeabi-v7a/**",
                "lib/x86/**",
                "lib/x86_64/**",
            )
        }
    }

    androidResources {
        noCompress += listOf("onnx", "data", "model", "bin", "so")
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

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any {
        it.project == project && (it.name == "assembleRelease" || it.name == "bundleRelease")
    }
    if (buildsRelease) {
        require(hardwareRuntimeReady) {
            "Release builds require either TALK2U_QNN_SDK_ROOT or " +
                "TALK2U_QNN_JNI_DIR. " +
                "CPU-only production packages are forbidden."
        }
    }
}

flutter {
    source = "../.."
}

tasks.named("preBuild").configure {
    dependsOn(prepareGenieXRuntimeAar, preparePackagedVendorJni)
    if (qnnSdkRoot != null) {
        dependsOn(prepareQnnSdkJni, prepareQnnSdkAssets)
    }
}
