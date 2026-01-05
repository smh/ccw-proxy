plugins {
    java
    application
    id("org.graalvm.buildtools.native") version "0.11.1"
    id("com.diffplug.spotless") version "8.1.0"
}

group = "io.github.smh"
version = "1.0.0"

repositories {
    mavenCentral()
}

dependencies {
    implementation("io.github.littleproxy:littleproxy:2.5.0")
    implementation("org.slf4j:slf4j-simple:2.0.16")
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(25))
    }
}

// Integration test source set
sourceSets {
    create("integrationTest") {
        compileClasspath += sourceSets.main.get().output
        runtimeClasspath += sourceSets.main.get().output
    }
}

val integrationTestImplementation by configurations.getting {
    extendsFrom(configurations.implementation.get())
}
val integrationTestRuntimeOnly by configurations.getting {
    extendsFrom(configurations.runtimeOnly.get())
}

dependencies {
    integrationTestImplementation("org.junit.jupiter:junit-jupiter:5.11.4")
    integrationTestRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

val integrationTest = tasks.register<Test>("integrationTest") {
    description = "Runs integration tests."
    group = "verification"
    testClassesDirs = sourceSets["integrationTest"].output.classesDirs
    classpath = sourceSets["integrationTest"].runtimeClasspath
    useJUnitPlatform()
    shouldRunAfter(tasks.test)
}

tasks.register("verify") {
    description = "Runs all verification tasks including integration tests."
    group = "verification"
    dependsOn(tasks.check, integrationTest)
}

application {
    mainClass.set("ccwproxy.CcwProxy")
}

graalvmNative {
    binaries {
        named("main") {
            imageName.set("ccw-proxy")
            mainClass.set("ccwproxy.CcwProxy")
            buildArgs.addAll(
                "--no-fallback",
                "-H:+ReportExceptionStackTraces",
                "--initialize-at-build-time=org.slf4j",
                "-H:ReflectionConfigurationFiles=$projectDir/src/main/resources/META-INF/native-image/reflect-config.json",
            )
        }
    }
}

spotless {
    java {
        palantirJavaFormat()
        formatAnnotations()
    }
}

val isCI = System.getenv().containsKey("CI")

tasks.withType<JavaCompile> {
    if (!isCI) {
        finalizedBy("spotlessApply")
    }
}
