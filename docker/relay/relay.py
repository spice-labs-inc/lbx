#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# llm-in-a-box-relay — the single door through the network wall.
#
# A stdlib-only, unprivileged CONNECT proxy. Policy is hostname-based:
#   - deny-by-default in enforce/locked modes; open mode allows + logs all;
#   - deny beats allow (block list first);
#   - no IP-literal CONNECT targets (shared CDN edges make IP allowlists
#     meaningless);
#   - deny-by-resolution: if the CONNECT host resolves to ANY address that
#     is not public (private, loopback, link-local, multicast, unspecified,
#     reserved, site-local IPv6, anything Python does not mark global, and
#     always 100.64.0.0/10, 192.0.0.0/24 and fec0::/10), deny: this is how
#     the box is kept off RFC1918, the host LAN, tailnet addresses and
#     169.254.169.254 even when a domain is allowlisted;
#   - a failed lookup is not a refusal of an address: it is denied as
#     resolve-failed:<EAI name> (bad-name for a name that cannot be
#     encoded, the errno name for a system error) with 503, so clients may
#     retry; the relay itself looks a name up once per request (the
#     resolver already retries within its own timeout);
#   - TLS SNI must equal the CONNECT host (no TLS termination; the
#     ClientHello is parsed from the stream, its first record read whole
#     within 5 seconds). Unparseable/non-TLS CONNECT
#     streams are denied (fail closed; ECH fails closed);
#   - plain-HTTP absolute-form requests (GET http://host/...) are supported
#     so apt works through the door;
#   - bytes that arrive with the request head (a ClientHello sent in the
#     same packet as CONNECT, the start of a plain-HTTP request body) are
#     forwarded upstream first, in order; a plain-HTTP body is forwarded
#     by Content-Length, and nothing past it;
#   - request timeout: a client that has not sent a complete request head
#     within request_timeout seconds of connecting (default 30) gets 408
#     and request-timeout, and its connection is closed;
#   - idle timeout: a tunnel with no byte in either direction for
#     idle_timeout_seconds (policy; default 300) is closed, and a
#     plain-HTTP exchange is dropped when the client (sending its body)
#     or the upstream (answering) sends nothing for that long;
#   - at most MAX_CONCURRENCY (64) client connections at a time, each
#     holding its slot until it closes; past that, 503 and
#     too-many-connections;
#   - every verdict is logged (ALLOW/DENY, host, reason) to the deny log.
#     A reason is one token (ip-literal, blocked, not-allowed, bad-target,
#     unsupported-request, too-many-connections, request-timeout,
#     resolve-failed:<EAI name or errno name>,
#     resolve-failed:bad-name, resolve-failed:no-address,
#     resolves-to-private followed by addr=<address>,
#     connect-failed:<errno name>, sni-mismatch followed by sni=<name>).
#     The sni value is text the client chose: control characters become
#     "?", but it may contain spaces.
#
# Inputs (env): LLMBOX_POLICY (JSON: {"mode": "open|enforce|locked",
# "allow": [...], "block": [...], optional "idle_timeout_seconds": n}),
# LLMBOX_DENY_LOG (log file path),
# LLMBOX_PORT (default 3128), LLMBOX_REQUEST_TIMEOUT (whole seconds from
# 1 to 3600, default 30; lbx never sets it, the relay's checks do).
# Binds 0.0.0.0 — the container network is the security boundary
# (--internal for sessions; 127.0.0.1 publishes in tests).
# ---------------------------------------------------------------------------
import errno
import ipaddress
import json
import os
import re
import select
import socket
import socketserver
import threading
import time
from urllib.parse import urlparse

POLICY_PATH = os.environ.get("LLMBOX_POLICY", "/policy.json")
LOG_PATH = os.environ.get("LLMBOX_DENY_LOG", "/deny.log")
BIND = ("0.0.0.0", int(os.environ.get("LLMBOX_PORT", "3128")))
MAX_CONCURRENCY = 64
CONNECT_TIMEOUT = 10
SNI_WAIT = 5
# Seconds a tunnel may carry no byte in either direction (or a plain-HTTP
# exchange may make no progress: no body byte from the client, no answer
# byte from the upstream) before the relay ends it. The policy's
# idle_timeout_seconds overrides the default; the relay accepts
# IDLE_TIMEOUT_MIN..IDLE_TIMEOUT_MAX (lbx allows a narrower product range)
# and refuses to start on anything else.
IDLE_TIMEOUT = 300
IDLE_TIMEOUT_MIN = 1
IDLE_TIMEOUT_MAX = 3600
idle_timeout = IDLE_TIMEOUT
# Seconds a client has, from connecting, to send a complete request head.
# The limit ends with the head; after it the idle timeout applies.
REQUEST_TIMEOUT = 30
REQUEST_TIMEOUT_MIN = 1
REQUEST_TIMEOUT_MAX = 3600
request_timeout = REQUEST_TIMEOUT

