# ccw-proxy

A lightweight native HTTP/HTTPS proxy shim for Claude Code Web environments.

## Building

```bash
# Standard build (requires Java 25)
./gradlew build

# Native binary (requires GraalVM 25)
./gradlew nativeCompile
```

## Running

Requires `HTTPS_PROXY` or `HTTP_PROXY` environment variable:

```bash
export HTTPS_PROXY="http://user:pass@host:port"
./ccw-proxy
```

## Testing locally

```bash
# Start the proxy
./gradlew run &

# Test with curl
curl -x http://127.0.0.1:15080 https://repo1.maven.org/maven2/
```
