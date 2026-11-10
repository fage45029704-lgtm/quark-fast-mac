#!/usr/bin/env bash
# ============================================================
#  quark-fast / dl.sh  —— 夸克直链：限速诊断 + 多连接下载
#
#  ./dl.sh -t "<直链>"              测速诊断：按连接限速 or 按账号限速
#  ./dl.sh    "<直链>" [文件名]      512 连接下载（默认）
#  ./dl.sh -j 32 "<直链>"           32 连接
#  ./dl.sh -o "名字.mkv" "<直链>"    指定输出文件名
#  ./dl.sh -f list.txt              批量（每行一条直链）
#  ./dl.sh -s                       查看配置
#
#  直链必须配 cookie.txt 里的 Cookie，否则夸克 CDN 直接 412。
#  没有直链就用：python3 quark_dl.py dl "<网盘路径>"（它自己取直链+下载）
# ============================================================
set -uo pipefail
# aria2 开 512 连接需要足够 fd（macOS 默认 soft limit 只有 256）
ulimit -n 8192 2>/dev/null || ulimit -n 4096 2>/dev/null || true

# 夸克 CDN 只认客户端 UA（普通 Chrome UA 会被 412）
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
REFERER="https://pan.quark.cn/"
CONF_DIR="$HOME/.config/quark-fast"
COOKIE_FILE="$CONF_DIR/cookie.txt"
ARIA_CONF="$CONF_DIR/aria2.conf"
OUT_DIR="$HOME/Downloads/quark"
TEST_SECONDS="${TEST_SECONDS:-8}"
THREADS=512      # 实测：夸克每连接约 10KB/s，512 条约 3.5MB/s（256≈2.2，1024 反而更差）
JOBS=3
ARIA2=""
CURL_CFG=""

c_hdr()  { printf '\033[1;36m%s\033[0m\n' "$*"; }
c_ok()   { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31m%s\033[0m\n' "$*"; }

cleanup() { [ -n "$CURL_CFG" ] && rm -f "$CURL_CFG"; }
trap cleanup EXIT

# ---- 把 Cookie/Referer/UA 写进临时 curl 配置，避免出现在命令行 ----
build_curl_cfg() {
  local ck=""
  [ -f "$COOKIE_FILE" ] && ck=$(tr -d '\r\n' < "$COOKIE_FILE")
  CURL_CFG=$(mktemp "${TMPDIR:-/tmp}/qf-curl.XXXXXX")
  chmod 600 "$CURL_CFG"
  {
    printf 'header = "Referer: %s"\n' "$REFERER"
    printf 'header = "User-Agent: %s"\n' "$UA"
    [ -n "$ck" ] && printf 'header = "Cookie: %s"\n' "$ck"
  } > "$CURL_CFG"
}

# ---- 找 aria2c：PATH → 本工具目录 → Motrix 自带 → Homebrew ----
resolve_aria2() {
  [ -n "$ARIA2" ] && return 0
  local c
  for c in "$(command -v aria2c 2>/dev/null)" \
           "$CONF_DIR/aria2c" \
           /Applications/Motrix.app/Contents/Resources/extra/*/*/aria2c \
           "/Applications/Motrix.app/Contents/Resources/engine/aria2c" \
           "/opt/homebrew/bin/aria2c" "/usr/local/bin/aria2c"; do
    if [ -n "$c" ] && [ -x "$c" ]; then ARIA2="$c"; return 0; fi
  done
  return 1
}

need_aria2() {
  resolve_aria2 && return 0
  c_err "没找到 aria2c。装 Motrix（自带一份）或 brew install aria2"
  exit 1
}

# ---- 取文件大小 ----
size_of() {
  local url="$1" len
  len=$(curl -s -K "$CURL_CFG" --max-time 20 -r 0-0 -D - -o /dev/null "$url" 2>/dev/null \
        | tr -d '\r' | awk 'tolower($1)=="content-range:"{split($2,a,"/"); print a[2]}')
  case "$len" in ''|*[!0-9]*) echo "" ;; *) echo "$len" ;; esac
}

