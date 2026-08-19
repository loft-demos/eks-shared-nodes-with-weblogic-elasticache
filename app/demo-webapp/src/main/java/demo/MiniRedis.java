package demo;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/**
 * A deliberately tiny RESP (Redis serialization protocol) client.
 *
 * The demo WAR ships no Redis driver on purpose: adding Jedis or Lettuce would pull
 * slf4j, gson, and commons-pool into WEB-INF/lib, which is exactly the kind of
 * classloader argument nobody wants to have during a live WebLogic demo. ElastiCache
 * speaks RESP2 by default, and the handful of commands this demo needs fit in one file.
 */
final class MiniRedis implements Closeable {

  private final Socket socket;
  private final BufferedInputStream in;
  private final OutputStream out;

  MiniRedis(String host, int port, boolean tls, int timeoutMillis) throws IOException {
    Socket s;
    if (tls) {
      SSLSocket ssl = (SSLSocket) SSLSocketFactory.getDefault().createSocket();
      // ElastiCache in-transit encryption presents a certificate for the endpoint
      // hostname signed by a public Amazon CA, so verify it rather than trusting blindly.
      SSLParameters params = ssl.getSSLParameters();
      params.setEndpointIdentificationAlgorithm("HTTPS");
      ssl.setSSLParameters(params);
      s = ssl;
    } else {
      s = new Socket();
    }
    s.connect(new InetSocketAddress(host, port), timeoutMillis);
    s.setSoTimeout(timeoutMillis);
    s.setTcpNoDelay(true);
    this.socket = s;
    this.in = new BufferedInputStream(s.getInputStream());
    this.out = s.getOutputStream();
  }

  Object call(String... args) throws IOException {
    writeCommand(args);
    return readReply();
  }

  long callLong(String... args) throws IOException {
    Object reply = call(args);
    return reply instanceof Long ? (Long) reply : -1L;
  }

  @SuppressWarnings("unchecked")
  List<Object> callList(String... args) throws IOException {
    Object reply = call(args);
    return reply instanceof List ? (List<Object>) reply : new ArrayList<Object>();
  }

  private void writeCommand(String... args) throws IOException {
    ByteArrayOutputStream buffer = new ByteArrayOutputStream();
    buffer.write(('*' + Integer.toString(args.length) + "\r\n").getBytes(StandardCharsets.UTF_8));
    for (String arg : args) {
      byte[] encoded = arg.getBytes(StandardCharsets.UTF_8);
      buffer.write(('$' + Integer.toString(encoded.length) + "\r\n").getBytes(StandardCharsets.UTF_8));
      buffer.write(encoded);
      buffer.write("\r\n".getBytes(StandardCharsets.UTF_8));
    }
    out.write(buffer.toByteArray());
    out.flush();
  }

  private Object readReply() throws IOException {
    int marker = in.read();
    if (marker < 0) {
      throw new IOException("cache closed the connection");
    }
    String line = readLine();
    switch (marker) {
      case '+':
        return line;
      case '-':
        throw new IOException("cache returned an error: " + line);
      case ':':
        return Long.valueOf(line);
      case '$':
        return readBulk(Integer.parseInt(line));
      case '*':
        return readArray(Integer.parseInt(line));
      default:
        throw new IOException("unexpected RESP marker: " + (char) marker);
    }
  }

  private Object readBulk(int length) throws IOException {
    if (length < 0) {
      return null;
    }
    byte[] payload = new byte[length];
    int read = 0;
    while (read < length) {
      int n = in.read(payload, read, length - read);
      if (n < 0) {
        throw new IOException("truncated bulk reply from cache");
      }
      read += n;
    }
    readExactly(2); // trailing CRLF
    return new String(payload, StandardCharsets.UTF_8);
  }

  private Object readArray(int count) throws IOException {
    if (count < 0) {
      return null;
    }
    List<Object> items = new ArrayList<Object>(count);
    for (int i = 0; i < count; i++) {
      items.add(readReply());
    }
    return items;
  }

  private String readLine() throws IOException {
    ByteArrayOutputStream buffer = new ByteArrayOutputStream();
    int previous = -1;
    while (true) {
      int current = in.read();
      if (current < 0) {
        throw new IOException("cache closed the connection mid-reply");
      }
      if (previous == '\r' && current == '\n') {
        byte[] bytes = buffer.toByteArray();
        return new String(bytes, 0, bytes.length - 1, StandardCharsets.UTF_8);
      }
      buffer.write(current);
      previous = current;
    }
  }

  private void readExactly(int count) throws IOException {
    for (int i = 0; i < count; i++) {
      if (in.read() < 0) {
        throw new IOException("cache closed the connection mid-reply");
      }
    }
  }

  @Override
  public void close() {
    closeQuietly(in);
    closeQuietly(out);
    try {
      socket.close();
    } catch (IOException ignored) {
      // nothing useful to do while tearing down a demo connection
    }
  }

  private static void closeQuietly(Closeable closeable) {
    try {
      closeable.close();
    } catch (IOException ignored) {
      // nothing useful to do while tearing down a demo connection
    }
  }
}
