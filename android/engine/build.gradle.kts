// The schedule and channel filter, as plain Kotlin with no Android in it, so the golden
// files from the Apple TV run on the JVM in a second, with no device or emulator.
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        // Compiled against the JDK 8 API, close to what Android guarantees on the TVs this runs
        // on, so a newer JDK call fails here instead of on the TV. Stream.toList (Java 16)
        // compiled against JDK 21 and crashed a SHIELD on Android 11.
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
        freeCompilerArgs.add("-Xjdk-release=1.8")
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_1_8
    targetCompatibility = JavaVersion.VERSION_1_8
}

dependencies {
    implementation(libs.kotlinx.serialization.json)
    testImplementation(libs.junit)
}

/**
 * The web tuner's Jellyfin and Emby scan run over the Roku port's saved server answers, so
 * MediaBrowserScanTest compares the Kotlin scan with the JS's own output. Needs node.
 */
val genMediaBrowserVectors = tasks.register<Exec>("genMediaBrowserVectors") {
    val out = layout.buildDirectory.file("vectors/mediabrowser.json")
    inputs.file("scripts/gen-mediabrowser-vectors.mjs")
    inputs.file(rootDir.parentFile.resolve("plex-tuner.html"))
    inputs.file(rootDir.parentFile.resolve("roku/tests/fixtures/mediabrowser-server.json"))
    inputs.file(rootDir.parentFile.resolve("roku/tests/gen-mediabrowser.mjs"))
    outputs.file(out)
    commandLine("node", "scripts/gen-mediabrowser-vectors.mjs", out.get().asFile.absolutePath)
}

val genEnrichmentVectors = tasks.register<Exec>("genEnrichmentVectors") {
    val out = layout.buildDirectory.file("vectors/enrichment.json")
    inputs.file("scripts/gen-enrichment-vectors.mjs")
    inputs.file(rootDir.parentFile.resolve("scripts/nostalgex-enrichment.js"))
    inputs.file(rootDir.parentFile.resolve("roku/tests/gen-enrichment.mjs"))
    inputs.file(rootDir.parentFile.resolve("channels.json"))
    outputs.file(out)
    commandLine("node", "scripts/gen-enrichment-vectors.mjs", out.get().asFile.absolutePath)
}

/**
 * The web tuner's franchise builder over the Roku port's text edge cases (Unicode titles, case
 * mapping, token boundaries, name order), so FranchiseVectorTest compares the Kotlin port with
 * the JS's own answers. Upstream's golden file is read directly by FranchiseGoldenTest. Needs node.
 */
val genFranchiseVectors = tasks.register<Exec>("genFranchiseVectors") {
    val out = layout.buildDirectory.file("vectors/franchise.json")
    inputs.file("scripts/gen-franchise-vectors.mjs")
    inputs.file(rootDir.parentFile.resolve("scripts/nostalgex-franchise-builder.js"))
    inputs.file(rootDir.parentFile.resolve("roku/tests/gen-franchise.mjs"))
    inputs.file(rootDir.parentFile.resolve("franchises.json"))
    outputs.file(out)
    commandLine("node", "scripts/gen-franchise-vectors.mjs", out.get().asFile.absolutePath)
}

/**
 * The web tuner's server collections run over the Roku port's fixtures, so
 * CollectionsVectorTest compares the Kotlin candidates, folds, numbering and server calls with
 * the JS's own output. Needs node.
 */
val genCollectionsVectors = tasks.register<Exec>("genCollectionsVectors") {
    val out = layout.buildDirectory.file("vectors/collections.json")
    inputs.file("scripts/gen-collections-vectors.mjs")
    inputs.file(rootDir.parentFile.resolve("scripts/nostalgex-collections.js"))
    inputs.file(rootDir.parentFile.resolve("roku/tests/gen-collections.mjs"))
    inputs.file(rootDir.parentFile.resolve("channels.json"))
    outputs.file(out)
    commandLine("node", "scripts/gen-collections-vectors.mjs", out.get().asFile.absolutePath)
}

/** The web tuner's watch state over the Roku port's scripts, for WatchStateTest. Needs node. */
val genWatchVectors = tasks.register<Exec>("genWatchVectors") {
    val out = layout.buildDirectory.file("vectors/watch.json")
    inputs.file("scripts/gen-watch-vectors.mjs")
    inputs.file(rootDir.parentFile.resolve("scripts/nostalgex-watch-state.js"))
    inputs.file(rootDir.parentFile.resolve("roku/tests/gen-watch.mjs"))
    outputs.file(out)
    commandLine("node", "scripts/gen-watch-vectors.mjs", out.get().asFile.absolutePath)
}

tasks.test {
    dependsOn(genMediaBrowserVectors, genEnrichmentVectors, genFranchiseVectors, genCollectionsVectors, genWatchVectors)
    systemProperty("nostalgex.watchVectors", layout.buildDirectory.file("vectors/watch.json").get().asFile.absolutePath)
    systemProperty("nostalgex.collectionsVectors", layout.buildDirectory.file("vectors/collections.json").get().asFile.absolutePath)
    systemProperty("nostalgex.franchiseVectors", layout.buildDirectory.file("vectors/franchise.json").get().asFile.absolutePath)
    systemProperty("nostalgex.enrichmentVectors", layout.buildDirectory.file("vectors/enrichment.json").get().asFile.absolutePath)
    systemProperty("nostalgex.mediaBrowserVectors", layout.buildDirectory.file("vectors/mediabrowser.json").get().asFile.absolutePath)
    // The golden files and channels.json live at the repo root, shared with every surface.
    systemProperty("nostalgex.repoRoot", rootDir.parentFile.absolutePath)
    inputs.files(
        rootDir.parentFile.resolve("scripts/schedule-parity-golden.json"),
        rootDir.parentFile.resolve("scripts/filter-golden.json"),
        rootDir.parentFile.resolve("scripts/stream-quality-golden.json"),
        rootDir.parentFile.resolve("scripts/season-golden.json"),
        rootDir.parentFile.resolve("scripts/franchise-golden.json"),
        rootDir.parentFile.resolve("franchises.json"),
        rootDir.parentFile.resolve("channels.json"),
        rootDir.parentFile.resolve("channels-memberships.json"),
        rootDir.parentFile.resolve("scripts/franchise-lineup-golden.json"),
        rootDir.parentFile.resolve("scripts/watch-cleanup-golden.json"),
    )
}
