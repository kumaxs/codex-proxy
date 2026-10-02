#!/usr/bin/env python3
"""Process-scoped Space Page transport. No app bundle changes or token logging.

Normal launches use a private CDP pipe (no debug TCP listener). Attach mode is
only for a pre-existing, verified loopback debug session during deployment.
"""
import argparse
import fcntl
import json
import os
import pathlib
import plistlib
import queue
import re
import signal
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import websocket

BUILD = "12776"  # ChatGPT 26.930.21537: validated renderer transport call site.
SCRIPT_PATTERN = r"/assets/app-initial-60d038a052d7\.js$"
LINE, COLUMN = 1602, 143900
BINDING = "__codexPageProxySend"
MAX_SEND, MAX_RECEIVE = 1024 * 1024, 16 * 1024 * 1024
ADAPTER = r'''(() => {
if (window.__codexPageProxy) return;
const callbacks = new Map(); let next = 0;
const emit = value => window.__codexPageProxySend(JSON.stringify(value));
window.__codexPageProxyDeliver = (id, event) => {
 const cb = callbacks.get(id); if (!cb) return;
 try { cb(event); } finally { if (event.type === 'close') callbacks.delete(id); }
};
window.__codexPageProxy = {connect: async (params, callback) => {
 const id = String(++next); let closed = false;
 callbacks.set(id, callback); emit({action:'connect',id,params});
 const close = () => {if(closed)return; closed=true; callbacks.delete(id); emit({action:'close',id});};
 return {send:data=>{if(closed)throw Error('Page connection closed'); emit({action:'send',id,data});},
         close, [Symbol.dispose]:close};
}};
})()'''


def endpoint(params):
    """Only the same official Page hosts accepted by the validated desktop build."""
    u = urllib.parse.urlsplit(params["endpoint"])
    host = u.hostname or ""
    broker = host == "chatgpt.com" and re.fullmatch(
        r"/backend-api/pages/realtime-broker/u(?:0|[1-9][0-9]*)/ws", u.path)
    gateway = re.fullmatch(r"pages-realtime\.gateway\.[A-Za-z0-9.-]+\.api\.openai\.(com|org)", host) and u.path == "/ws"
    if not (broker or gateway) or u.scheme not in ("https", "wss") or u.port not in (None, 443) or u.username is not None or u.password is not None or u.fragment:
        raise ValueError("Unsupported Page endpoint")
    page = params.get("pageId", "")
    if not re.fullmatch(r"page_[A-Za-z0-9_-]{1,128}", page):
        raise ValueError("Invalid Page ID")
    token = params.get("token", "")
    grant = params.get("authorizationGrant")
    if not isinstance(token, str) or not 1 <= len(token) <= 32768:
        raise ValueError("Invalid Page token")
    if grant is not None and (not isinstance(grant, str) or len(grant) > 32768):
        raise ValueError("Invalid authorization grant")
    query = [(k, v) for k, v in urllib.parse.parse_qsl(u.query) if k not in ("token", "authorization_grant")]
    query.append(("token", token))
    if grant is not None:
        query.append(("authorization_grant", grant))
    return urllib.parse.urlunsplit(("wss", u.netloc, u.path, urllib.parse.urlencode(query), "")), "pages-realtime-room." + page


def proxy_address(url):
    u = urllib.parse.urlsplit(url)
    if u.scheme != "http" or not u.hostname or u.username is not None or u.password is not None or u.path not in ("", "/") or u.query or u.fragment:
        raise ValueError("Page transport currently requires a credential-free HTTP upstream")
    return u.hostname, u.port or 80


def identity(pid, app):
    try:
        text = subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "uid=,lstart=,comm="], text=True).strip()
    except subprocess.CalledProcessError:
        return None
    if not text.startswith(str(os.getuid()) + " ") or not text.endswith(str(app)):
        return None
    return text


