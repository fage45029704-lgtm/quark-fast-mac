#!/usr/bin/env bash
# ============================================================
#  quark-fast / setup.sh
#  作用：找到 aria2 → 建目录 → 装配置 → 加 qdl 别名 → 自检
#  用法：bash setup.sh
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="$HOME/.config/quark-fast"
OUT_DIR="$HOME/Downloads/quark"
ZSHRC="$HOME/.zshrc"
MARK_BEGIN="# >>> quark-fast >>>"
MARK_END="# <<< quark-fast <<<"

c_hdr()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
c_ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31m%s\033[0m\n' "$*"; }

c_hdr "== 1/5 查找 aria2"
ARIA2=""
for c in "$(command -v aria2c 2>/dev/null)" \
         /Applications/Motrix.app/Contents/Resources/extra/*/*/aria2c \
         "/Applications/Motrix.app/Contents/Resources/engine/aria2c" \
         "/opt/homebrew/bin/aria2c" "/usr/local/bin/aria2c"; do
  if [ -n "$c" ] && [ -x "$c" ]; then ARIA2="$c"; break; fi
done
if [ -n "$ARIA2" ]; then
  c_ok "  可用：$ARIA2"
  echo "        $("$ARIA2" --version 2>/dev/null | head -1)"
elif command -v brew >/dev/null 2>&1; then
  c_warn "  没找到现成的 aria2c，用 brew 装一个 ..."
  brew install aria2 || { c_err "  安装失败"; exit 1; }
  ARIA2="$(command -v aria2c)"
  c_ok "  已安装：$ARIA2"
else
  c_err "  没找到 aria2c，也没有 Homebrew。"
  c_warn "  最省事的办法：装 Motrix（motrix.app），它自带 aria2c，本工具会自动找到并用它。"
  exit 1
fi

c_hdr "== 2/5 建目录"
mkdir -p "$CONF_DIR" "$OUT_DIR"
chmod 700 "$CONF_DIR" 2>/dev/null
c_ok "  $CONF_DIR"
c_ok "  $OUT_DIR"

c_hdr "== 3/5 安装配置"
cp "$HERE/aria2.conf" "$CONF_DIR/aria2.conf"
touch "$CONF_DIR/aria2.session"
chmod 600 "$CONF_DIR/aria2.conf"
c_ok "  aria2.conf 已就位（16 连接 / 断点续传 / 不预分配）"

c_hdr "== 4/5 加 qdl 别名"
if [ ! -f "$ZSHRC" ]; then touch "$ZSHRC"; fi
if grep -qF "$MARK_BEGIN" "$ZSHRC" 2>/dev/null; then
  python3 - "$ZSHRC" "$HERE" <<'PY'
import re, sys
path, here = sys.argv[1], sys.argv[2]
s = open(path).read()
block = ("# >>> quark-fast >>>\n"
         f'alias qdl="{here}/dl.sh"\n'
         f'alias qdl-py="python3 {here}/quark_dl.py"\n'
         "# <<< quark-fast <<<\n")
s = re.sub(r"# >>> quark-fast >>>.*?# <<< quark-fast <<<\n?", block, s, flags=re.S)
open(path, "w").write(s)
PY
  c_ok "  已有标记块，路径已更新"
else
  {
    echo ""
    echo "$MARK_BEGIN"
    echo "alias qdl=\"$HERE/dl.sh\""
    echo "alias qdl-py=\"python3 $HERE/quark_dl.py\""
    echo "$MARK_END"
  } >> "$ZSHRC"
  c_ok "  已写入 $ZSHRC"
  echo "        新开一个终端，或执行： source ~/.zshrc"
fi

c_hdr "== 5/5 自检"
echo "  aria2   : ${ARIA2:-未找到}"
echo "  配置    : $CONF_DIR/aria2.conf"
echo "  下载目录: $OUT_DIR"
echo -n "  Cookie  : "
if [ -s "$CONF_DIR/cookie.txt" ]; then
  c_ok "已有（$(wc -c < "$CONF_DIR/cookie.txt" | tr -d ' ') 字节）"
else
  c_warn "还没有 → 浏览器登录 pan.quark.cn 后跑：python3 $HERE/get_cookie.py"
fi
echo "  磁盘剩余:"
df -h "$HOME" | tail -1 | awk '{printf "           %s 可用 / %s（已用 %s）\n", $4, $2, $5}'

echo
c_hdr "下一步"
echo "  1) 浏览器打开 https://pan.quark.cn 登录（手机夸克 App 扫码，不用密码）"
echo "  2) python3 $HERE/get_cookie.py    # 或手动把 Cookie 存到 $CONF_DIR/cookie.txt"
echo "  3) python3 $HERE/quark_dl.py whoami"
echo "  4) python3 $HERE/quark_dl.py ls /"
echo "  5) python3 $HERE/quark_dl.py dl \"<文件路径>\""
