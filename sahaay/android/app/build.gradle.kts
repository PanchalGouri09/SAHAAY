import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("com.google.android.libraries.mapsplatform.secrets-gradle-plugin")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

secrets {
    // android/secrets.properties is the canonical location (kept outside the app
    // module). Point the plugin at it so ${MAPS_API_KEY} in the manifest gets
    // substituted during the manifest merge.
    propertiesFileName = "secrets.properties"
}

val releaseManifestPropertiesFile = rootProject.file("../build/release-manifest.properties")
val releaseManifestProperties = Properties().apply {
    if (releaseManifestPropertiesFile.isFile) {
        releaseManifestPropertiesFile.inputStream().use(::load)
    }
}
val allowInsecureLanForTesting =
    releaseManifestProperties.getProperty("allowInsecureLanForTesting").toBoolean()
val apiHostOctets = releaseManifestProperties.getProperty("apiHost")
    ?.split(".")
    ?.map { it.toIntOrNull() ?: -1 }
val isPrivateIpv4 = apiHostOctets?.let { octets ->
    octets.size == 4 &&
        octets.all { it in 0..255 } &&
        (
            octets[0] == 10 ||
                (octets[0] == 172 && octets[1] in 16..31) ||
                (octets[0] == 192 && octets[1] == 168)
            )
} ?: false
if (
    allowInsecureLanForTesting &&
    (releaseManifestProperties.getProperty("apiScheme") != "http" || !isPrivateIpv4)
) {
    throw GradleException(
        "Cleartext traffic is allowed only for an explicit private-LAN HTTP test build."
    )
}
val allowCleartextTraffic = allowInsecureLanForTesting && isPrivateIpv4

android {
    namespace = "com.example.sahaay"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications 18.x uses java.time on older API levels,
        // so core library desugaring must be enabled or the AAR metadata check
        // fails at build time.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.sahaay"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["allowCleartextTraffic"] = allowCleartextTraffic.toString()
    }

    buildTypes {
        release {
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("com.google.android.libraries.places:places:2.4.0")
    // volley 1.1.1 (transitive, required by Places) is 404 on both Maven repos from this
    // machine; 1.2.1 is already in the local Gradle cache, so force resolution to it.
    implementation("com.android.volley:volley:1.2.1")
}