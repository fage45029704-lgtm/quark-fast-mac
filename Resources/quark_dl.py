#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
quark-fast / quark_dl.py —— 自己网盘里的文件，取直链 + 多连接下载（macOS 原生，零依赖）

关键点（照 Alist 的 Quark 驱动实现）：
  API   : https://drive.quark.cn/1/clouddrive   （PC 客户端通道，不是 Web 通道）
  Query : pr=ucpro & fr=pc
  UA    : quark-cloud-drive 客户端 UA
  下载签名绑定「请求 /file/download 时的 Cookie」→ 下载头必须带同一份 Cookie + Referer + UA，
          否则 403。这就是很多脚本下到一半失败的原因。

用法:
  python3 quark_dl.py whoami                     验证 Cookie 是否有效
  python3 quark_dl.py ls [路径]                   列目录（默认根目录）
  python3 quark_dl.py link <路径|fid>             只打印直链
  python3 quark_dl.py dl   <路径|fid> [-j 16]     取直链并交给 aria2 多连接下载
  python3 quark_dl.py dl   <路径|fid> --print    只生成 aria2 命令，不执行

Cookie 来源（优先级从高到低）:
  --cookie "..."   →  环境变量 QUARK_COOKIE  →  ~/.config/quark-fast/cookie.txt
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://drive.quark.cn/1/clouddrive"
REFERER = "https://pan.quark.cn"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 "
      "Safari/537.36 Channel/pckk_other_ch")
CONF_DIR = os.path.expanduser("~/.config/quark-fast")
COOKIE_FILE = os.path.join(CONF_DIR, "cookie.txt")
OUT_DIR = os.path.expanduser("~/Downloads/quark")


def find_aria2():
    """PATH → 本工具配置目录 → Motrix 自带 → Homebrew。Motrix 里那份能直接用，省掉安装。"""
    cands = [shutil.which("aria2c"),
             os.path.expanduser("~/.config/quark-fast/aria2c")]
    cands += sorted(glob.glob("/Applications/Motrix.app/Contents/Resources/extra/*/*/aria2c"))
    cands += ["/Applications/Motrix.app/Contents/Resources/engine/aria2c",
              "/opt/homebrew/bin/aria2c",
              "/usr/local/bin/aria2c"]
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


def c(t, s):
    codes = {"ok": "32", "warn": "33", "err": "31", "hdr": "36", "dim": "2"}
    print(f"\033[1;{codes.get(t, '0')}m{s}\033[0m")


def die(msg, hint=None):
    c("err", "✗ " + msg)
    if hint:
        print("  " + hint)
    sys.exit(1)


def load_cookie(arg=None):
    if arg:
        return arg.strip()
    env = os.environ.get("QUARK_COOKIE", "").strip()
    if env:
        return env
    if os.path.exists(COOKIE_FILE):
        with open(COOKIE_FILE, "r", encoding="utf-8") as f:
            v = f.read().strip()
        if v:
            return v
    die("没有 Cookie。", "在浏览器登录 pan.quark.cn → F12 → Network → 任一请求 → 复制整个 Cookie 值，"
                        f"写入 {COOKIE_FILE}，或用 --cookie 参数传入。")


def save_cookie(cookie):
    os.makedirs(CONF_DIR, exist_ok=True)
    tmp = COOKIE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(cookie)
    os.chmod(tmp, 0o600)
    os.replace(tmp, COOKIE_FILE)


def merge_set_cookie(cookie, headers):
    """夸克会通过 Set-Cookie 轮换 __puus，不跟着更新就会在 1~2 小时后 403。"""
    jars = headers.get_all("Set-Cookie") or []
    if not jars:
        return cookie, False
    jar = {}
    for pair in cookie.split(";"):
        if "=" in pair:
            k, v = pair.split("=", 1)
            jar[k.strip()] = v.strip()
    changed = False
    for sc in jars:
        first = sc.split(";")[0]
        if "=" not in first:
            continue
        k, v = first.split("=", 1)
        k, v = k.strip(), v.strip()
        if k in ("__puus", "__pus") and jar.get(k) != v:
            jar[k] = v
            changed = True
    if not changed:
        return cookie, False
    return "; ".join(f"{k}={v}" for k, v in jar.items()), True


