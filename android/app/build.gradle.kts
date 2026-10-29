plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "com.muellhaus.nostalgex"
    compileSdk = 37

    defaultConfig {
        applicationId = "com.muellhaus.nostalgex"
        // The SHIELD runs Android 11 (API 30); 28 still covers older Android TV boxes.
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        // A release build runs much faster than a debug one on the TV (no debugger hooks, full
        // compiler optimisation). Until there is a store listing it is signed with the local
        // debug key, so `./gradlew :app:installRelease` sideloads it like the debug build.
        // Shrinking stays off until R8 rules for kotlinx.serialization are checked on a device.
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        compose = true
    }

    lint {
        // Fail on a call the TV's Android doesn't have. :engine is guarded by compiling
        // against the JDK 8 API instead (engine/build.gradle.kts), since lint has no minSdk for it.
        fatal += "NewApi"
    }
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    implementation(project(":engine"))
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.okhttp)
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.exoplayer.hls)
    implementation(libs.media3.ui)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.tv.material)
    implementation(libs.activity.compose)
    implementation(libs.zxing.core)
}
