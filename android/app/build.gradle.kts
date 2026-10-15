plugins {
    id("com.android.application")
    // Flutter 的 Gradle 插件必须排在 Android / Kotlin 插件之后。
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.farfarfun.funread_client"

    // compileSdk / minSdk / targetSdk / ndkVersion 全部跟着 Flutter SDK 走，
    // 不写死数字：写死之后每次升 Flutter 都要人工对一遍，而对错了的表现是
    // 插件编译失败或 NDK 版本冲突，排查成本远高于这一行的「不确定性」。
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.farfarfun.funread_client"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 还没有发布签名。先用 debug 签名让 `flutter build apk --release`
            // 能跑通；真正出包之前必须换成 key.properties 里的正式签名。
            signingConfig = signingConfigs.getByName("debug")
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
