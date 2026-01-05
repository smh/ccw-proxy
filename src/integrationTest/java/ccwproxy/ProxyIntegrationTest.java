package ccwproxy;

import static org.junit.jupiter.api.Assertions.*;

import io.netty.handler.codec.http.HttpRequest;
import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.littleshoot.proxy.HttpProxyServer;
import org.littleshoot.proxy.impl.DefaultHttpProxyServer;

/**
 * Integration test that verifies ccw-proxy can successfully proxy
 * Gradle dependency downloads through an upstream proxy.
 */
class ProxyIntegrationTest {

    private HttpProxyServer upstreamProxy;
    private Process ccwProxyProcess;
    private int upstreamPort;
    private int ccwProxyPort;
    private AtomicBoolean upstreamWasUsed;

    private static final String TEST_USERNAME = "testuser";
    private static final String TEST_PASSWORD = "testpass";

    @TempDir
    Path tempDir;

    @BeforeEach
    void setUp() throws Exception {
        upstreamWasUsed = new AtomicBoolean(false);

        // Find available ports
        upstreamPort = findAvailablePort();
        ccwProxyPort = findAvailablePort();

        // Start upstream proxy (simulates corporate/upstream proxy)
        upstreamProxy = DefaultHttpProxyServer.bootstrap()
                .withAddress(new InetSocketAddress("127.0.0.1", upstreamPort))
                .withAllowLocalOnly(true)
                .withFiltersSource(new org.littleshoot.proxy.HttpFiltersSourceAdapter() {
                    @Override
                    public org.littleshoot.proxy.HttpFilters filterRequest(HttpRequest originalRequest) {
                        upstreamWasUsed.set(true);
                        return super.filterRequest(originalRequest);
                    }
                })
                .start();

        // Start the actual ccw-proxy application as a separate process
        startCcwProxy();
    }

    private void startCcwProxy() throws Exception {
        Path projectRoot = Path.of(System.getProperty("user.dir"));
        String gradleWrapper =
                System.getProperty("os.name").toLowerCase().contains("win") ? "gradlew.bat" : "./gradlew";

        ProcessBuilder pb = new ProcessBuilder(gradleWrapper, "run", "--quiet");
        pb.directory(projectRoot.toFile());
        pb.redirectErrorStream(true);

        // Configure ccw-proxy via environment variables
        pb.environment()
                .put(
                        "HTTPS_PROXY",
                        String.format("http://%s:%s@127.0.0.1:%d", TEST_USERNAME, TEST_PASSWORD, upstreamPort));
        pb.environment().put("PROXY_SHIM_LISTEN", "127.0.0.1:" + ccwProxyPort);

        ccwProxyProcess = pb.start();

        // Wait for ccw-proxy to be ready by watching for "listening on" message
        BufferedReader reader = new BufferedReader(new InputStreamReader(ccwProxyProcess.getInputStream()));
        long startTime = System.currentTimeMillis();
        long timeout = 60_000; // 60 seconds for Gradle to start the app

        StringBuilder output = new StringBuilder();
        while (System.currentTimeMillis() - startTime < timeout) {
            if (reader.ready()) {
                String line = reader.readLine();
                if (line != null) {
                    output.append(line).append("\n");
                    if (line.contains("[ccw-proxy] listening on")) {
                        return; // Ready!
                    }
                }
            } else {
                Thread.sleep(100);
            }

            // Check if process died
            if (!ccwProxyProcess.isAlive()) {
                fail("ccw-proxy process died during startup. Output:\n" + output);
            }
        }

        ccwProxyProcess.destroyForcibly();
        fail("Timeout waiting for ccw-proxy to start. Output:\n" + output);
    }

