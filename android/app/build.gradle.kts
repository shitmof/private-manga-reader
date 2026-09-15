plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 签名配置。
//
// 为什么不能依赖默认的 debug signingConfig：Gradle 把 debug keystore 解析为
// $ANDROID_USER_HOME/.android/debug.keystore（旧变量是 $ANDROID_SDK_HOME），
// 而不是 $HOME/.android。本机 ANDROID_USER_HOME 指向 E:\Android\.android，
// 与 v1.5.0 实际使用的 C:\Users\<user>\.android\debug.keystore 并非同一把密钥，
// 会导致同一台设备上的新版本无法覆盖安装。
//
fun keyPropertiesFile(): File = rootProject.file("key.properties")

/// 解析 key.properties。
///
/// 必须剥掉 UTF-8 BOM：Windows 上的 PowerShell `Set-Content -Encoding UTF8`
/// 和不少编辑器都会写入 BOM，而 BOM 会把**第一行**的键名污染成 "\uFEFFstoreFile"，
/// 导致 storeFile 解析失败。若此时再静默回退到默认密钥，
/// 就会签出「同一台设备无法覆盖安装」的包，且完全看不出原因。
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

fun resolveStoreFile(): File? {
    val fromProperties = keyProperties["storeFile"]
    if (fromProperties != null) {
        val direct = File(fromProperties)
        if (direct.exists()) return direct
        val relative = rootProject.file(fromProperties)
        if (relative.exists()) return relative
        // 显式指定却找不到：直接失败，绝不回退。
        // 静默回退会签出无法覆盖安装的包，比构建失败危险得多。
        throw GradleException(
            "key.properties 指定了 storeFile=$fromProperties，但找不到该文件。" +
                "已尝试：${direct.absolutePath} 与 ${relative.absolutePath}。" +
                "请修正路径，或删除 android/key.properties 以使用默认 debug 密钥。",
        )
    }
    System.getenv("SHIHUAGE_KEYSTORE")?.let { path ->
        val file = File(path)
        if (file.exists()) return file
    }
    val home = System.getProperty("user.home") ?: return null
    val fallback = File(home, ".android/debug.keystore")
    println("[拾画阁签名] 未指定 key.properties，使用默认密钥：${fallback.absolutePath}")
    return if (fallback.exists()) fallback else null
}

val resolvedStore = resolveStoreFile()

// 显式打印签名解析结果：静默回退是危险的（会导致发布包用了非预期密钥，
// 用户无法覆盖升级，而且完全看不出来）。
println(
    "[拾画阁签名] key.properties=${keyPropertiesFile().absolutePath} " +
        "exists=${keyPropertiesFile().exists()} " +
        "storeFile=${resolvedStore?.absolutePath ?: "<未找到>"}",
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
