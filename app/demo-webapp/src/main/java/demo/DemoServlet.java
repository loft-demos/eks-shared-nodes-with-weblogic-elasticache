package demo;

import java.io.IOException;
import java.time.Instant;
import javax.servlet.ServletException;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

/** Plain-text probe endpoint. Also reports whether the ElastiCache endpoint is reachable. */
@WebServlet("/health")
public class DemoServlet extends HttpServlet {

  private static final int CONNECT_TIMEOUT_MILLIS = 2000;

  @Override
  protected void doGet(HttpServletRequest request, HttpServletResponse response)
      throws ServletException, IOException {
    response.setContentType("text/plain");
    response.setHeader("Cache-Control", "no-store");
    response.getWriter().printf("Example Corp WebLogic demo OK at %s%n", Instant.now());
    // Named so a curl against several tenants is self-identifying.
    String tenant = System.getenv("TENANT_NAME");
    if (tenant != null && !tenant.trim().isEmpty()) {
      response.getWriter().printf("tenant=%s%n", tenant.trim());
    }
    response.getWriter().printf("cache=%s%n", cacheStatus());
  }

  private String cacheStatus() {
    CacheConfig cache = CacheConfig.current();
    if (!cache.isReady()) {
      return "pending (" + cache.backend() + " state: " + cache.state() + ")";
    }
    MiniRedis client = null;
    try {
      client = new MiniRedis(cache.endpoint(), cache.port(), cache.tls(), CONNECT_TIMEOUT_MILLIS);
      client.call("PING");
      return "ok (" + cache.endpoint() + ":" + cache.port() + (cache.tls() ? ", TLS)" : ")");
    } catch (IOException e) {
      return "unreachable (" + e.getMessage() + ")";
    } finally {
      if (client != null) {
        client.close();
      }
    }
  }
}
