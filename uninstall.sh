#!/usr/bin/env bash
# 彻底卸载 QuarkFast（下载的文件保留）
set -u
echo "→ 删除 App"
rm -rf /Applications/QuarkFast.app
echo "→ 删除登录态与配置"
rm -rf "$HOME/.config/quark-fast"
echo "→ 删除日志"
rm -f "$HOME/Library/Logs/QuarkFast.log"
echo
echo "✓ 卸载完成。"
echo "  下载目录 ~/Downloads/quark 未动（要清就自己删）。"