# ---- Range 支持 + 权限 ----
range_code() {
  curl -s -K "$CURL_CFG" --max-time 20 -o /dev/null -w '%{http_code}' \
       -r 0-1023 "$1" 2>/dev/null
}

# ---- 测总吞吐（MB/s）----
measure() {
  local url="$1" conns="$2" secs="${3:-8}" size="${4:-}"
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/qf.XXXXXX")
  local i=1 per start end
  while [ "$i" -le "$conns" ]; do
    if [ -n "$size" ] && [ "$size" -gt 0 ]; then
      per=$(( size / conns ))
      [ "$per" -lt 2097152 ] && per=2097152
      start=$(( (i - 1) * per ))
      end=$(( start + per - 1 ))
      curl -s -o /dev/null --max-time "$secs" -K "$CURL_CFG" \
        -r "${start}-${end}" -w '%{speed_download}\n' "$url" >>"$tmp" 2>/dev/null &
    else
      curl -s -o /dev/null --max-time "$secs" -K "$CURL_CFG" \
        -w '%{speed_download}\n' "$url" >>"$tmp" 2>/dev/null &
    fi
    i=$(( i + 1 ))
  done
  wait
  awk '{s+=$1} END{printf "%.2f", s/1048576}' "$tmp"
  rm -f "$tmp"
}

diagnose() {
  local url="$1"
  build_curl_cfg
  command -v curl >/dev/null || { c_err "系统没有 curl"; exit 1; }

  c_hdr "== 1/4 直链可访问性"
  local code; code=$(range_code "$url")
  case "$code" in
    206) c_ok "  206 Partial Content —— 直链有效，支持分片" ;;
    412|403) c_err "  HTTP $code —— 被拒。夸克直链绑定取链时的 Cookie，必须带同一份 Cookie 才能下。"
             [ -s "$COOKIE_FILE" ] && c_warn "  本地有 cookie.txt 但被拒 → 可能已过期，重跑 python3 quark_dl.py link 取新直链" \
                                   || c_warn "  没有 cookie.txt：先跑 python3 login.py"
             exit 1 ;;
    404) c_err "  404 —— 直链过期了，重新取一条" ; exit 1 ;;
    *)   c_warn "  HTTP $code（非 206，可能不支持分片）" ;;
  esac

  c_hdr "== 2/4 文件信息"
  local size; size=$(size_of "$url")
  if [ -n "$size" ] && [ "$size" -gt 0 ]; then
    printf "  大小: %s\n" "$(awk -v b="$size" 'BEGIN{printf "%.2f GB", b/1073741824}')"
  else
    c_warn "  取不到 Content-Range（不影响下载）"
  fi

  c_hdr "== 3/4 测速（每种 ${TEST_SECONDS}s，不落盘，只耗流量）"
  printf "  单连接 : "
  local s1; s1=$(measure "$url" 1 "$TEST_SECONDS" "$size")
  printf "%8s MB/s\n" "$s1"
  printf "  16 连接: "
  local s16; s16=$(measure "$url" 16 "$TEST_SECONDS" "$size")
  printf "%8s MB/s\n" "$s16"

  c_hdr "== 4/4 结论"
  local ratio
  ratio=$(awk -v a="$s1" -v b="$s16" 'BEGIN{ if(a<=0){print 0}else{printf "%.1f", b/a} }')
  printf "  加速比 = %sx\n" "$ratio"
  if awk -v r="$ratio" 'BEGIN{exit !(r>=3)}'; then
    c_ok "  → 按「连接」限速：多连接有效，直接 16~64 连接跑满。"
    echo "     ./dl.sh -j 16 \"<直链>\" \"文件名\""
  elif awk -v r="$ratio" 'BEGIN{exit !(r>=1.5)}'; then
    c_warn "  → 部分受益：16 连接已接近上限，加线程收益有限。"
    echo "     ./dl.sh -j 16 \"<直链>\" \"文件名\""
  else
    c_err "  → 按「账号/会话」限速：再加线程也没用，这是服务端按账号算的账。"
    echo "     能做的只剩："
    echo "       1) 换时段（0–7 点通常宽松）"
    echo "       2) 同一时间只下 1 个文件，把连接全给它"
    echo "       3) 真要大文件天天搬：开会员比折腾工具省事"
  fi
}

