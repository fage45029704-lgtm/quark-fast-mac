#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
quark-fast / get_cookie.py —— 从本机浏览器里直接读出 pan.quark.cn 的 Cookie

支持任何 Chromium 内核浏览器（夸克浏览器 / Chrome / Edge / Brave / Chromium / 各类套壳），
原理：Cookies 是 SQLite，值用系统钥匙串里的 "<App> Safe Storage" 口令派生的
AES-128-CBC 密钥加密（v10/v11 前缀）；macOS 上自带 openssl 即可解密，无需第三方库。

用法:
  python3 get_cookie.py              # 自动扫描并写入 ~/.config/quark-fast/cookie.txt
  python3 get_cookie.py --print      # 只打印，不写文件
  python3 get_cookie.py --db <path> --service "Chrome Safe Storage"   # 手动指定
"""
import argparse
import glob
import hashlib
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile

HOME = os.path.expanduser("~")
CONF_DIR = os.path.join(HOME, ".config", "quark-fast")
COOKIE_FILE = os.path.join(CONF_DIR, "cookie.txt")

# 需要的 Cookie 名（drive.quark.cn 认 __puus 为主）
NEED = ["__puus", "__pus", "__kp", "__uid", "__ktd", "b-user-id", "tfstk", "isg", "__kuus"]

# (浏览器名, 配置根目录, 钥匙串服务名)
BROWSERS = [
    ("夸克浏览器", "Library/Application Support/Quark", "Quark Safe Storage"),
    ("Chrome", "Library/Application Support/Google/Chrome", "Chrome Safe Storage"),
    ("Chrome Beta", "Library/Application Support/Google/Chrome Beta", "Chrome Safe Storage"),
    ("Edge", "Library/Application Support/Microsoft Edge", "Microsoft Edge Safe Storage"),
    ("Brave", "Library/Application Support/BraveSoftware/Brave-Browser", "Brave Safe Storage"),
    ("Chromium", "Library/Application Support/Chromium", "Chromium Safe Storage"),
    ("Vivaldi", "Library/Application Support/Vivaldi", "Vivaldi Safe Storage"),
    ("Codex", "Library/Application Support/Codex", "Codex Safe Storage"),
]


def c(t, s):
    codes = {"ok": "32", "warn": "33", "err": "31", "hdr": "36", "dim": "2"}
    print(f"\033[1;{codes.get(t, '0')}m{s}\033[0m")


def keychain_secret(service):
    try:
        out = subprocess.run(["security", "find-generic-password", "-w", "-s", service],
                             capture_output=True, timeout=20)
        if out.returncode == 0:
            return out.stdout.strip().decode("utf-8", "replace")
    except Exception:
        pass
    return None


def derive_key(secret):
    return hashlib.pbkdf2_hmac("sha1", secret.encode(), b"saltysalt", 1003, 16)


def decrypt(blob, key):
    if not blob:
        return b""
    prefix = blob[:3]
    if prefix in (b"v10", b"v11"):
        body = blob[3:]
        p = subprocess.run(
            ["openssl", "enc", "-aes-128-cbc", "-d", "-K", key.hex(),
             "-iv", (b" " * 16).hex(), "-nopad"],
            input=body, capture_output=True)
        out = p.stdout
        if not out:
            return b""
        pad = out[-1]
        if 0 < pad <= 16:
            out = out[:-pad]
        return out
    if prefix == b"v20":
        return None  # App-Bound 加密，需浏览器自身解密；跳过
    return blob  # 未加密


def cookie_value(host_key, plain):
    if not plain:
        return b""
    h = hashlib.sha256(host_key.encode()).digest()
    if plain.startswith(h):     # Chrome ≥130 在明文前加了 host 哈希
        return plain[32:]
    return plain


def scan_db(db_path, service, browser):
    if not os.path.exists(db_path):
        return None
    secret = keychain_secret(service)
    if not secret:
        return ("nokey", browser)
    key = derive_key(secret)
    tmpdir = tempfile.mkdtemp(prefix="qf-ck-")
    tmpdb = os.path.join(tmpdir, "Cookies")
    try:
        shutil.copy2(db_path, tmpdb)   # 避免浏览器锁库
        for ext in ("-wal", "-shm"):
            if os.path.exists(db_path + ext):
                shutil.copy2(db_path + ext, tmpdb + ext)
        con = sqlite3.connect(tmpdb)
        rows = con.execute(
            "SELECT host_key,name,encrypted_value,value FROM cookies "
            "WHERE host_key LIKE '%quark.cn%' ORDER BY host_key"
        ).fetchall()
        con.close()
    except Exception as e:
        return ("dberr", f"{e}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    jar = {}
    for host_key, name, ev, val in rows:
        plain = decrypt(ev, key)
        if plain is None:
            continue
        v = cookie_value(host_key, plain)
        if not v and val:
            v = val.encode()
        if not v:
            continue
        # 同名时按域从小到大的优先级：pan.quark.cn / drive.quark.cn 优先
        jar.setdefault(name, {})[host_key] = v.decode("utf-8", "replace")

    order = ["drive.quark.cn", "pan.quark.cn", ".quark.cn"]
    parts = []
    for name in NEED + [n for n in jar if n not in NEED]:
        if name not in jar:
            continue
        src = jar[name]
        pick = next((src[h] for h in order if h in src), None)
        if pick is None:
            pick = list(src.values())[0]
        parts.append(f"{name}={pick}")
    return ("ok", "; ".join(parts), set(jar))


def main():
    ap = argparse.ArgumentParser(description="从本机 Chromium 系浏览器提取夸克网盘 Cookie")
    ap.add_argument("--print", dest="print_only", action="store_true")
    ap.add_argument("--db", help="直接指定 Cookies 数据库路径")
    ap.add_argument("--service", help="钥匙串服务名，如 'Chrome Safe Storage'")
    args = ap.parse_args()

    cands = []
    if args.db:
        cands.append(("手动指定", args.db, args.service or "Chrome Safe Storage"))
    else:
        for name, rel, svc in BROWSERS:
            root = os.path.join(HOME, rel)
            if not os.path.isdir(root):
                continue
            for prof in ["Default"] + [os.path.basename(p) for p in glob.glob(os.path.join(root, "Profile *"))]:
                db = os.path.join(root, prof, "Cookies")
                if os.path.exists(db):
                    cands.append((f"{name}/{prof}", db, svc))

    if not cands:
        c("err", "✗ 没找到任何 Chromium 系浏览器的 Cookie 库")
        print("  解决：用 Chrome / 夸克浏览器打开 pan.quark.cn 登录一次，再跑本脚本。")
        sys.exit(1)

    for label, db, svc in cands:
        r = scan_db(db, svc, label)
        if r is None:
            continue
        if r[0] == "nokey":
            c("dim", f"  跳过 {label}（读不到钥匙串口令，可能需要允许访问）")
            continue
        if r[0] == "dberr":
            c("dim", f"  跳过 {label}（{r[1]}）")
            continue
        _, cookie, names = r
        has_login = "__puus" in names or "__kp" in names or "__uid" in names
        if not has_login:
            c("dim", f"  跳过 {label}（有 {len(names)} 个夸克域 Cookie，但没有登录态 __puus）")
            continue
        c("ok", f"✓ 从 {label} 提取成功，{len(names)} 个 Cookie")
        os.makedirs(CONF_DIR, exist_ok=True)
        if args.print_only:
            print(cookie)
        else:
            tmp = COOKIE_FILE + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(cookie)
            os.chmod(tmp, 0o600)
            os.replace(tmp, COOKIE_FILE)
            c("ok", f"✓ 已写入 {COOKIE_FILE}（权限 600）")
            print()
            print("  下一步： python3 quark_dl.py whoami")
        return

    c("err", "✗ 扫描到的浏览器里都没有 pan.quark.cn 的登录态（__puus）")
    print("  最省事的做法：")
    print("   1) 用 Chrome 或夸克浏览器打开 https://pan.quark.cn 并登录")
    print("   2) 重新运行本脚本")
    print("  或手动复制：F12 → Network → 任一请求 → 复制整个 Cookie 值，粘贴到")
    print(f"   {COOKIE_FILE}")
    sys.exit(2)


if __name__ == "__main__":
    main()
