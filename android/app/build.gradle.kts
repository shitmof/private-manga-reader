plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 签名配置。
//
// 背景：Gradle 把 debug keystore 解析为 $ANDROID_USER_HOME/.android/debug.keystore
// （旧变量是 $ANDROID_SDK_HOME），而不是 $HOME/.android。本机存在两把不同的
// debug keystore，v1.6.0 因此签出了与 v1.5.0 不一致的包，用户无法覆盖升级。
//
// 因此本文件采取「零静默回退」策略：
//   1. 发布构建必须提供 android/key.properties，缺失即失败；
//   2. key.properties 必须声明 storeFile，找不到文件即失败；
//   3. storeFile 的证书 SHA-256 必须等于 expectedCertSha256，否则失败。
// 只有显式传 -PallowDebugSigning=true（本地开发/测试）才允许用默认 debug 密钥。
//
// 为什么用 keytool 取指纹而不是 java.security.KeyStore：
// Gradle 的 Kotlin DSL 脚本里 java.* 类型在部分版本下无法解析。

val expectReleaseSigning: Boolean =
    (project.findProperty("allowDebugSigning") as String?) != "true"

fun keyPropertiesFile(): File = rootProject.file("key.properties")

/// 解析 key.properties。
///
/// 必须剥掉 UTF-8 BOM：Windows 上的 PowerShell `Set-Content -Encoding UTF8`
/// 和不少编辑器都会写入 BOM，而 BOM 会把**第一行**的键名污染成 "\uFEFFstoreFile"，
/// 导致 storeFile 解析失败。
fun readKeyProperties(): Map<String, String> {
    val file = keyPropertiesFile()
    if (!file.exists()) return emptyMap()
    val result = mutableMapOf<String, String>()
    file.readLines().forEach { rawLine ->
        val line = rawLine.removePrefix("\uFEFF").trim()
        if (line.isEmpty() || line.startsWith("#")) return@forEach
        val separator = line.indexOf('=')
        if (separator <= 0) return@forEach
        val key = line.substring(0, separator).trim()
        val value = line.substring(separator + 1).trim()
        if (key.isNotEmpty()) result[key] = value
    }
    return result
}

val keyProperties = readKeyProperties()

/// 读取 keystore 内条目的证书 SHA-256（去冒号大写）。
///
/// 用 Gradle 的 providers.exec 调 keytool，避免在 Kotlin DSL 里引用 java.* 类型
/// （该脚本环境下 java.io / java.util 均无法解析）。
/// 缺少 keytool 或读取失败时直接失败，而不是跳过校验。
fun readCertificateSha256(store: File, storePassword: String, alias: String): String {
    val javaHome = System.getProperty("java.home")
    val keytoolName = if (System.getProperty("os.name").lowercase().contains("win")) {
        "keytool.exe"
    } else {
        "keytool"
    }
    val keytool = File(javaHome, "bin/$keytoolName")
    require(keytool.exists()) {
        "找不到 keytool（java.home=$javaHome），无法校验签名证书。"
    }
    val result = providers.exec {
        commandLine(
            keytool.absolutePath,
            "-list", "-v",
            "-keystore", store.absolutePath,
            "-storepass", storePassword,
            "-alias", alias,
        )
        isIgnoreExitValue = true
    }
    val text = result.standardOutput.asText.get() + result.standardError.asText.get()
    check(result.result.get().exitValue == 0) {
        "keytool 读取证书失败：\n$text\n请核对 key.properties 中的 storePassword / keyAlias。"
    }
    val match = Regex("SHA256:\\s*([0-9A-Fa-f:]{95})").find(text)
        ?: error("未能从 keytool 输出解析出证书 SHA-256。\n$text")
    return match.groupValues[1].replace(":", "").uppercase()
}

fun resolveStoreFile(): File? {
    val fromProperties = keyProperties["storeFile"]
    if (expectReleaseSigning && fromProperties == null) {
        throw GradleException(
            "发布构建必须提供 android/key.properties 并声明 storeFile。\n" +
                "缺少配置时使用默认 debug 密钥会签出「同一台设备无法覆盖安装」的包。\n" +
                "若确实只做本地开发构建，请显式传 -PallowDebugSigning=true。",
        )
    }
    if (fromProperties != null) {
        val direct = File(fromProperties)
        if (direct.exists()) return direct
        val relative = rootProject.file(fromProperties)
        if (relative.exists()) return relative
        throw GradleException(
            "key.properties 指定了 storeFile=$fromProperties，但找不到该文件。" +
                "已尝试：${direct.absolutePath} 与 ${relative.absolutePath}。",
        )
    }
    val home = System.getProperty("user.home") ?: return null
    val fallback = File(home, ".android/debug.keystore")
    println("[拾画阁签名] 开发构建，使用默认 debug 密钥：${fallback.absolutePath}")
    return if (fallback.exists()) fallback else null
}

val resolvedStore = resolveStoreFile()

// 发布构建校验：证书指纹必须与预期一致。
val verifiedCertificate: String? = if (resolvedStore != null && expectReleaseSigning) {
    val expected = keyProperties["expectedCertSha256"]
        ?: throw GradleException(
            "key.properties 缺少 expectedCertSha256。\n" +
                "必须固定预期证书指纹，否则换错密钥也能构建成功。",
        )
    val actual = readCertificateSha256(
        store = resolvedStore,
        storePassword = keyProperties["storePassword"] ?: "android",
        alias = keyProperties["keyAlias"] ?: "androiddebugkey",
    )
    if (!actual.equals(expected, ignoreCase = true)) {
        throw GradleException(
            "签名证书指纹不匹配，已停止构建。\n" +
                "  预期：$expected\n  实际：$actual\n" +
                "  密钥：${resolvedStore.absolutePath}\n" +
                "用错密钥会签出无法覆盖安装的包。若这是有意切换渠道，请先更新 expectedCertSha256。",
        )
    }
    actual
} else {
    null
}

println(
    "[拾画阁签名] 模式=" + (if (expectReleaseSigning) "发布校验" else "开发(allowDebugSigning)") +
        " storeFile=${resolvedStore?.absolutePath ?: "<未找到>"}" +
        " 证书=${verifiedCertificate ?: "<未校验>"}",
)

android {
    namespace = "com.shitmof.private_manga_reader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // signingConfigs 属于 android 扩展，必须在 android {} 内部访问。
    if (resolvedStore != null) {
        signingConfigs.create("releaseFromProperties") {
            storeFile = resolvedStore
            storePassword = keyProperties["storePassword"]
                ?: System.getenv("SHIHUAGE_STORE_PASSWORD")
                ?: "android"
            keyAlias = keyProperties["keyAlias"]
                ?: System.getenv("SHIHUAGE_KEY_ALIAS")
                ?: "androiddebugkey"
            keyPassword = keyProperties["keyPassword"]
                ?: System.getenv("SHIHUAGE_KEY_PASSWORD")
                ?: "android"
        }
    }

    defaultConfig {
        applicationId = "com.shitmof.private_manga_reader"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 升级必须可覆盖安装：一旦改用新密钥，已装用户将无法就地升级，
            // 只能卸载重装（会丢失书架数据）。请始终保持同一把密钥。
            signingConfig = if (resolvedStore != null) {
                signingConfigs.getByName("releaseFromProperties")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
