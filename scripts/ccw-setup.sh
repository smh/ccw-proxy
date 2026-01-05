#!/bin/bash
set -e

# ccw-proxy setup script for Claude Code Web
# Downloads the native binary and configures Gradle to use it

REPO="smh/ccw-proxy"
VERSION="${CCW_PROXY_VERSION:-latest}"

# Detect OS and architecture
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$OS" in
  linux) OS="linux" ;;
  darwin) OS="macos" ;;
  *) echo "[ccw-setup] Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "[ccw-setup] Unsupported architecture: $ARCH"; exit 1 ;;
esac

BINARY_NAME="ccw-proxy-${OS}-${ARCH}"
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
  echo "[ccw-setup] Setup complete! Gradle will now use the proxy shim."
else
  echo "[ccw-setup] ERROR: ccw-proxy failed to start. Check /tmp/ccw-proxy.log"
  exit 1
fi