policy = {"mode": "open", "allow": [], "block": []}
_log_lock = threading.Lock()


def log_line(verdict, src, detail):
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    detail = re.sub(r"[\x00-\x1f\x7f]", "?", detail)
    try:
        with _log_lock:
            with open(LOG_PATH, "a") as f:
                f.write("%s %s %s %s\n" % (ts, verdict, src, detail))
    except OSError:
        pass  # a dead log file must never take down the door


def load_policy():
    """Read the policy; an invalid idle_timeout_seconds stops the relay."""
    global policy, idle_timeout
    with open(POLICY_PATH) as f:
        policy = json.load(f)
    value = policy.get("idle_timeout_seconds", IDLE_TIMEOUT)
    # bool is a subclass of int in Python, so it is excluded explicitly.
    if (type(value) is not int
            or not IDLE_TIMEOUT_MIN <= value <= IDLE_TIMEOUT_MAX):
        raise SystemExit(
            "invalid idle_timeout_seconds in policy: %r (want a whole number"
            " from %d to %d)" % (value, IDLE_TIMEOUT_MIN, IDLE_TIMEOUT_MAX))
    idle_timeout = value


def load_request_timeout():
    """Read LLMBOX_REQUEST_TIMEOUT; an invalid value stops the relay."""
    global request_timeout
    raw = os.environ.get("LLMBOX_REQUEST_TIMEOUT")
    if raw is None:
        return
    if (not re.fullmatch(r"[0-9]+", raw)
            or not REQUEST_TIMEOUT_MIN <= int(raw) <= REQUEST_TIMEOUT_MAX):
        raise SystemExit(
            "invalid LLMBOX_REQUEST_TIMEOUT: %r (want a whole number from %d"
            " to %d)" % (raw, REQUEST_TIMEOUT_MIN, REQUEST_TIMEOUT_MAX))
    request_timeout = int(raw)


def host_matches(host, patterns):
    host = host.lower().rstrip(".")
    for p in patterns or []:
        p = str(p).lower().rstrip(".")
        if p.startswith("*."):
            if host == p[2:] or host.endswith(p[1:]):
                return True
        elif host == p:
            return True
    return False


# Always refused, whatever the running Python's ipaddress tables say (they
# have changed between patch releases): the shared address space, which
# carries carrier-grade network address translation and every tailnet node
# address; the Internet Engineering Task Force protocol assignments block,
# whose anycast members Python counts as global; and deprecated site-local
# IPv6, which Python counts as global.
ALWAYS_REFUSED = (
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("192.0.0.0/24"),
    ipaddress.ip_network("fec0::/10"),
)

# EAI_* error numbers to their names, for one-token lookup-failure reasons
# that read the same on glibc and musl.
_EAI_NAMES = {}
for _name in dir(socket):
    if _name.startswith("EAI_"):
        _EAI_NAMES.setdefault(getattr(socket, _name), _name)


def ip_disallowed(addr):
    """True when addr is not a public address the relay may connect to."""
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return True
    if ip.version == 6 and ip.ipv4_mapped is not None:
        return ip_disallowed(str(ip.ipv4_mapped))
    if any(ip in net for net in ALWAYS_REFUSED if net.version == ip.version):
        return True
    return (ip.is_private or ip.is_loopback or ip.is_link_local
            or ip.is_multicast or ip.is_unspecified or ip.is_reserved
            or getattr(ip, "is_site_local", False) or not ip.is_global)


