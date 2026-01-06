#!/bin/bash
set -e

# ccw-proxy setup script for Claude Code Web
# Downloads the native binary and configures Gradle to use it

REPO="smh/ccw-proxy"
VERSION="${CCW_PROXY_VERSION:-latest}"

BINARY_NAME="ccw-proxy"
INSTALL_DIR="${HOME}/.local/bin"
BINARY_PATH="${INSTALL_DIR}/ccw-proxy"

# Create install directory
mkdir -p "$INSTALL_DIR"

# Download binary
echo "[ccw-setup] Downloading ${BINARY_NAME}..."
if [ "$VERSION" = "latest" ]; then
  DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${BINARY_NAME}"
else
  DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${VERSION}/${BINARY_NAME}"
fi

curl -fsSL "$DOWNLOAD_URL" -o "$BINARY_PATH"
chmod +x "$BINARY_PATH"

echo "[ccw-setup] Installed ccw-proxy to ${BINARY_PATH}"

# Configure Gradle to use the proxy
GRADLE_PROPS="${HOME}/.gradle/gradle.properties"
mkdir -p "$(dirname "$GRADLE_PROPS")"

# Check if already configured
if grep -q "ccw-proxy configuration" "$GRADLE_PROPS" 2>/dev/null; then
  echo "[ccw-setup] Gradle already configured for ccw-proxy"
else
  # Configure Gradle to use local proxy shim
  cat >> "$GRADLE_PROPS" << 'EOF'

# ccw-proxy configuration
systemProp.http.proxyHost=127.0.0.1
systemProp.http.proxyPort=15080
systemProp.https.proxyHost=127.0.0.1
systemProp.https.proxyPort=15080
EOF
  echo "[ccw-setup] Configured Gradle proxy settings in ${GRADLE_PROPS}"
fi

# Check for upstream proxy configuration
if [ -z "$HTTPS_PROXY" ] && [ -z "$HTTP_PROXY" ]; then
  echo "[ccw-setup] Warning: No HTTPS_PROXY or HTTP_PROXY environment variable set"
  echo "[ccw-setup] ccw-proxy requires an upstream proxy to be configured"
  exit 0
fi

# Save the original upstream proxy URL before we override the env vars
# ccw-proxy reads CCW_UPSTREAM_PROXY to know where to forward requests
if [ -n "$HTTPS_PROXY" ]; then
  export CCW_UPSTREAM_PROXY="$HTTPS_PROXY"
elif [ -n "$HTTP_PROXY" ]; then
  export CCW_UPSTREAM_PROXY="$HTTP_PROXY"
fi

# Stop any existing ccw-proxy instance
if [ -f /tmp/ccw-proxy.pid ]; then
  OLD_PID=$(cat /tmp/ccw-proxy.pid)
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[ccw-setup] Stopping existing ccw-proxy (pid: $OLD_PID)"
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
  fi
fi

# Start the proxy in background
echo "[ccw-setup] Starting ccw-proxy..."

# Use system Java truststore which includes TLS inspection CA
JVM_ARGS=""
if [ -n "$JAVA_HOME" ] && [ -f "$JAVA_HOME/lib/security/cacerts" ]; then
  JVM_ARGS="-Djavax.net.ssl.trustStore=$JAVA_HOME/lib/security/cacerts -Djavax.net.ssl.trustStorePassword=changeit"
  echo "[ccw-setup] Using Java truststore: $JAVA_HOME/lib/security/cacerts"
fi

# Debug: Show certificate store information for troubleshooting
echo "[ccw-setup] Certificate debug info:"
echo "[ccw-setup] --- System Java cacerts ---"
ls -l /etc/ssl/certs/java/cacerts 2>/dev/null || echo "[ccw-setup] /etc/ssl/certs/java/cacerts not found"

echo "[ccw-setup] --- JAVA_HOME cacerts ---"
if [ -n "$JAVA_HOME" ] && [ -f "$JAVA_HOME/lib/security/cacerts" ]; then
  ls -l "$JAVA_HOME/lib/security/cacerts"
  echo "[ccw-setup] Certificates in Java truststore:"
  keytool -list -keystore "$JAVA_HOME/lib/security/cacerts" -storepass changeit 2>/dev/null | grep -E "^[a-zA-Z].*,.*," | head -20
  CERT_COUNT=$(keytool -list -keystore "$JAVA_HOME/lib/security/cacerts" -storepass changeit 2>/dev/null | grep -c "trustedCertEntry" || echo "0")
  echo "[ccw-setup] Total certificates in Java truststore: $CERT_COUNT"
else
  echo "[ccw-setup] JAVA_HOME cacerts not found"
fi

echo "[ccw-setup] --- System CA bundle ---"
if [ -f "/etc/ssl/certs/ca-certificates.crt" ]; then
  ls -l /etc/ssl/certs/ca-certificates.crt
  PEM_COUNT=$(grep -c "BEGIN CERTIFICATE" /etc/ssl/certs/ca-certificates.crt || echo "0")
  echo "[ccw-setup] Total certificates in CA bundle: $PEM_COUNT"
  echo "[ccw-setup] Certificate subjects (first 10):"
  awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' /etc/ssl/certs/ca-certificates.crt | \
    openssl crl2pkcs7 -nocrl -certfile /dev/stdin 2>/dev/null | \
    openssl pkcs7 -print_certs -noout 2>/dev/null | \
    grep "subject=" | head -10 || \
    echo "[ccw-setup] Could not parse CA bundle"
else
  echo "[ccw-setup] /etc/ssl/certs/ca-certificates.crt not found"
fi
echo "[ccw-setup] --- End certificate debug ---"

nohup "$BINARY_PATH" $JVM_ARGS > /tmp/ccw-proxy.log 2>&1 &
echo $! > /tmp/ccw-proxy.pid

# Wait briefly and check if it started
sleep 1
if kill -0 "$(cat /tmp/ccw-proxy.pid)" 2>/dev/null; then
  echo "[ccw-setup] ccw-proxy started (pid: $(cat /tmp/ccw-proxy.pid))"

  # Persist environment variables for Claude Code Web
  # Write to CLAUDE_ENV_FILE so they're available to subsequent commands
  if [ -n "$CLAUDE_ENV_FILE" ]; then
    {
      echo "CCW_UPSTREAM_PROXY=${CCW_UPSTREAM_PROXY}"
      echo "HTTP_PROXY=http://127.0.0.1:15080"
      echo "HTTPS_PROXY=http://127.0.0.1:15080"
      echo "http_proxy=http://127.0.0.1:15080"
      echo "https_proxy=http://127.0.0.1:15080"
    } >> "$CLAUDE_ENV_FILE"
    echo "[ccw-setup] Environment variables written to CLAUDE_ENV_FILE"
  else
    echo "[ccw-setup] Warning: CLAUDE_ENV_FILE not set, env vars may not persist"
  fi

  echo "[ccw-setup] Setup complete!"
else
  echo "[ccw-setup] ERROR: ccw-proxy failed to start. Check /tmp/ccw-proxy.log"
  exit 1
fi