# 构造 aria2 临时配置（带 Cookie，权限 600）
aria_conf_with_cookie() {
  local t="${1:-$THREADS}"
  local out; out=$(mktemp "${TMPDIR:-/tmp}/qf-aria.XXXXXX"); chmod 600 "$out"
  if [ -f "$ARIA_CONF" ]; then
    grep -viE '^\s*(header|referer|user-agent)\s*=' "$ARIA_CONF" >> "$out" 2>/dev/null
  else
    cat >> "$out" <<'EOF'
continue=true
file-allocation=none
max-tries=0
retry-wait=10
summary-interval=5
console-log-level=warn
download-result=hide
EOF
  fi
  {
    echo "dir=$OUT_DIR"
    echo "split=$t"
    echo "max-connection-per-server=$t"
    echo "min-split-size=1M"
    echo "header=Referer: $REFERER"
    echo "header=User-Agent: $UA"
    [ -s "$COOKIE_FILE" ] && echo "header=Cookie: $(tr -d '\r\n' < "$COOKIE_FILE")"
  } >> "$out"
  echo "$out"
}

dl_one() {
  local url="$1" threads="$2" name="${3:-}"
  need_aria2
  mkdir -p "$OUT_DIR"
  local conf; conf=$(aria_conf_with_cookie)
  local args=(--conf-path="$conf")
  [ -n "$name" ] && args+=(-o "$name")
  c_hdr "== 下载（${threads} 连接）→ $OUT_DIR"
  c_dim_engine
  "$ARIA2" "${args[@]}" "$url"
  local rc=$?
  rm -f "$conf"
  [ $rc -eq 0 ] && c_ok "✓ 完成" || c_warn "aria2 退出码 $rc（直链过期就重取，会续传）"
  return $rc
}

c_dim_engine() { printf '\033[1;2m  引擎: %s\033[0m\n' "$ARIA2"; }

dl_batch() {
  local list="$1" threads="$2"
  need_aria2
  mkdir -p "$OUT_DIR"
  local conf; conf=$(aria_conf_with_cookie "$threads")
  c_hdr "== 批量（每文件 ${threads} 连接，同时 ${JOBS} 个）"
  "$ARIA2" --conf-path="$conf" -i "$list" -j "$JOBS"
  local rc=$?
  rm -f "$conf"
  return $rc
}

show_conf() {
  c_hdr "== 配置"
  if resolve_aria2; then
    echo "  aria2   : $ARIA2"
    echo "            $("$ARIA2" --version 2>/dev/null | head -1)"
  else
    echo "  aria2   : 未找到"
  fi
  echo "  conf    : $ARIA_CONF"
  echo "  输出    : $OUT_DIR"
  echo -n "  Cookie  : "
  if [ -s "$COOKIE_FILE" ]; then echo "已就绪（$(wc -c < "$COOKIE_FILE" | tr -d ' ') 字节）"; else echo "缺失"; fi
  echo "  线程    : 默认 $THREADS，批量并发 $JOBS"
  echo "  磁盘    : $(df -h "$HOME" | tail -1 | awk '{print $4" 可用 / "$2}')"
}

usage() { sed -n '3,14p' "$0" | sed 's/^#  \{0,1\}//'; }

MODE="dl"; NAME=""; FILE=""
while getopts "tj:o:f:sh" opt; do
  case "$opt" in
    t) MODE="test" ;;
    j) THREADS="$OPTARG" ;;
    o) NAME="$OPTARG" ;;
    f) MODE="batch"; FILE="$OPTARG" ;;
    s) MODE="conf" ;;
    h|*) usage; exit 0 ;;
  esac
done
shift $((OPTIND - 1))

case "$MODE" in
  conf)  show_conf ;;
  test)  [ $# -ge 1 ] || { usage; exit 1; }; diagnose "$1" ;;
  batch) [ -n "$FILE" ] || { usage; exit 1; }; dl_batch "$FILE" "$THREADS" ;;
  dl)    [ $# -ge 1 ] || { usage; exit 1; }; dl_one "$1" "$THREADS" "${NAME:-${2:-}}" ;;
esac
