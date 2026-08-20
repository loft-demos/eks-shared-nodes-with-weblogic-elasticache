package demo;

import java.io.IOException;
import java.io.PrintWriter;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.List;
import javax.servlet.ServletException;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

/**
 * The page the audience actually looks at.
 *
 * Every request increments a counter in ElastiCache and appends the serving managed
 * server to a short history list. Refreshing shows the request landing on different
 * managed servers while the counter keeps climbing, which is the point: the state lives
 * in an AWS cache the tenant asked for through ACK, not in any one WebLogic JVM.
 */
@WebServlet(urlPatterns = {"/"})
public class CacheDemoServlet extends HttpServlet {

  private static final int CONNECT_TIMEOUT_MILLIS = 3000;
  private static final int HISTORY_LENGTH = 8;
  private static final DateTimeFormatter STAMP = DateTimeFormatter.ofPattern("HH:mm:ss");

  @Override
  protected void doGet(HttpServletRequest request, HttpServletResponse response)
      throws ServletException, IOException {
    response.setContentType("text/html; charset=UTF-8");
    response.setHeader("Cache-Control", "no-store");

    String domainUID = env("DOMAIN_UID", "unknown-domain");
    String serverName = env("SERVER_NAME", env("HOSTNAME", "unknown-server"));
    CacheConfig cache = CacheConfig.current();
    boolean reset = "1".equals(request.getParameter("reset")) || "true".equals(request.getParameter("reset"));

    CacheResult result = cache.isReady()
        ? exercise(cache, domainUID, serverName, reset)
        : CacheResult.pending();

    PrintWriter out = response.getWriter();
    render(out, domainUID, serverName, cache, result, request.getRequestURI());
  }

  private CacheResult exercise(CacheConfig cache, String domainUID, String serverName, boolean reset) {
    String counterKey = "demo:" + domainUID + ":hits";
    String historyKey = "demo:" + domainUID + ":history";
    MiniRedis client = null;
    try {
      client = new MiniRedis(cache.endpoint(), cache.port(), cache.tls(), CONNECT_TIMEOUT_MILLIS);
      if (reset) {
        client.call("DEL", counterKey, historyKey);
      }
      long hits = client.callLong("INCR", counterKey);
      String entry = ZonedDateTime.now().format(STAMP) + "  served by  " + serverName;
      client.call("LPUSH", historyKey, entry);
      client.call("LTRIM", historyKey, "0", Integer.toString(HISTORY_LENGTH - 1));
      client.call("EXPIRE", historyKey, "86400");
      List<Object> history = client.callList("LRANGE", historyKey, "0", Integer.toString(HISTORY_LENGTH - 1));
      return CacheResult.connected(hits, history);
    } catch (IOException e) {
      return CacheResult.failed(e.getMessage() == null ? e.toString() : e.getMessage());
    } finally {
      if (client != null) {
        client.close();
      }
    }
  }

  /**
   * Injected by the tenant cluster template. TENANT_NAME is the vCluster Platform tenant
   * cluster name; TENANT_HOST_NAMESPACE is the namespace on the Control Plane Cluster where
   * the shared operator actually creates these pods - the developer only ever sees "wi".
   * NODE_NAME comes from the downward API and shows which shared node served the request.
   */
  private static final String TENANT_NAME = envOr("TENANT_NAME");
  private static final String HOST_NAMESPACE = envOr("TENANT_HOST_NAMESPACE");
  private static final String NODE_NAME = envOr("NODE_NAME");

  private static String envOr(String key) {
    String value = System.getenv(key);
    return value == null ? "" : value.trim();
  }

