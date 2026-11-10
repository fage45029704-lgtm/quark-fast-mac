#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
quark-fast / login.py —— 开一个干净的 Chrome 窗口扫码登录，直接从页面里取 Cookie

为什么不用 get_cookie.py：
  · 不读钥匙串、不碰你日常浏览器的 Cookie 库（也就没有 TCC「完全磁盘访问权限」的麻烦）
  · 用一个独立的一次性配置目录 ~/.config/quark-fast/chrome，登完可以整个删掉
  · 走 Chrome DevTools 协议（Network.getAllCookies），httpOnly 的 __puus 也能拿到

用法：
  python3 login.py            # 弹窗 → 手机夸克 App 扫码 → 自动收 Cookie
  python3 login.py --manual   # 只弹窗，你自己扫码后按回车
  python3 login.py --show     # 不开窗，只把现有一次性窗口里的 Cookie 再导一次
"""
import argparse
import base64
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import time
import urllib.request

HOME = os.path.expanduser("~")
CONF_DIR = os.path.join(HOME, ".config", "quark-fast")
COOKIE_FILE = os.path.join(CONF_DIR, "cookie.txt")
PROFILE = os.path.join(CONF_DIR, "chrome")
PORT = 9333
URL = "https://pan.quark.cn/list#/list/all"

CHROME_CANDS = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/Applications/Quark.app/Contents/MacOS/Quark",
]


def c(t, s):
    codes = {"ok": "32", "warn": "33", "err": "31", "hdr": "36", "dim": "2"}
    print(f"\033[1;{codes.get(t, '0')}m{s}\033[0m", flush=True)


# ---------------- 极简 WebSocket 客户端（够用：文本帧 + 掩码 + 分片）----------------
class WS:
    def __init__(self, url, timeout=20):
        from urllib.parse import urlparse
        u = urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port or 80), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        path = u.path + (f"?{u.query}" if u.query else "")
        req = (f"GET {path} HTTP/1.1\r\n"
               f"Host: {u.hostname}:{u.port}\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            d = self.sock.recv(4096)
            if not d:
                raise RuntimeError("WS 握手失败")
            buf += d
        if b"101" not in buf.split(b"\r\n")[0]:
            raise RuntimeError("WS 握手被拒: " + buf.split(b"\r\n")[0].decode("latin1"))
        self.buf = b""

    def send(self, obj):
        payload = json.dumps(obj).encode()
        mask = os.urandom(4)
        hdr = bytearray([0x81])
        n = len(payload)
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126)
            hdr += struct.pack(">H", n)
        else:
            hdr.append(0x80 | 127)
            hdr += struct.pack(">Q", n)
        hdr += mask
        self.sock.sendall(bytes(hdr) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _read(self, n):
        while len(self.buf) < n:
            d = self.sock.recv(65536)
            if not d:
                raise RuntimeError("WS 断开")
            self.buf += d
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self):
        while True:
            b0, b1 = self._read(2)
            opcode = b0 & 0x0F
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read(8))[0]
            masked = b1 & 0x80
            mask = self._read(4) if masked else None
            data = self._read(length)
            if masked:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 9:          # ping → pong
                self.sock.sendall(bytes([0x8A, 0x80]) + os.urandom(4))
                continue
            if opcode == 8:
                raise RuntimeError("WS 被关闭")
            if opcode in (1, 2):
                return json.loads(data.decode("utf-8", "replace"))


def http_json(path):
    with urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}", timeout=5) as r:
        return json.loads(r.read())


def find_chrome():
    for p in CHROME_CANDS:
        if os.path.exists(p):
            return p
    return None


def ensure_chrome():
    try:
        http_json("/json/version")
        return None   # 已经在跑
    except Exception:
        pass
    chrome = find_chrome()
    if not chrome:
        c("err", "✗ 没找到 Chrome / Chromium / Edge / Quark")
        sys.exit(1)
    os.makedirs(PROFILE, exist_ok=True)
    c("dim", f"  启动浏览器：{os.path.basename(chrome)}（独立配置，不影响你日常的浏览器）")
    subprocess.Popen(
        [chrome,
         f"--user-data-dir={PROFILE}",
         f"--remote-debugging-port={PORT}",
         "--remote-allow-origins=*",
         "--no-first-run", "--no-default-browser-check",
         "--disable-features=Translate",
         URL],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try:
            http_json("/json/version")
            return chrome
        except Exception:
            time.sleep(0.5)
    c("err", "✗ 浏览器调试端口没起来（可能被安全软件拦了）")
    sys.exit(1)


def page_ws():
    for t in http_json("/json"):
        if t.get("type") == "page" and "devtools" not in t.get("url", ""):
            return t.get("webSocketDebuggerUrl")
    return None


def get_cookies():
    url = page_ws()
    if not url:
        raise RuntimeError("没有可用页面")
    ws = WS(url)
    ws.send({"id": 1, "method": "Network.getAllCookies"})
    deadline = time.time() + 15
    while time.time() < deadline:
        msg = ws.recv()
        if msg.get("id") == 1:
            if "error" in msg:
                raise RuntimeError(msg["error"])
            return msg["result"]["cookies"]
    raise RuntimeError("取 Cookie 超时")


NEED = ["__puus", "__pus", "__kp", "__uid", "__ktd", "b-user-id", "tfstk", "isg", "__kuus"]


def pick(cookies):
    jar = {}
    for ck in cookies:
        if "quark.cn" not in ck.get("domain", ""):
            continue
        jar.setdefault(ck["name"], {})[ck["domain"]] = ck["value"]
    order = ["drive.quark.cn", "pan.quark.cn", ".quark.cn"]
    parts = []
    for name in NEED + [n for n in jar if n not in NEED]:
        if name not in jar:
            continue
        src = jar[name]
        v = next((src[d] for d in order if d in src), None) or list(src.values())[0]
        parts.append(f"{name}={v}")
    return "; ".join(parts), set(jar)


def save(cookie):
    os.makedirs(CONF_DIR, exist_ok=True)
    tmp = COOKIE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(cookie)
    os.chmod(tmp, 0o600)
    os.replace(tmp, COOKIE_FILE)


def main():
    ap = argparse.ArgumentParser(description="开独立 Chrome 窗口扫码登录并取夸克 Cookie")
    ap.add_argument("--manual", action="store_true", help="不自动轮询，等你按回车")
    ap.add_argument("--show", action="store_true", help="只导出现有窗口的 Cookie")
    ap.add_argument("--keep", action="store_true", help="用完不关浏览器")
    args = ap.parse_args()

    started = ensure_chrome()
    if not args.show:
        c("hdr", "== 在弹出的窗口里登录")
        c("dim", "  1) 页面已打开 pan.quark.cn")
        c("dim", "  2) 点右上角「登录」→ 手机夸克 App 扫码")
        c("dim", "  3) 看到网盘文件列表就算成功，脚本会自动收 Cookie")
        print()

    deadline = time.time() + (600 if args.manual else 300)
    last = None
    got = None
    while time.time() < deadline:
        try:
            cookie, names = pick(get_cookies())
        except Exception as e:
            c("dim", f"  等待中…（{e}）")
            cookie, names = "", set()
        if "__puus" in names:
            got = (cookie, names)
            break
        hint = f"  已见 {len(names)} 个夸克 Cookie，还没登录态"
        if hint != last:
            c("dim", hint)
            last = hint
        time.sleep(2)

    if not got:
        c("err", "✗ 没等到登录态（__puus）")
        c("dim", "  窗口我没关，登录完再跑一次：python3 login.py --show")
        sys.exit(2)

    cookie, names = got
    save(cookie)
    c("ok", f"✓ 登录态已保存（{len(names)} 个 Cookie）→ {COOKIE_FILE}")
    if started and not args.keep:
        try:
            os.system(f"pkill -f 'user-data-dir={PROFILE}'")
            c("dim", "  一次性浏览器已关闭；要重登再跑 python3 login.py")
        except Exception:
            pass
    print()
    print("  下一步： python3 quark_dl.py whoami")


if __name__ == "__main__":
    main()