class Quark:
    def __init__(self, cookie, verbose=False):
        self.cookie = cookie
        self.verbose = verbose
        self.dirty = False

    def _req(self, path, method="GET", params=None, body=None):
        q = {"pr": "ucpro", "fr": "pc"}
        if params:
            q.update({k: str(v) for k, v in params.items()})
        url = f"{API}{path}?{urllib.parse.urlencode(q)}"
        data = None
        headers = {
            "Cookie": self.cookie,
            "Referer": REFERER,
            "User-Agent": UA,
            "Accept": "application/json, text/plain, */*",
        }
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json;charset=UTF-8"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
                new_cookie, changed = merge_set_cookie(self.cookie, r.headers)
                if changed:
                    self.cookie = new_cookie
                    self.dirty = True
        except urllib.error.HTTPError as e:
            raw = e.read() or b"{}"
            try:
                j = json.loads(raw)
            except Exception:
                die(f"HTTP {e.code}", raw[:200].decode("utf-8", "replace"))
            die(f"HTTP {e.code} / code={j.get('code')} {j.get('message', '')}",
                "Cookie 可能已过期，重新复制一份。")
        except urllib.error.URLError as e:
            die(f"网络错误: {e.reason}", "检查网络 / 代理；夸克直链绑 IP，别挂代理。")
        try:
            j = json.loads(raw)
        except Exception:
            die("返回不是 JSON", raw[:300].decode("utf-8", "replace"))
        if j.get("code") not in (0, None) or (j.get("status") or 0) >= 400:
            msg = j.get("message") or ""
            code = j.get("code")
            hint = None
            if code in (31001, 31023, 31024) or "cookie" in msg.lower() or "登录" in msg:
                hint = "Cookie 失效：重新从浏览器复制（注意要带 __puus）。"
            elif "空间" in msg:
                hint = "网盘空间不足（转存类操作会占空间）。"
            die(f"接口报错 code={code} {msg}", hint)
        return j

    def list(self, pdir="0"):
        out, page = [], 1
        while True:
            j = self._req("/file/sort", params={
                "pdir_fid": pdir, "_page": page, "_size": 100,
                "_fetch_total": 1, "fetch_all_file": 1, "fetch_risk_file_name": 1,
            })
            data = j.get("data") or {}
            out.extend(data.get("list") or [])
            total = ((j.get("metadata") or {}).get("_total")) or 0
            if page * 100 >= total:
                break
            page += 1
        return out

    def resolve(self, spec):
        """把 /a/b/c、a/b/c 或 fid 解析成一个文件对象。"""
        if re.fullmatch(r"[0-9a-fA-F]{16,}", spec):
            return {"fid": spec, "file_name": spec, "size": 0, "file": True}
        parts = [p for p in spec.split("/") if p]
        cur = "0"
        node = None
        for i, name in enumerate(parts):
            items = self.list(cur)
            hits = [x for x in items if x.get("file_name") == name]
            if not hits:
                cand = [x.get("file_name") for x in items][:12]
                die(f"找不到「{name}」", "该层可选：" + ", ".join(cand))
            node = hits[0]
            if i < len(parts) - 1:
                if node.get("file"):
                    die(f"「{name}」是文件，不是目录")
                cur = node["fid"]
        return node

    def download_url(self, fid):
        j = self._req("/file/download", method="POST", body={"fids": [fid]})
        data = j.get("data") or []
        if not data or not data[0].get("download_url"):
            die("没拿到直链", json.dumps(j)[:300])
        return data[0]["download_url"], data[0].get("file_name") or ""


def fmt_size(n):
    if not n:
        return "-"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


def cmd_whoami(q):
    root = q.list("0")
    c("ok", "✓ Cookie 有效，接口通了")
    c("dim", f"  根目录 {len(root)} 项，前几项：")
    for x in root[:8]:
        kind = "DIR " if not x.get("file") else "FILE"
        print(f"   {kind} {fmt_size(x.get('size')):>10}  {x.get('file_name')}")


def cmd_ls(q, path, as_json=False):
    if path in (None, "", "/"):
        cur, title = "0", "/"
    else:
        node = q.resolve(path)
        if node.get("file"):
            if as_json:
                print(json.dumps({"path": path, "items": [{
                    "fid": node.get("fid"), "name": node.get("file_name"),
                    "size": node.get("size") or 0, "dir": False}]}, ensure_ascii=False))
            else:
                print(f"FILE {fmt_size(node.get('size')):>10}  {node.get('fid')}  {node.get('file_name')}")
            return
        cur, title = node["fid"], path
    items = q.list(cur)
    if as_json:
        print(json.dumps({"path": title, "items": [{
            "fid": x.get("fid"), "name": x.get("file_name"),
            "size": x.get("size") or 0,
            "dir": bool(x.get("dir")) or not bool(x.get("file")),
            "updated": x.get("updated_at") or 0} for x in items]}, ensure_ascii=False))
        return
    if not items:
        c("warn", f"{title} (空)")
        return
    c("dim", f"{title}  共 {len(items)} 项")
    for x in items:
        kind = "DIR " if not x.get("file") else "FILE"
        print(f"{kind} {fmt_size(x.get('size')):>10}  {x.get('fid')}  {x.get('file_name')}")