def resolve_public(host):
    """Resolve host once and judge every address.

    Returns (addrs, reason, refused): the public addresses and None, None
    when every address may be used; otherwise no addresses, the deny
    reason, and the first refused address (None for a failed lookup).
    """
    try:
        infos = socket.getaddrinfo(host, None, socket.AF_UNSPEC, socket.SOCK_STREAM)
    except socket.gaierror as e:
        return [], "resolve-failed:%s" % _EAI_NAMES.get(e.errno, e.errno), None
    except UnicodeError:
        # A name the internationalized domain name codec rejects (an empty
        # label, a label over 63 characters) never reaches the resolver.
        return [], "resolve-failed:bad-name", None
    except OSError as e:
        # EAI_SYSTEM surfaces as a plain OSError carrying the system error.
        return [], "resolve-failed:%s" % error_name(e), None
    addrs = []
    for info in infos:
        addr = info[4][0]
        if ip_disallowed(addr):
            return [], "resolves-to-private", addr
        addrs.append(addr)
    if not addrs:
        return [], "resolve-failed:no-address", None
    return addrs, None, None


def error_name(err):
    """One-token name of a connect error: its errno name when it has one."""
    name = errno.errorcode.get(getattr(err, "errno", None))
    if name:
        return name
    if isinstance(err, socket.timeout):
        return "ETIMEDOUT"
    return type(err).__name__


def is_ip_literal(host):
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        return False


def allowed(host):
    """(ok, reason) for a CONNECT/HTTP target hostname."""
    if is_ip_literal(host):
        return False, "ip-literal"
    if host_matches(host, policy.get("block")):
        return False, "blocked"
    if policy.get("mode") == "open":
        return True, "open"
    if host_matches(host, policy.get("allow")):
        return True, "allowed"
    return False, "not-allowed"


def parse_sni(data):
    """SNI hostname from the start of a TLS ClientHello, or None."""
    try:
        if len(data) < 43 or data[0] != 0x16 or data[1] != 0x03 or data[5] != 0x01:
            return None
        i = 9          # skip record header + handshake type/len, at version
        i += 2 + 32    # version + random
        sid_len = data[i]
        i += 1 + sid_len
        cs_len = int.from_bytes(data[i:i + 2], "big")
        i += 2 + cs_len
        comp_len = data[i]
        i += 1 + comp_len
        ext_total = int.from_bytes(data[i:i + 2], "big")
        i += 2
        end = i + ext_total
        while i + 4 <= end:
            etype = int.from_bytes(data[i:i + 2], "big")
            elen = int.from_bytes(data[i + 2:i + 4], "big")
            i += 4
            if etype == 0x0000 and i + 5 <= end:
                ntype = data[i + 2]
                nlen = int.from_bytes(data[i + 3:i + 5], "big")
                return data[i + 5:i + 5 + nlen].decode("ascii", "ignore")
            i += elen
        return None
    except (IndexError, TypeError):
        return None


