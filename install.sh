#!/bin/bash
# 把 SimpleFly.app 装到当前用户自己家的输入法目录（不需要 sudo）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/build/SimpleFly.app"
DEST_DIR="$HOME/Library/Input Methods"
DEST="$DEST_DIR/SimpleFly.app"

if [ ! -d "$SRC" ]; then
  echo "找不到 $SRC，先跑 ./build.sh" >&2
  exit 1
fi

# 二进制新鲜度自检：src/ 或 resources/ 里只要有比 app 主二进制新的文件，
# 说明改完代码没有重新 build —— 装下去也是旧功能（0.5.5 踩过：--test 只编译测试
# 二进制不重建 app，版本号没动导致 14=14 的自检照样通过，真机跑的还是旧逻辑）。
echo "==> 二进制新鲜度自检"
BIN="$SRC/Contents/MacOS/SimpleFly"
STALE=$(find "$ROOT/src" "$ROOT/resources" -type f -newer "$BIN" 2>/dev/null | head -5 || true)
if [ -n "$STALE" ]; then
  echo "    ✗ 以下源文件比 build/SimpleFly.app 新，先跑 ./build.sh 再 install：" >&2
  echo "$STALE" | sed 's/^/      /' >&2
  exit 1
fi
echo "    无过期源文件  ✓"

echo "==> 停掉正在运行的旧进程"
pkill -x SimpleFly 2>/dev/null || true
sleep 0.5

mkdir -p "$DEST_DIR"

# 只删自己这一个 bundle，且路径必须落在 ~/Library/Input Methods 下
if [ -d "$DEST" ]; then
  case "$DEST" in
    "$HOME/Library/Input Methods/SimpleFly.app") rm -rf "$DEST" ;;
    *) echo "路径检查未通过，已中止：$DEST" >&2; exit 1 ;;
  esac
fi

echo "==> 复制到 $DEST"
cp -R "$SRC" "$DEST"
codesign --force --sign - "$DEST" >/dev/null 2>&1 || echo "   (重新签名失败，通常不影响本机使用)"

# 构建版本 vs 安装版本自检。
# 0.5.0 踩过一次：改完功能只 build 没 install，真机表现是「新功能完全没反应」，
# 而排查方向会被引到「逻辑写错了」。把核对写成 install.sh 的一步，比让人记住更可靠。
echo "==> 版本一致性自检"
SRC_VER=$(plutil -extract CFBundleVersion raw "$SRC/Contents/Info.plist" 2>/dev/null || echo "?")
DST_VER=$(plutil -extract CFBundleVersion raw "$DEST/Contents/Info.plist" 2>/dev/null || echo "?")
if [ "$SRC_VER" = "$DST_VER" ] && [ "$SRC_VER" != "?" ]; then
  echo "    构建 $SRC_VER = 安装 $DST_VER  ✓"
else
  echo "    ✗ 不一致：构建 $SRC_VER / 安装 $DST_VER —— 复制没生效，别急着去查逻辑" >&2
  exit 1
fi
echo

echo "安装完成：$DEST"
echo
echo "接下来两步："
echo "  1) 注销并重新登录（输入法列表只在登录时刷新）"
echo "  2) 系统设置 › 键盘 › 输入法 › 编辑… › + › 中文（简体） › 选中 SimpleFly"
echo
echo "想换码表（不重新构建 app）就把码表放到："
echo "  ~/Library/Application Support/SimpleFly/simplefly.dict"
echo "然后 killall SimpleFly，切走再切回本输入法即可重新加载。"