    @AfterEach
    void tearDown() {
        if (ccwProxyProcess != null && ccwProxyProcess.isAlive()) {
            ccwProxyProcess.destroyForcibly();
            try {
                ccwProxyProcess.waitFor(5, TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        if (upstreamProxy != null) {
            upstreamProxy.stop();
        }
    }

    @Test
    void downloadsDependencyThroughProxy() throws Exception {
        // Create a minimal Gradle project
        createMinimalGradleProject();

        // Run Gradle with proxy settings pointing to ccw-proxy
        // Use --refresh-dependencies to force fresh downloads (bypass cache)
        ProcessBuilder pb = new ProcessBuilder(
                findGradleWrapper(),
                "dependencies",
                "--no-daemon",
                "--refresh-dependencies",
                "-Dhttp.proxyHost=127.0.0.1",
                "-Dhttp.proxyPort=" + ccwProxyPort,
                "-Dhttps.proxyHost=127.0.0.1",
                "-Dhttps.proxyPort=" + ccwProxyPort);
        pb.directory(tempDir.toFile());
        pb.redirectErrorStream(true);

        // Clear any inherited proxy settings
        pb.environment().remove("HTTP_PROXY");
        pb.environment().remove("HTTPS_PROXY");
        pb.environment().remove("http_proxy");
        pb.environment().remove("https_proxy");
        // Use isolated Gradle user home to avoid global settings
        Path gradleUserHome = tempDir.resolve(".gradle-home");
        Files.createDirectories(gradleUserHome);
        pb.environment().put("GRADLE_USER_HOME", gradleUserHome.toString());
        // Override Gradle opts to ensure our proxy settings are used
        pb.environment()
                .put(
                        "GRADLE_OPTS",
                        "-Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=" + ccwProxyPort
                                + " -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort="
                                + ccwProxyPort + " -Dhttp.nonProxyHosts= -Dhttps.nonProxyHosts=");

        Process process = pb.start();
        StringBuilder output = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
            String line;
            while ((line = reader.readLine()) != null) {
                output.append(line).append("\n");
            }
        }

        boolean completed = process.waitFor(120, TimeUnit.SECONDS);
        assertTrue(completed, "Gradle should complete within timeout");

        int exitCode = process.exitValue();
        assertEquals(0, exitCode, "Gradle should succeed. Output:\n" + output);

        // Verify the upstream proxy was actually used
        assertTrue(upstreamWasUsed.get(), "Upstream proxy should have been used");

        // Verify the output contains Spring Boot and Google Cloud dependencies
        String outputStr = output.toString();
        assertTrue(
                outputStr.contains("spring-boot") && outputStr.contains("spring-web"),
                "Output should reference Spring Boot dependencies. Output: " + outputStr);
        assertTrue(
                outputStr.contains("google-cloud") && outputStr.contains("libraries-bom"),
                "Output should reference Google Cloud dependencies. Output: " + outputStr);
    }

    private void createMinimalGradleProject() throws IOException {
        // Create build.gradle with Spring Boot + Google Cloud BOMs (lots of transitives)
        // This stress tests the proxy with many dependency downloads
        String buildGradle = """
                plugins {
                    id 'java'
                    id 'org.springframework.boot' version '3.4.1'
                    id 'io.spring.dependency-management' version '1.1.7'
                }

                repositories {
                    mavenCentral()
                }

                dependencyManagement {
                    imports {
                        mavenBom 'com.google.cloud:libraries-bom:26.51.0'
                    }
                }

                dependencies {
                    // Spring Boot starters
                    implementation 'org.springframework.boot:spring-boot-starter-web'
                    implementation 'org.springframework.boot:spring-boot-starter-data-jpa'
                    implementation 'org.springframework.boot:spring-boot-starter-validation'
                    implementation 'org.springframework.boot:spring-boot-starter-security'
                    implementation 'org.springframework.boot:spring-boot-starter-actuator'
                    runtimeOnly 'com.h2database:h2'

                    // Google Cloud libraries (managed by BOM)
                    implementation 'com.google.cloud:google-cloud-storage'
                    implementation 'com.google.cloud:google-cloud-bigquery'
                    implementation 'com.google.cloud:google-cloud-pubsub'
                    implementation 'com.google.cloud:google-cloud-secretmanager'

                    // Test dependencies
                    testImplementation 'org.springframework.boot:spring-boot-starter-test'
                    testImplementation 'org.springframework.security:spring-security-test'
                }
                """;
        Files.writeString(tempDir.resolve("build.gradle"), buildGradle);

        // Create settings.gradle
        Files.writeString(tempDir.resolve("settings.gradle"), "rootProject.name = 'test-project'");

        // Create gradle.properties to override any global proxy settings
        // Must explicitly clear nonProxyHosts to ensure proxy is used
        String gradleProps = """
                systemProp.http.proxyHost=127.0.0.1
                systemProp.http.proxyPort=%d
                systemProp.https.proxyHost=127.0.0.1
                systemProp.https.proxyPort=%d
                systemProp.http.nonProxyHosts=
                systemProp.https.nonProxyHosts=
                """.formatted(ccwProxyPort, ccwProxyPort);
        Files.writeString(tempDir.resolve("gradle.properties"), gradleProps);

        // Create minimal source to make it a valid project
        Path srcDir = tempDir.resolve("src/main/java");
        Files.createDirectories(srcDir);
        Files.writeString(srcDir.resolve("Empty.java"), "public class Empty {}");

        // Copy gradle wrapper from this project
        copyGradleWrapper();
    }

    private void copyGradleWrapper() throws IOException {
        Path projectRoot = Path.of(System.getProperty("user.dir"));

        // Copy gradlew
        Path gradlew = projectRoot.resolve("gradlew");
        if (Files.exists(gradlew)) {
            Files.copy(gradlew, tempDir.resolve("gradlew"));
            tempDir.resolve("gradlew").toFile().setExecutable(true);
        }

        // Copy gradlew.bat
        Path gradlewBat = projectRoot.resolve("gradlew.bat");
        if (Files.exists(gradlewBat)) {
            Files.copy(gradlewBat, tempDir.resolve("gradlew.bat"));
        }

        // Copy gradle/wrapper directory
        Path wrapperDir = projectRoot.resolve("gradle/wrapper");
        if (Files.exists(wrapperDir)) {
            Path targetWrapperDir = tempDir.resolve("gradle/wrapper");
            Files.createDirectories(targetWrapperDir);
            Files.list(wrapperDir).forEach(source -> {
                try {
                    Files.copy(source, targetWrapperDir.resolve(source.getFileName()));
                } catch (IOException e) {
                    throw new RuntimeException(e);
                }
            });
        }
    }

    private String findGradleWrapper() {
        String os = System.getProperty("os.name").toLowerCase();
        if (os.contains("win")) {
            return tempDir.resolve("gradlew.bat").toString();
        }
        return tempDir.resolve("gradlew").toString();
    }

    private static int findAvailablePort() throws IOException {
        try (ServerSocket socket = new ServerSocket(0)) {
            return socket.getLocalPort();
        }
    }
}