class CDP:
    def __init__(self, sock=None, read_fd=None, write_fd=None):
        self.sock, self.read_fd, self.write_fd = sock, read_fd, write_fd
        self.events, self.pending = queue.Queue(maxsize=4096), {}
        self.lock, self.counter, self.closed = threading.Lock(), 0, threading.Event()
        threading.Thread(target=self.read, daemon=True).start()

    def send(self, method, params=None, session=None, wait=False):
        with self.lock:
            self.counter += 1
            msg = {"id": self.counter, "method": method, "params": params or {}}
            if session:
                msg["sessionId"] = session
            result = queue.Queue(maxsize=1) if wait else None
            if result is not None:
                self.pending[self.counter] = result
            raw = json.dumps(msg, ensure_ascii=True)
            if self.sock:
                self.sock.send(raw)
            else:
                data = (raw + "\0").encode()
                while data:
                    n = os.write(self.write_fd, data)
                    data = data[n:]
        if not wait:
            return None
        try:
            reply = result.get(timeout=8)
            if "error" in reply:
                raise RuntimeError("CDP operation failed: " + method)
            return reply.get("result", {})
        finally:
            with self.lock:
                self.pending.pop(msg["id"], None)

    def read(self):
        buffer = b""
        try:
            while not self.closed.is_set():
                if self.sock:
                    try:
                        raw = self.sock.recv()
                    except websocket.WebSocketTimeoutException:
                        continue
                    if not raw:
                        break
                    messages = [json.loads(raw)]
                else:
                    part = os.read(self.read_fd, 65536)
                    if not part:
                        break
                    buffer += part
                    if len(buffer) > 2 * MAX_RECEIVE:
                        raise ValueError("Oversized CDP message")
                    messages = []
                    while b"\0" in buffer:
                        raw, buffer = buffer.split(b"\0", 1)
                        messages.append(json.loads(raw))
                for msg in messages:
                    if "id" in msg:
                        future = self.pending.get(msg["id"])
                        if future is not None:
                            future.put_nowait(msg)
                    else:
                        self.events.put(msg, timeout=2)
        except Exception:
            pass  # Never print CDP payloads or credential-bearing exceptions.
        finally:
            self.closed.set()

    def close(self):
        self.closed.set()
        if self.sock:
            self.sock.close(timeout=0.2)
        for fd in (self.read_fd, self.write_fd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass


class PagesProxy:
    def __init__(self, cdp, args, tls):
        self.cdp, self.args, self.tls = cdp, args, tls
        self.sessions, self.channels = {}, {}
        self.messages = queue.Queue(maxsize=2048)
        self.running = threading.Event()
        self.running.set()
        self.opens, self.frames, self.errors = 0, 0, 0
        self.app_identity = identity(args.pid, args.app)
        self.proxy_host, self.proxy_port = proxy_address(args.proxy)

    def attach(self, target):
        url = urllib.parse.urlsplit(target.get("url", ""))
        if urllib.parse.parse_qs(url.query).get("initialRoute") == ["/avatar-overlay"]:
            return
        if target.get("type") != "page" or url.scheme != "app" or url.netloc != "-" or url.path not in ("/index.html", "/detached-window.html") or any(s["target"] == target["targetId"] for s in self.sessions.values()):
            return
        sid = self.cdp.send("Target.attachToTarget", {"targetId": target["targetId"], "flatten": True}, wait=True)["sessionId"]
        info = {"target": target["targetId"], "ready": False}
        self.sessions[sid] = info
        self.cdp.send("Runtime.enable", session=sid, wait=True)
        self.cdp.send("Runtime.addBinding", {"name": BINDING}, sid, wait=True)
        info["script"] = self.cdp.send("Page.addScriptToEvaluateOnNewDocument", {"source": ADAPTER}, sid, wait=True)["identifier"]
        self.cdp.send("Runtime.evaluate", {"expression": ADAPTER}, sid, wait=True)
        self.cdp.send("Debugger.enable", session=sid, wait=True)
        bp = self.cdp.send("Debugger.setBreakpointByUrl", {"urlRegex": SCRIPT_PATTERN, "lineNumber": LINE, "columnNumber": COLUMN,
            "condition": "c=window.__codexPageProxy||c,false"}, sid, wait=True)
        if any(loc["lineNumber"] != LINE or loc["columnNumber"] != COLUMN for loc in bp.get("locations", [])):
            raise RuntimeError("Unexpected Page transport call site")
        info.update(ready=True, breakpoint=bp["breakpointId"])
        print("[PAGES] renderer adapter ready", flush=True)

    def emit(self, key, event):
        self.messages.put((key, event), timeout=2)

    def upstream(self, key, params, channel):
        sock, code = None, 1006
        try:
            url, protocol = endpoint(params)
            sock = websocket.create_connection(url, timeout=12, suppress_origin=True,
                http_proxy_host=self.proxy_host, http_proxy_port=self.proxy_port,
                proxy_type="http", http_no_proxy=[], subprotocols=[protocol],
                sslopt={"context": self.tls}, redirect_limit=0, enable_multithread=True)
            channel["sock"] = sock
            if channel["stop"].is_set():
                return
            self.emit(key, {"type": "open", "hostReceivedAtMs": time.time() * 1000})
            sock.settimeout(0.5)
            last_ping = time.monotonic()
            while self.running.is_set() and not channel["stop"].is_set():
                try:
                    data = sock.recv()
                except websocket.WebSocketTimeoutException:
                    if time.monotonic() - last_ping > 25:
                        sock.ping()
                        last_ping = time.monotonic()
                    continue
                if not data:
                    code = 1000
                    break
                if not isinstance(data, str) or len(data.encode()) > MAX_RECEIVE:
                    raise ValueError("Invalid Page frame")
                self.emit(key, {"type": "message", "data": data, "messageBytes": len(data.encode()), "hostReceivedAtMs": time.time() * 1000})
        except Exception as error:
            if not channel["stop"].is_set():
                self.emit(key, {"type": "error", "name": type(error).__name__, "message": "Page proxy connection failed"})
        finally:
            if sock:
                sock.close(timeout=0.2)
            self.emit(key, {"type": "close", "code": code, "reason": ""})

    def stop_channel(self, key):
        channel = self.channels.pop(key, None)
        if channel:
            channel["stop"].set()
            if channel.get("sock"):
                channel["sock"].abort()

    def event(self, msg):
        method, p, sid = msg.get("method"), msg.get("params", {}), msg.get("sessionId")
        if method in ("Target.targetCreated", "Target.targetInfoChanged"):
            self.attach(p["targetInfo"])
        elif method == "Target.detachedFromTarget":
            sid = p["sessionId"]
            self.sessions.pop(sid, None)
            for key in list(self.channels):
                if key[0] == sid:
                    self.stop_channel(key)
        elif method == "Runtime.executionContextsCleared":
            for key in list(self.channels):
                if key[0] == sid:
                    self.stop_channel(key)
        elif method == "Runtime.bindingCalled" and p.get("name") == BINDING and sid in self.sessions:
            if len(p["payload"]) > 8 * MAX_SEND:
                raise ValueError("Oversized Page binding message")
            data = json.loads(p["payload"])
            key = (sid, p["executionContextId"], str(data["id"]))
            if data["action"] == "connect":
                endpoint(data["params"])
                if key in self.channels or len(self.channels) >= 32:
                    raise ValueError("Too many Page connections")
                channel = {"stop": threading.Event()}
                self.channels[key] = channel
                threading.Thread(target=self.upstream, args=(key, data["params"], channel), daemon=True).start()
            elif data["action"] == "send" and key in self.channels:
                content = data["data"]
                if not isinstance(content, str) or len(content.encode()) > MAX_SEND:
                    raise ValueError("Invalid outbound Page frame")
                sock = self.channels[key].get("sock")
                if sock is None:
                    raise ValueError("Page connection is not ready")
                try:
                    sock.send(content)
                except Exception as error:
                    # A dropped Page socket must not stop other Pages or the helper.
                    self.emit(key, {"type": "error", "name": type(error).__name__, "message": "Page proxy connection failed"})
                    self.emit(key, {"type": "close", "code": 1006, "reason": ""})
            elif data["action"] == "close":
                self.stop_channel(key)

    def flush(self):
        for _ in range(100):
            try:
                key, event = self.messages.get_nowait()
            except queue.Empty:
                return
            if key not in self.channels:
                continue
            kind = event["type"]
            if kind == "open":
                self.opens += 1
                print("[PAGES] upstream websocket connected (101)", flush=True)
            elif kind == "message":
                self.frames += 1
            elif kind == "error":
                self.errors += 1
                print("[PAGES] transport error: " + event["name"], flush=True)
            self.cdp.send("Runtime.evaluate", {"expression": "window.__codexPageProxyDeliver?.(" + json.dumps(key[2]) + "," + json.dumps(event) + ")", "contextId": key[1]}, key[0])
            if kind == "close":
                self.stop_channel(key)

    def status(self, state="running"):
        payload = {"state": state, "updated": time.time(), "helper_pid": os.getpid(),
            "app_pid": self.args.pid, "app_identity": self.app_identity, "build": BUILD,
            "mode": self.args.mode, "ready_renderers": sum(x["ready"] for x in self.sessions.values()),
            "active_connections": len(self.channels), "total_opens": self.opens,
            "received_frames": self.frames, "errors": self.errors}
        fd, name = tempfile.mkstemp(prefix=".pages-status-", dir=self.args.state.parent)
        try:
            with os.fdopen(fd, "w") as out:
                json.dump(payload, out)
            os.replace(name, self.args.state)
        finally:
            if os.path.exists(name):
                os.unlink(name)

    def run(self):
        check_at = 0
        try:
            self.cdp.send("Target.setDiscoverTargets", {"discover": True}, wait=True)
            for target in self.cdp.send("Target.getTargets", wait=True)["targetInfos"]:
                self.attach(target)
            while self.running.is_set() and not self.cdp.closed.is_set():
                if time.monotonic() >= check_at:
                    if not self.app_identity or identity(self.args.pid, self.args.app) != self.app_identity:
                        break
                    self.status()
                    check_at = time.monotonic() + 5
                self.flush()
                try:
                    self.event(self.cdp.events.get(timeout=0.1))
                except queue.Empty:
                    pass
        finally:
            self.running.clear()
            for key in list(self.channels):
                try:
                    self.cdp.send("Runtime.evaluate", {"expression": "window.__codexPageProxyDeliver?.(" + json.dumps(key[2]) + ",{type:'close',code:1006,reason:'Page proxy stopped'})", "contextId": key[1]}, key[0])
                except Exception:
                    pass
                self.stop_channel(key)
            for sid, info in list(self.sessions.items()):
                try:
                    if info.get("breakpoint"):
                        self.cdp.send("Debugger.removeBreakpoint", {"breakpointId": info["breakpoint"]}, sid)
                    if info.get("script"):
                        self.cdp.send("Page.removeScriptToEvaluateOnNewDocument", {"identifier": info["script"]}, sid)
                    # Retain inert adapter closures so cached Pages can reconnect on re-attach.
                    self.cdp.send("Runtime.removeBinding", {"name": BINDING}, sid)
                    self.cdp.send("Target.detachFromTarget", {"sessionId": sid})
                except Exception:
                    pass
            self.status("stopped")
            self.cdp.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("check", "verify", "launch", "attach"), required=True)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--proxy", required=True)
    parser.add_argument("--state", type=pathlib.Path, required=True)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--port", type=int, default=9223)
    parser.add_argument("app_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    with open(args.app.parent.parent / "Info.plist", "rb") as f:
        build = str(plistlib.load(f)["CFBundleVersion"])
    proxy_address(args.proxy)
    if build != BUILD:
        print("[PAGES] unsupported ChatGPT build " + build + "; Page adaptation disabled, Chromium/CLI proxy remains available", flush=True)
        if args.mode == "launch":
            extra = args.app_args[1:] if args.app_args[:1] == ["--"] else args.app_args
            os.execve(str(args.app), [str(args.app), *extra], dict(os.environ))
        raise SystemExit(2)
    if args.mode == "check":
        print("[PAGES] runtime and ChatGPT build supported")
        return
    if args.mode == "verify":
        state = json.loads(args.state.read_text())
        os.kill(state["helper_pid"], 0)
        if state["app_pid"] != args.pid or state["state"] != "running" or time.time() - state["updated"] > 20 or state["build"] != build or not state["ready_renderers"] or identity(args.pid, args.app) != state["app_identity"]:
            raise ValueError("Page helper is not active for this ChatGPT process")
        print("[PAGES] adapter active; openings=" + str(state["total_opens"]) + ", frames=" + str(state["received_frames"]))
        return
    if not args.state.parent.is_dir() or args.state.parent.stat().st_uid != os.getuid():
        raise ValueError("Page status directory must belong to the current user")
    lock_fd = os.open(str(args.state) + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    app_env = dict(os.environ)
    # The Page companion uses origin TLS through upstream, not the relay's CA.
    os.environ.pop("SSL_CERT_FILE", None)
    os.environ.pop("SSL_CERT_DIR", None)
    tls = ssl.create_default_context()
    if args.mode == "launch":
        extra = args.app_args[1:] if args.app_args[:1] == ["--"] else args.app_args
        if any(x.startswith("--remote-debugging") for x in extra):
            raise ValueError("Debug TCP flags are not accepted by the pipe launcher")
        r, w = os.pipe()
        out, childout = os.pipe()
        child = subprocess.Popen(["/bin/zsh", "-c", f'exec 3<&{r} 4>&{childout}; exec "$@"', "pages-pipe",
            str(args.app), *extra, "--remote-debugging-pipe"], pass_fds=(r, childout), stdin=subprocess.DEVNULL, env=app_env)
        os.close(r)
        os.close(childout)
        args.pid = child.pid
        cdp = CDP(read_fd=out, write_fd=w)
        # Wait only for this new child to exec the expected official executable.
        until = time.monotonic() + 5
        while identity(args.pid, args.app) is None and child.poll() is None and time.monotonic() < until:
            time.sleep(0.05)
    else:
        if not args.pid or not identity(args.pid, args.app):
            raise ValueError("Attach target is not the current user's ChatGPT process")
        owner = subprocess.check_output(["/usr/sbin/lsof", "-nP", "-a", "-iTCP:" + str(args.port), "-sTCP:LISTEN", "-Fp"], text=True)
        if "p" + str(args.pid) not in owner.splitlines():
            raise ValueError("Debug listener does not belong to the target application")
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open("http://127.0.0.1:" + str(args.port) + "/json/version", timeout=3) as response:
            debugger = json.load(response)["webSocketDebuggerUrl"]
        u = urllib.parse.urlsplit(debugger)
        if u.hostname not in ("127.0.0.1", "localhost", "::1") or u.port != args.port:
            raise ValueError("Debug endpoint must remain loopback")
        cdp = CDP(sock=websocket.create_connection(debugger, timeout=0.5, suppress_origin=True, http_no_proxy=["127.0.0.1", "localhost", "::1"]))
    helper = PagesProxy(cdp, args, tls)
    signal.signal(signal.SIGTERM, lambda *_: helper.running.clear())
    signal.signal(signal.SIGINT, lambda *_: helper.running.clear())
    helper.run()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Exception strings can contain signed URLs. Log class only.
        print("[PAGES] stopped: " + type(error).__name__ + "; check build, runtime dependencies and proxy", flush=True)
        raise SystemExit(1)