  private void render(PrintWriter out, String domainUID, String serverName, CacheConfig cache,
      CacheResult result, String requestUri) {
    out.println("<!doctype html>");
    out.println("<html lang=\"en\"><head><meta charset=\"utf-8\"/>");
    out.println("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>");
    out.println("<title>" + (TENANT_NAME.isEmpty() ? "WebLogic on a Tenant Cluster"
        : escape(TENANT_NAME) + " &middot; WebLogic") + "</title>");
    out.println("<style>");
    out.println(":root{--ink:#050B24;--accent:#FF6600;--muted:#828592;--line:#E6E7E9;--bg:#EDEFF3;}");
    out.println("body{font-family:Inter,system-ui,-apple-system,sans-serif;background:var(--bg);");
    out.println("color:var(--ink);margin:0;padding:2.5rem 1.5rem;line-height:1.5;}");
    out.println(".wrap{max-width:52rem;margin:0 auto;}");
    out.println("h1{font-size:1.6rem;margin:0 0 .25rem;}");
    out.println(".sub{color:var(--muted);margin:0 0 1.75rem;}");
    out.println(".card{background:#fff;border:1px solid var(--line);border-radius:12px;");
    out.println("padding:1.25rem 1.5rem;margin-bottom:1rem;}");
    out.println(".count{font-size:3rem;font-weight:700;color:var(--accent);line-height:1;}");
    out.println("dl{display:grid;grid-template-columns:12rem 1fr;gap:.4rem 1rem;margin:0;}");
    out.println("dt{color:var(--muted);}");
    out.println("dd{margin:0;}");
    out.println("code{font-family:'Roboto Mono',ui-monospace,monospace;color:#48B5FF;");
    out.println("background:var(--ink);padding:.1rem .4rem;border-radius:5px;font-size:.85rem;}");
    out.println("ol{margin:.5rem 0 0;padding-left:1.25rem;}");
    out.println("li{font-family:'Roboto Mono',ui-monospace,monospace;font-size:.85rem;}");
    out.println(".warn{border-left:4px solid var(--accent);}");
    out.println(".chip{display:inline-block;vertical-align:middle;background:#FFE0CC;");
    out.println("color:#CC5100;border-radius:999px;padding:.15rem .7rem;font-size:.8rem;");
    out.println("font-weight:600;letter-spacing:.02em;margin-left:.5rem;}");
    out.println("a.btn{display:inline-block;background:var(--accent);color:#fff;text-decoration:none;");
    out.println("padding:.5rem 1rem;border-radius:8px;font-size:.9rem;}");
    out.println("a.btn:hover{background:#FF8433;}");
    out.println("</style></head><body><div class=\"wrap\">");

    out.println("<h1>WebLogic on a shared-node tenant cluster"
        + (TENANT_NAME.isEmpty() ? "" : "<span class=\"chip\">" + escape(TENANT_NAME) + "</span>")
        + "</h1>");
    out.println("<p class=\"sub\">One WebLogic operator on the Control Plane Cluster. "
        + escape(cacheBlurb(cache)) + "</p>");

    out.println("<div class=\"card\">");
    out.println("<dl>");
    if (!TENANT_NAME.isEmpty()) {
      row(out, "Tenant cluster", "<code>" + escape(TENANT_NAME) + "</code>");
    }
    row(out, "Domain UID", escape(domainUID));
    if (!HOST_NAMESPACE.isEmpty()) {
      row(out, "Backing namespace", "<code>" + escape(HOST_NAMESPACE) + "</code>");
    }
    if (!NODE_NAME.isEmpty()) {
      row(out, "Shared node", "<code>" + escape(NODE_NAME) + "</code>");
    }
    row(out, "Serving instance", escape(serverName));
    row(out, "Cache endpoint", cache.isReady()
        ? "<code>" + escape(cache.endpoint()) + ":" + cache.port() + "</code>"
        : "<em>not published yet</em>");
    row(out, "In-transit encryption", cache.isReady() ? (cache.tls() ? "TLS" : "disabled") : "&mdash;");
    row(out, cache.isElastiCache() ? "ReplicationGroup state" : "Cache state",
        "<code>" + escape(cache.state()) + "</code>");
    out.println("</dl></div>");

    if (result.status == CacheResult.Status.CONNECTED) {
      out.println("<div class=\"card\">");
      out.println("<div class=\"count\">" + result.hits + "</div>");
      out.println("<p class=\"sub\" style=\"margin:.5rem 0 0\">requests served, counted in ElastiCache</p>");
      out.println("<ol>");
      for (Object entry : result.history) {
        out.println("<li>" + escape(String.valueOf(entry)) + "</li>");
      }
      out.println("</ol>");
      out.println("<p style=\"margin-top:1.25rem\"><a class=\"btn\" href=\"" + escape(requestUri)
          + "?reset=1\">Reset counter</a></p>");
      out.println("</div>");
    } else if (result.status == CacheResult.Status.PENDING) {
      out.println("<div class=\"card warn\"><strong>Cache is still provisioning.</strong>");
      out.println("<p class=\"sub\" style=\"margin:.5rem 0 0\">" + pendingBlurb(cache)
          + "</p></div>");
    } else {
      out.println("<div class=\"card warn\"><strong>Could not reach the cache.</strong>");
      out.println("<p class=\"sub\" style=\"margin:.5rem 0 0\">" + escape(result.error) + "</p>");
      out.println("<p class=\"sub\">Check the ElastiCache security group allows 6379 from the "
          + "EKS node security group, and that in-transit encryption matches the "
          + "<code>tls</code> value in the endpoint ConfigMap.</p></div>");
    }

    out.println("</div></body></html>");
  }

  /** Describes the cache the way this tenant actually got it. */
  private static String cacheBlurb(CacheConfig cache) {
    if (cache.isElastiCache()) {
      return "One ElastiCache replication group requested from inside the tenant through ACK.";
    }
    if ("in-tenant".equals(cache.backend())) {
      return "Redis running inside the tenant cluster, reached by ClusterIP.";
    }
    return "Cache details are published into a ConfigMap the domain mounts.";
  }

  private static String pendingBlurb(CacheConfig cache) {
    if (cache.isElastiCache()) {
      return "The tenant created an ACK <code>ReplicationGroup</code>. Once AWS reports an "
          + "endpoint, the publisher writes it into the mounted ConfigMap and this page starts "
          + "counting &mdash; no domain restart.";
    }
    return "The publisher is waiting for the in-tenant Redis Service to report a ClusterIP. "
        + "Once it does, it writes the address into the mounted ConfigMap and this page starts "
        + "counting &mdash; no domain restart.";
  }

  private static void row(PrintWriter out, String label, String value) {
    out.println("<dt>" + label + "</dt><dd>" + value + "</dd>");
  }

  private static String env(String name, String fallback) {
    String value = System.getenv(name);
    return value == null || value.isEmpty() ? fallback : value;
  }

  private static String escape(String raw) {
    if (raw == null) {
      return "";
    }
    return raw.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
  }

  private static final class CacheResult {
    enum Status { CONNECTED, PENDING, FAILED }

    final Status status;
    final long hits;
    final List<Object> history;
    final String error;

    private CacheResult(Status status, long hits, List<Object> history, String error) {
      this.status = status;
      this.hits = hits;
      this.history = history;
      this.error = error;
    }

    static CacheResult connected(long hits, List<Object> history) {
      return new CacheResult(Status.CONNECTED, hits, history, null);
    }

    static CacheResult pending() {
      return new CacheResult(Status.PENDING, 0L, null, null);
    }

    static CacheResult failed(String error) {
      return new CacheResult(Status.FAILED, 0L, null, error);
    }
  }
}
