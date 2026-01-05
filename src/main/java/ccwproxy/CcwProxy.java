package ccwproxy;

import io.netty.handler.codec.http.HttpObject;
import io.netty.handler.codec.http.HttpRequest;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.concurrent.CountDownLatch;
import org.littleshoot.proxy.ChainedProxyAdapter;
import org.littleshoot.proxy.ChainedProxyManager;
import org.littleshoot.proxy.HttpProxyServer;
import org.littleshoot.proxy.impl.DefaultHttpProxyServer;

public class CcwProxy {

    public static void main(String[] args) {
        // Parse upstream proxy from environment
        // Prefer CCW_UPSTREAM_PROXY to avoid conflicts - after ccw-proxy starts,
        // HTTP_PROXY/HTTPS_PROXY should be overridden to point to this local proxy
        String proxyUrl = System.getenv("CCW_UPSTREAM_PROXY");
        if (proxyUrl == null) {
            proxyUrl = System.getenv("HTTPS_PROXY");
        }
        if (proxyUrl == null) {
            proxyUrl = System.getenv("HTTP_PROXY");
        }
        if (proxyUrl == null) {
            System.err.println("ERROR: Set CCW_UPSTREAM_PROXY (format: http://user:pass@host:port)");
            System.exit(1);
        }

        URI uri;
        try {
            uri = new URI(proxyUrl);
        } catch (URISyntaxException e) {
            System.err.println("ERROR: Invalid proxy URL: " + e.getMessage());
            System.exit(1);
            return;
        }

        String upstreamHost = uri.getHost();
        int upstreamPort = uri.getPort();
        String userInfo = uri.getUserInfo();

        if (upstreamHost == null || upstreamPort == -1) {
            System.err.println("ERROR: Proxy URL must include host and port");
            System.exit(1);
        }

        if (userInfo == null || !userInfo.contains(":")) {
            System.err.println(
                    "ERROR: Proxy URL must include username and password (format: http://user:pass@host:port)");
            System.exit(1);
        }

        String[] creds = userInfo.split(":", 2);
        String username = URLDecoder.decode(creds[0], StandardCharsets.UTF_8);
        String password = URLDecoder.decode(creds[1], StandardCharsets.UTF_8);
        String basicAuth =
                Base64.getEncoder().encodeToString((username + ":" + password).getBytes(StandardCharsets.UTF_8));

        // Parse listen address
        String listen = System.getenv("PROXY_SHIM_LISTEN");
        if (listen == null) {
            listen = "127.0.0.1:15080";
        }
        String[] listenParts = listen.split(":");
        if (listenParts.length != 2) {
            System.err.println("ERROR: Invalid PROXY_SHIM_LISTEN format (expected host:port)");
            System.exit(1);
        }
        String listenHost = listenParts[0];
        int listenPort;
        try {
            listenPort = Integer.parseInt(listenParts[1]);
        } catch (NumberFormatException e) {
            System.err.println("ERROR: Invalid port in PROXY_SHIM_LISTEN");
            System.exit(1);
            return;
        }

        // Create chained proxy configuration
        final String fUpstreamHost = upstreamHost;
        final int fUpstreamPort = upstreamPort;
        final String fBasicAuth = basicAuth;

        ChainedProxyManager chainedProxyManager = (httpRequest, chainedProxies, flowContext) -> {
            chainedProxies.add(new ChainedProxyAdapter() {
                @Override
                public InetSocketAddress getChainedProxyAddress() {
                    return new InetSocketAddress(fUpstreamHost, fUpstreamPort);
                }

                @Override
                public void filterRequest(HttpObject httpObject) {
                    if (httpObject instanceof HttpRequest) {
                        HttpRequest request = (HttpRequest) httpObject;
                        request.headers().set("Proxy-Authorization", "Basic " + fBasicAuth);
                    }
                }
            });
        };

        // Start proxy server
        HttpProxyServer server = DefaultHttpProxyServer.bootstrap()
                .withAddress(new InetSocketAddress(listenHost, listenPort))
                .withChainProxyManager(chainedProxyManager)
                .withAllowLocalOnly(true)
                .start();

        System.out.println("[ccw-proxy] listening on " + listenHost + ":" + listenPort + " -> upstream " + upstreamHost
                + ":" + upstreamPort);

        // Keep running until shutdown
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println("[ccw-proxy] shutting down...");
            server.stop();
        }));

        // Block main thread to keep the JVM alive
        try {
            new CountDownLatch(1).await();
        } catch (InterruptedException e) {
            // Shutdown triggered
        }
    }
}
