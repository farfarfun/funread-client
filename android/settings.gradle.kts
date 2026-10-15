// 这三个文件（settings / build / app/build）照搬 Flutter 3.47.7 的官方模板，
// 只改了 namespace 和注释。本机没有 Flutter SDK，`flutter create` 跑不了，
// 所以是按 flutter_tools 的 templates/app/android*.tmpl 一比一手抄的。
// 版本号来自同一版本的 gradle_utils.dart：
//   templateAndroidGradlePluginVersion = 9.1.0
//   templateKotlinGradlePluginVersion  = 2.4.0
//   templateDefaultGradleVersion       = 9.3.1
// 升级 Flutter 时这三处要一起对，别只改 CI 里的 FLUTTER_VERSION。
pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")
