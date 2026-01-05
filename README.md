# ccw-proxy

A lightweight native HTTP/HTTPS proxy shim for Claude Code Web environments.

## Problem

Claude Code Web's sandbox uses a security proxy that returns `401 Unauthorized` instead of RFC-compliant `407 Proxy Authentication Required`. Java-based tools (Gradle, Maven) don't handle this, causing dependency downloads to fail.

## Solution

ccw-proxy sits between your Java tools and Claude's upstream proxy, properly injecting authentication headers.

```
┌─────────────┐         ┌───────────┐         ┌─────────────────┐
│   Gradle    │──HTTP──►│ ccw-proxy │──HTTPS─►│ Claude's Proxy  │
│  (no auth)  │         │ (local)   │ (auth)  │ (upstream)      │
└─────────────┘         └───────────┘         └─────────────────┘
```

## Quick Start (Claude Code Web)

Add to your project's `.claude/sessionStartup.sh`:

```bash
curl -fsSL https://github.com/smh/ccw-proxy/releases/latest/download/ccw-setup.sh | bash
```

## Manual Installation

```bash
# Download (Linux amd64)
curl -fsSL https://github.com/smh/ccw-proxy/releases/latest/download/ccw-proxy-linux-amd64 -o ccw-proxy
chmod +x ccw-proxy

# Run (reads HTTPS_PROXY from environment)
./ccw-proxy
```

### Available Binaries

- `ccw-proxy-linux-amd64` - Linux x86_64
- `ccw-proxy-linux-arm64` - Linux ARM64
- `ccw-proxy-macos-amd64` - macOS Intel
- `ccw-proxy-macos-arm64` - macOS Apple Silicon

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `HTTPS_PROXY` or `HTTP_PROXY` | Upstream proxy URL (`http://user:pass@host:port`) | Required |
| `PROXY_SHIM_LISTEN` | Local listen address | `127.0.0.1:15080` |

## Gradle Configuration

Add to `~/.gradle/gradle.properties`:

```properties
systemProp.http.proxyHost=127.0.0.1
systemProp.http.proxyPort=15080
systemProp.https.proxyHost=127.0.0.1
systemProp.https.proxyPort=15080
```

The setup script (`ccw-setup.sh`) configures this automatically.

## Building from Source

```bash
# Standard build (requires Java 21)
./gradlew build

# Native binary (requires GraalVM 21)
./gradlew nativeCompile
```

## Troubleshooting

- Check proxy logs: `cat /tmp/ccw-proxy.log`
- Verify proxy is running: `ps aux | grep ccw-proxy`
- Check environment: `echo $HTTPS_PROXY`
- Test connectivity: `curl -x http://127.0.0.1:15080 https://repo1.maven.org/maven2/`

## License

MIT
