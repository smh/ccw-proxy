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
nohup "$BINARY_PATH" > /tmp/ccw-proxy.log 2>&1 &
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

  # Import TLS inspection CA into Java truststore
  # The upstream proxy does TLS inspection, and Java needs to trust the CA
  echo "[ccw-setup] Checking for TLS inspection CA..."

  # Extract the intermediate CA cert (TLS inspection CA) from any HTTPS connection
  TLS_CA_CERT="/tmp/tls-inspection-ca.pem"
  if echo | openssl s_client -connect repo1.maven.org:443 -proxy 127.0.0.1:15080 -showcerts 2>/dev/null | \
       awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{ if(/BEGIN CERTIFICATE/) n++; if(n==2) print }' > "$TLS_CA_CERT" 2>/dev/null && \
       [ -s "$TLS_CA_CERT" ]; then

    # Check if this looks like a TLS inspection CA (not the real site cert)
    ISSUER=$(openssl x509 -in "$TLS_CA_CERT" -noout -issuer 2>/dev/null || echo "")
    if echo "$ISSUER" | grep -qi "anthropic\|inspection\|sandbox"; then
      echo "[ccw-setup] Found TLS inspection CA: $ISSUER"

      # Find Java truststore
      if [ -n "$JAVA_HOME" ] && [ -f "$JAVA_HOME/lib/security/cacerts" ]; then
        CACERTS="$JAVA_HOME/lib/security/cacerts"
      elif [ -f "/usr/lib/jvm/java-21-openjdk-amd64/lib/security/cacerts" ]; then
        CACERTS="/usr/lib/jvm/java-21-openjdk-amd64/lib/security/cacerts"
      elif [ -f "/usr/lib/jvm/default-java/lib/security/cacerts" ]; then
        CACERTS="/usr/lib/jvm/default-java/lib/security/cacerts"
      else
        # Try to find any Java cacerts
        CACERTS=$(find /usr/lib/jvm -name cacerts -type f 2>/dev/null | head -1)
      fi

      if [ -n "$CACERTS" ] && [ -f "$CACERTS" ]; then
        # Check if already imported
        if ! keytool -list -keystore "$CACERTS" -storepass changeit -alias ccw-tls-inspection-ca >/dev/null 2>&1; then
          echo "[ccw-setup] Importing TLS inspection CA into Java truststore..."
          if keytool -import -trustcacerts -keystore "$CACERTS" -storepass changeit \
               -noprompt -alias ccw-tls-inspection-ca -file "$TLS_CA_CERT" 2>/dev/null; then
            echo "[ccw-setup] TLS inspection CA imported successfully"
          else
            echo "[ccw-setup] Warning: Failed to import TLS inspection CA (may need root)"
          fi
        else
          echo "[ccw-setup] TLS inspection CA already in truststore"
        fi
      else
        echo "[ccw-setup] Warning: Could not find Java truststore"
      fi
    else
      echo "[ccw-setup] No TLS inspection detected (direct connection)"
    fi
  else
    echo "[ccw-setup] Warning: Could not extract TLS certificate"
  fi

  rm -f "$TLS_CA_CERT"

  echo "[ccw-setup] Setup complete!"
else
  echo "[ccw-setup] ERROR: ccw-proxy failed to start. Check /tmp/ccw-proxy.log"
  exit 1
fi
