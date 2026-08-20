package demo;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * Reads the cache connection details that the tenant-side endpoint publisher
 * writes into a ConfigMap.
 *
 * The ConfigMap is mounted as a directory (never with subPath), so kubelet refreshes
 * the files in place when the endpoint is finally reported. Re-reading on a short TTL
 * means the WebLogic domain picks up a newly provisioned cache without a restart, which
 * matters because a WebLogic restart is the slowest thing in this demo.
 */
final class CacheConfig {

  private static final String DEFAULT_DIR = "/u01/cache-config";
  private static final long TTL_MILLIS = 5000L;

  private static volatile CacheConfig cached;
  private static volatile long cachedAt;

  private final String endpoint;
  private final int port;
  private final boolean tls;
  private final String state;
  private final String backend;

  private CacheConfig(String endpoint, int port, boolean tls, String state, String backend) {
    this.endpoint = endpoint;
    this.port = port;
    this.tls = tls;
    this.state = state;
    this.backend = backend;
  }

  static CacheConfig current() {
    long now = System.currentTimeMillis();
    CacheConfig snapshot = cached;
    if (snapshot != null && now - cachedAt < TTL_MILLIS) {
      return snapshot;
    }
    CacheConfig loaded = load();
    cached = loaded;
    cachedAt = now;
    return loaded;
  }

  private static CacheConfig load() {
    Path dir = Paths.get(value(System.getenv("CACHE_CONFIG_DIR"), DEFAULT_DIR));
    String endpoint = read(dir, "endpoint");
    String port = read(dir, "port");
    String tls = read(dir, "tls");
    String state = read(dir, "state");
    int parsedPort = 6379;
    try {
      if (!port.isEmpty()) {
        parsedPort = Integer.parseInt(port);
      }
    } catch (NumberFormatException ignored) {
      // fall back to the default Redis port rather than failing the page render
    }
    return new CacheConfig(endpoint, parsedPort, "true".equalsIgnoreCase(tls),
        value(state, "unknown"), value(read(dir, "backend"), "unknown"));
  }

  private static String read(Path dir, String key) {
    Path file = dir.resolve(key);
    if (!Files.isReadable(file)) {
      return "";
    }
    try {
      return new String(Files.readAllBytes(file), StandardCharsets.UTF_8).trim();
    } catch (IOException e) {
      return "";
    }
  }

  private static String value(String candidate, String fallback) {
    return candidate == null || candidate.isEmpty() ? fallback : candidate;
  }

  boolean isReady() {
    return !endpoint.isEmpty();
  }

  String endpoint() {
    return endpoint;
  }

  int port() {
    return port;
  }

  boolean tls() {
    return tls;
  }

  String state() {
    return state;
  }

  /** "elasticache", "in-tenant", or "unknown". Drives how the page describes itself. */
  String backend() {
    return backend;
  }

  boolean isElastiCache() {
    return "elasticache".equals(backend);
  }
}
