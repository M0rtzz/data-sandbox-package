#!/usr/bin/env python3
"""Dev-stack WebSocket/TCP tunnel for the data-sandbox developer environment.

Kuscia 0.13.0b0 gateway envoy has no `upgrade_configs`, so WebSocket upgrades
through it are rejected (403 `$upgrade_failed$`). Sandbox Jupyter pods are only
reachable from inside the kuscia container (its k3s network, 10.88.0.x).

This tunnel runs inside the kuscia container: it accepts the secretpad WebSocket
bridge's connection, resolves the sandbox headless service
(`ds-sbx-<id>-task-server-0-web.dev-zgz.svc`) to a pod address via
`kubectl get endpoints`, opens a TCP connection to the pod, forwards the original
upgrade request bytes verbatim, then relays raw bytes both ways. The real WebSocket
endpoints (JDK HttpClient client <-> Jupyter server) do all WS framing, so the
tunnel is a transparent TCP pipe.

Dev-only: managed by data-sandbox-package/develop.sh (ensure_ws_tunnel); it is NOT
part of the deployment system.
"""

import logging
import os
import re
import socket
import socketserver
import subprocess
import sys
import threading
import time

HOST_RE = re.compile(r"^([a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+)\.svc$", re.IGNORECASE)

LOG_PATH = os.environ.get("WS_TUNNEL_LOG", "/opt/ws-tunnel.log")
LISTEN_HOST = os.environ.get("WS_TUNNEL_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("WS_TUNNEL_PORT", "10082"))
RESOLVE_TTL_SECONDS = 10.0
HEADER_READ_TIMEOUT = 10.0
CONNECT_TIMEOUT = 5.0
MAX_HEADER_BYTES = 16 * 1024

logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("ws-tunnel")

# svc key ("<ns>/<service>") -> (host:port, resolved_at_monotonic)
_resolve_cache = {}


def resolve_target(service, namespace):
    """Resolve a headless service to pod ip:port via kubectl endpoints (cached)."""
    key = "{}/{}".format(namespace, service)
    now = time.monotonic()
    cached = _resolve_cache.get(key)
    if cached and now - cached[1] < RESOLVE_TTL_SECONDS:
        return cached[0]
    out = subprocess.check_output(
        [
            "kubectl",
            "get",
            "endpoints",
            service,
            "-n",
            namespace,
            "-o",
            "jsonpath={.subsets[0].addresses[0].ip}:{.subsets[0].ports[0].port}",
        ],
        text=True,
        timeout=8,
    ).strip()
    if not out:
        raise RuntimeError("no endpoints for {}/{}".format(service, namespace))
    _resolve_cache[key] = (out, now)
    return out


def write_502(conn, reason):
    body = "Bad Gateway: {}".format(reason).encode()
    conn.sendall(
        b"HTTP/1.1 502 Bad Gateway\r\n"
        b"Content-Type: text/plain\r\n"
        b"Connection: close\r\n"
        + "Content-Length: {}\r\n\r\n".format(len(body)).encode()
        + body
    )


def splice(src, dst):
    """Copy bytes one way until EOF/error, then shut down the destination's write side."""
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class TunnelHandler(socketserver.StreamRequestHandler):
    def handle(self):
        conn = self.request
        conn.settimeout(HEADER_READ_TIMEOUT)
        up = None
        try:
            head = bytearray()
            while b"\r\n\r\n" not in head:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                head += chunk
                if len(head) > MAX_HEADER_BYTES:
                    write_502(conn, "request headers too large")
                    return

            raw = bytes(head)
            text = raw.decode("utf-8", "replace")
            host = None
            for line in text.split("\r\n"):
                if line.lower().startswith("host:"):
                    host = line.split(":", 1)[1].strip()
                    break
            if not host:
                write_502(conn, "missing Host header")
                return
            # strip an explicit :port (the bridge sends no port; be lenient anyway)
            rsplit = host.rsplit(":", 1)
            if len(rsplit) == 2 and rsplit[1].isdigit():
                host = rsplit[0]
            match = HOST_RE.match(host.rstrip("."))
            if not match:
                write_502(conn, "invalid Host: {}".format(host))
                return
            labels = match.group(1).split(".")
            service = labels[0]
            namespace = labels[1] if len(labels) > 1 else "dev-zgz"

            key = "{}/{}".format(namespace, service)
            target = resolve_target(service, namespace)
            try:
                ip, _, port = target.rpartition(":")
                up = socket.create_connection((ip, int(port)), timeout=CONNECT_TIMEOUT)
            except OSError:
                # pod may have been rescheduled; drop the cache entry and retry once
                _resolve_cache.pop(key, None)
                target = resolve_target(service, namespace)
                ip, _, port = target.rpartition(":")
                up = socket.create_connection((ip, int(port)), timeout=CONNECT_TIMEOUT)

            # relay phase: block freely, no read timeouts (WS frames may be sparse)
            conn.settimeout(None)
            up.settimeout(None)
            for sock in (conn, up):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

            # forward the original upgrade request verbatim, then splice both ways
            up.sendall(raw)
            log.info("relay established %s -> %s", host, target)
            t1 = threading.Thread(target=splice, args=(conn, up), daemon=True)
            t2 = threading.Thread(target=splice, args=(up, conn), daemon=True)
            t1.start()
            t2.start()
            t1.join()
            t2.join()
        except Exception as exc:  # noqa: BLE001 - never kill the listener on one bad conn
            log.warning("connection failed: %s", exc)
            try:
                write_502(conn, str(exc))
            except OSError:
                pass
        finally:
            if up is not None:
                try:
                    up.close()
                except OSError:
                    pass
            try:
                conn.close()
            except OSError:
                pass


class TunnelServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    try:
        server = TunnelServer((LISTEN_HOST, LISTEN_PORT), TunnelHandler)
    except OSError as exc:
        log.error("cannot bind %s:%s: %s", LISTEN_HOST, LISTEN_PORT, exc)
        sys.exit(1)
    log.info("ws-tunnel listening on %s:%s", LISTEN_HOST, LISTEN_PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