def cmd_link(q, spec, quiet=False):
    node = q.resolve(spec)
    url, name = q.download_url(node["fid"])
    if quiet:
        print(url)
    else:
        c("hdr", f"== {node.get('file_name')}  ({fmt_size(node.get('size'))})")
        print(url)
        c("dim", f"  直链有效期有限（夸克通常数小时）且绑当前 IP；UA/Cookie/Referer 必须与取链时一致。")
        c("warn", "  注意：链接里带签名，别贴到公开场合。")
    return url, node.get("file_name") or name


def cmd_dl(q, spec, threads, print_only):
    url, name = cmd_link(q, spec, quiet=print_only)
    if not url:
        return
    os.makedirs(OUT_DIR, exist_ok=True)
    if print_only:
        print()
        print("aria2c -c -x {n} -s {n} -k1M --file-allocation=none \\\n"
              "  --header=\"Referer: {r}\" --header=\"User-Agent: '{ua}'\" \\\n"
              "  -d \"{d}\" \"{u}\"".format(n=threads, r=REFERER, ua=UA, d=OUT_DIR, u=url))
        return

    # 把敏感头写进临时 conf（600），避免 Cookie 出现在 ps 命令行里
    fd, conf = tempfile.mkstemp(prefix="qf-aria-", suffix=".conf")
    os.close(fd)
    os.chmod(conf, 0o600)
    with open(conf, "w", encoding="utf-8") as f:
        f.write(
            f'dir={OUT_DIR}\n'
            f'continue=true\n'
            f'split={threads}\n'
            f'max-connection-per-server={threads}\n'
            f'min-split-size=1M\n'
            f'file-allocation=none\n'
            f'max-tries=0\n'
            f'retry-wait=10\n'
            f'summary-interval=5\n'
            f'header=Cookie: {q.cookie}\n'
            f'header=Referer: {REFERER}\n'
            f'header=User-Agent: {UA}\n'
        )
    # 512 连接要先放开 fd 上限（macOS 默认 soft=256）
    try:
        import resource
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        if soft < 8192:
            target = 8192 if hard in (resource.RLIM_INFINITY, -1) or hard >= 8192 else hard
            resource.setrlimit(resource.RLIMIT_NOFILE, (target, hard))
    except Exception:
        pass

    try:
        aria2 = find_aria2()
        if not aria2:
            die("没找到 aria2c", "装 Motrix（它自带一份）或 brew install aria2")
        c("hdr", f"== aria2 下载（{threads} 连接）→ {OUT_DIR}")
        c("dim", f"  引擎: {aria2}")
        cmd = [aria2, f"--conf-path={conf}", "-o", name, url]
        rc = subprocess.call(cmd)
    finally:
        try:
            os.unlink(conf)
        except OSError:
            pass
    if rc == 0:
        c("ok", f"✓ 完成：{os.path.join(OUT_DIR, name)}")
    else:
        c("err", f"aria2 退出码 {rc}（直链过期就重新跑一次，会断点续传）")
    sys.exit(rc)


def main():
    ap = argparse.ArgumentParser(add_help=True, description="夸克自己网盘：取直链 + 多连接下载")
    ap.add_argument("--cookie", help="直接传 Cookie 字符串")
    sub = ap.add_subparsers(dest="cmd")

    sub.add_parser("whoami", help="验证 Cookie")
    p_ls = sub.add_parser("ls", help="列目录")
    p_ls.add_argument("path", nargs="?", default="/")
    p_ls.add_argument("--json", dest="as_json", action="store_true", help="输出 JSON（给 GUI 用）")
    p_lk = sub.add_parser("link", help="打印直链")
    p_lk.add_argument("spec")
    p_dl = sub.add_parser("dl", help="取直链并下载")
    p_dl.add_argument("spec")
    p_dl.add_argument("-j", "--threads", type=int, default=512,
                      help="aria2 连接数；实测夸克每连接约 10KB/s，512≈3.5MB/s")
    p_dl.add_argument("--print", dest="print_only", action="store_true")

    args = ap.parse_args()
    if not args.cmd:
        ap.print_help()
        return

    cookie = load_cookie(args.cookie)
    q = Quark(cookie)
    try:
        if args.cmd == "whoami":
            cmd_whoami(q)
        elif args.cmd == "ls":
            cmd_ls(q, args.path, args.as_json)
        elif args.cmd == "link":
            cmd_link(q, args.spec)
        elif args.cmd == "dl":
            cmd_dl(q, args.spec, args.threads, args.print_only)
    finally:
        if q.dirty:
            save_cookie(q.cookie)


if __name__ == "__main__":
    main()