def pipe(a, b, first=b""):
    """Copy bytes both ways until both directions end or the tunnel is idle.

    first holds bytes already read from a (past the request head); they
    are sent to b before anything else read from a.

    Each direction has its own thread, so both flow at the same time: a
    peer that writes before it reads cannot stall the other direction.
    One timer covers the whole tunnel: it restarts on any byte received or
    sent in either direction, and after idle_timeout seconds with no byte
    either way both sockets are shut down and the tunnel ends. A server
    that streams to a silent client (or a client that uploads to a silent
    server) therefore keeps the tunnel open. A direction that reaches end
    of stream is half-closed toward the other side, and the other
    direction keeps flowing.
    A failed send ends the whole tunnel, not just one direction: the
    peer that should have received the bytes is gone, so the rest of the
    exchange cannot complete.
    """
    a.setblocking(False)
    b.setblocking(False)
    last = [time.monotonic()]
    done = threading.Event()
    # Wake up at least once a second to look at the shared timer. select()
    # is enough here: the connection cap keeps the number of sockets small.
    poll = min(1.0, idle_timeout)

    def idle():
        return time.monotonic() - last[0] >= idle_timeout

    def end_tunnel():
        done.set()
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def send_all(dst, data):
        """Send data to dst without blocking the other direction."""
        view = memoryview(data)
        while view:
            if done.is_set():
                return False
            _, writable, _ = select.select([], [dst], [], poll)
            if not writable:
                if idle():
                    end_tunnel()
                    return False
                continue
            try:
                sent = dst.send(view)
            except (BlockingIOError, InterruptedError):
                continue
            except OSError:
                end_tunnel()
                return False
            view = view[sent:]
            last[0] = time.monotonic()
        return True

    def copy(src, dst, pending=b""):
        if pending and not send_all(dst, pending):
            return
        while not done.is_set():
            readable, _, _ = select.select([src], [], [], poll)
            if not readable:
                if idle():
                    end_tunnel()
                    return
                continue
            try:
                data = src.recv(65536)
            except (BlockingIOError, InterruptedError):
                continue
            except OSError:
                data = b""
            if not data:
                try:
                    dst.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                return
            last[0] = time.monotonic()
            if not send_all(dst, data):
                return

    t1 = threading.Thread(target=copy, args=(a, b, first), daemon=True)
    t2 = threading.Thread(target=copy, args=(b, a), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            self._handle()
        except OSError:
            pass

    def _read_head(self):
        """Read until the end of the request head, within request_timeout.

        Returns everything read (the head and any bytes after it), or None
        when the client closed first or the time ran out; in the second
        case the relay has answered 408 and logged request-timeout.
        """
        deadline = time.monotonic() + request_timeout
        buf = b""
        while b"\r\n\r\n" not in buf and len(buf) < 65536:
            left = deadline - time.monotonic()
            try:
                if left <= 0:
                    raise socket.timeout()
                self.connection.settimeout(left)
                chunk = self.connection.recv(4096)
            except socket.timeout:
                self.connection.settimeout(None)
                self.deny("-", "request-timeout", 408)
                return None
            if not chunk:
                return None
            buf += chunk
        self.connection.settimeout(None)
        return buf

    def _handle(self):
        buf = self._read_head()
        if buf is None:
            return
        head, _, rest = buf.partition(b"\r\n\r\n")
        lines = head.split(b"\r\n")
        if not lines:
            return
        parts = lines[0].decode("latin-1").split()
        if len(parts) < 3:
            return
        method, target = parts[0].upper(), parts[1]
        headers = {}
        for line in lines[1:]:
            if b":" in line:
                k, _, v = line.partition(b":")
                headers[k.decode("latin-1").strip().lower()] = v.decode("latin-1").strip()
        if method == "CONNECT":
            self.do_connect(target, rest)
        elif target.startswith(("http://", "https://")):
            self.do_plain(method, target, headers, rest)
        else:
            self.deny(target, "unsupported-request")

    PHRASES = {403: "Forbidden", 408: "Request Timeout", 503: "Service Unavailable"}

    def deny(self, host, reason, code=403):
        """Log a DENY line and answer with code: 403 for a refusal, 503 for
        a failed lookup (the request may succeed if retried), 408 for a
        request head that did not arrive in time."""
        log_line("DENY", self.client_address[0], "host=%s reason=%s" % (host, reason))
        try:
            self.wfile.write(
                ("HTTP/1.1 %d %s\r\n%sContent-Length: 0\r\n\r\n"
                 % (code, self.PHRASES.get(code, "Error"),
                    "Connection: close\r\n" if code == 408 else "")).encode()
            )
        except OSError:
            pass

    def _connect_upstream(self, host, port):
        ok, why = allowed(host)
        if not ok:
            self.deny(host, why)
            return None
        addrs, why, refused = resolve_public(host)
        if refused is not None:
            self.deny(host, "%s addr=%s" % (why, refused))
            return None
        if why is not None:
            # A lookup failure says nothing about the destination; 503 tells
            # clients the request may succeed if retried.
            self.deny(host, why, 503)
            return None
        last_err = None
        for addr in addrs:
            try:
                return socket.create_connection((addr, port), CONNECT_TIMEOUT)
            except OSError as e:
                last_err = e
        self.deny(host, "connect-failed:%s" % (error_name(last_err) if last_err else "none"))
        return None

    def do_connect(self, target, leftover):
        host, _, port_s = target.rpartition(":")
        if not host or not port_s.isdigit():
            self.deny(target, "bad-target")
            return
        port = int(port_s)
        upstream = self._connect_upstream(host, port)
        if upstream is None:
            return
        try:
            self.wfile.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
            self.wfile.flush()
        except OSError:
            upstream.close()
            return
        # SNI must equal the CONNECT host. Everything read to find it is
        # forwarded upstream first once the tunnel is allowed.
        hello = self._read_hello(leftover)
        sni = parse_sni(hello)
        if sni is None or sni.lower().rstrip(".") != host.lower().rstrip("."):
            log_line("DENY", self.client_address[0],
                     "host=%s reason=sni-mismatch sni=%s" % (host, sni or "-"))
            upstream.close()
            return
        log_line("ALLOW", self.client_address[0], "host=%s:%d sni=%s" % (host, port, sni))
        pipe(self.connection, upstream, hello)
        upstream.close()

    def _read_hello(self, data):
        """Read until data holds the first TLS record whole, for up to
        SNI_WAIT seconds, starting from the bytes that came with the
        request. Stops early when the stream cannot be a TLS handshake.
        Returns everything read, which may run past the record."""
        deadline = time.monotonic() + SNI_WAIT
        while len(data) < 5 or (
                data[0] == 0x16 and len(data) < 5 + int.from_bytes(data[3:5], "big")):
            left = deadline - time.monotonic()
            if left <= 0:
                break
            self.connection.settimeout(left)
            try:
                chunk = self.connection.recv(65536)
            except socket.timeout:
                break
            if not chunk:
                break
            data += chunk
        self.connection.settimeout(None)
        return data

    def do_plain(self, method, target, headers, rest):
        parsed = urlparse(target)
        host = parsed.hostname or ""
        port = parsed.port or 80
        upstream = self._connect_upstream(host, port)
        if upstream is None:
            return
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        fwd_headers = {}
        for k, v in headers.items():
            if k in ("proxy-connection", "connection"):
                continue
            fwd_headers[k] = v
        fwd_headers["host"] = host if ":" not in host or port == 80 else "%s:%d" % (host, port)
        fwd_headers["connection"] = "close"
        head = "%s %s HTTP/1.0\r\n" % (method, path)
        head += "".join("%s: %s\r\n" % (k, v) for k, v in fwd_headers.items())
        head += "\r\n"
        try:
            upstream.sendall(head.encode("latin-1"))
            upstream.settimeout(idle_timeout)
            self.connection.settimeout(idle_timeout)
            self._forward_body(upstream, headers, rest)
            while True:
                data = upstream.recv(65536)
                if not data:
                    break
                self.connection.sendall(data)
            log_line("ALLOW", self.client_address[0], "host=%s:%d method=%s" % (host, port, method))
        except OSError:
            pass
        finally:
            upstream.close()

    def _forward_body(self, upstream, headers, rest):
        """Send the request body upstream: exactly Content-Length bytes,
        those read with the head (rest) first, then the rest from the
        client. Bytes past the body are not forwarded: the upstream gets
        one request and has been told to close. One select() watches the
        upstream the whole time, so an upstream that answers before it has
        the whole body (401, 413; it cannot send 100 Continue to the
        HTTP/1.0 request it got) ends the body at once and its answer is
        relayed, whether the relay was waiting on the client or on the
        upstream. No progress for idle_timeout seconds raises
        socket.timeout. A body framed by Transfer-Encoding, or a
        Content-Length that is not a plain number of at most 18 digits,
        is not forwarded at all."""
        length = headers.get("content-length", "")
        if "transfer-encoding" in headers or not re.fullmatch(r"[0-9]{1,18}", length):
            return
        remaining = int(length)
        pending = rest[:remaining]
        remaining -= len(pending)
        while pending or remaining > 0:
            readers = [upstream]
            if not pending:
                readers.append(self.connection)
            readable, writable, _ = select.select(
                readers, [upstream] if pending else [], [], idle_timeout)
            if not readable and not writable:
                raise socket.timeout()
            if upstream in readable:
                return
            if self.connection in readable:
                chunk = self.connection.recv(65536)
                if not chunk:
                    return
                pending = chunk[:remaining]
                remaining -= len(pending)
            elif writable:
                try:
                    sent = upstream.send(pending)
                except OSError:
                    return
                pending = pending[sent:]


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    # A listen backlog above the cap, so connections past it reach
    # process_request and get their 503 instead of waiting for the kernel
    # to retry the connection request (the socketserver default is 5).
    request_queue_size = 128

    def __init__(self, *args, **kwargs):
        self._sem = threading.BoundedSemaphore(MAX_CONCURRENCY)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        """Take a slot for the connection's whole life, or refuse it.

        Past MAX_CONCURRENCY live connections the relay answers 503
        immediately, logs too-many-connections (the request is never
        read, so the host is "-"), and closes the connection.
        """
        if not self._sem.acquire(blocking=False):
            log_line("DENY", client_address[0], "host=- reason=too-many-connections")
            try:
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n")
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._sem.release()
            raise

    def process_request_thread(self, request, client_address):
        # Runs in the connection's own thread; the slot is freed only when
        # the handler has finished and the connection is closed.
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._sem.release()


def main():
    load_policy()
    load_request_timeout()
    server = Server(BIND, Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
