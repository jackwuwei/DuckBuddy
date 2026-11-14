plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "robot.duckbuddy.microduck"
    compileSdk = 36

    defaultConfig {
        applicationId = "robot.duckbuddy.microduck"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures { compose = true }

    // 两端共用的资源：文案、字体、鸭子图片、3D 模型、演示画面，原地引用，不复制。
    sourceSets["main"].assets.srcDirs("../../shared/i18n", "../../shared/images", "../../shared/models")
    sourceSets["main"].res.srcDirs("src/main/res", "build/generated/sharedRes")
    androidResources { noCompress += listOf("bin") }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

// 字体放到 res/font（Android 资源名只能小写下划线）。
val copySharedFonts by tasks.registering(Copy::class) {
    from("../../shared/fonts") { include("*.ttf") }
    into(layout.buildDirectory.dir("generated/sharedRes/font"))
    rename("Anton-Regular.ttf", "anton.ttf")
    rename("DMSans.ttf", "dm_sans.ttf")
}
tasks.named("preBuild") { dependsOn(copySharedFonts) }

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.10.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-process:2.9.4")
    implementation("androidx.window:window:1.4.0")
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    // duck-core（UniFFI 生成的 Kotlin 绑定走 JNA）
    implementation("net.java.dev.jna:jna:5.17.0@aar")
    // 视频 + 数据通道：Google libwebrtc（预编译发布版）
    implementation("io.github.webrtc-sdk:android:144.7559.15")
    // 豆包实时语音 WebSocket
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // 扫码：CameraX + ML Kit
    implementation("androidx.camera:camera-camera2:1.5.1")
    implementation("androidx.camera:camera-lifecycle:1.5.1")
    implementation("androidx.camera:camera-view:1.5.1")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
}
