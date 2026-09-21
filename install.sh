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
# 用户手册也算：它会被 build.sh 拷进 bundle，改了手册没重构建的话，菜单「用户手册」
# 打开的还是上一版正文（比「改了代码没 build」更难察觉，一并纳入判据）。
STALE=$(find "$ROOT/src" "$ROOT/resources" "$ROOT/用户手册.md" -type f -newer "$BIN" 2>/dev/null | head -5 || true)
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
    "$HOME/Library/Input Methods/SimpleFly.app") ;;
    *) echo "路径检查未通过，已中止：$DEST" >&2; exit 1 ;;
  esac
fi

# 先在暂存目录里签好名、验过，再整体换上去 —— 不要「先拷到 $DEST 再原地签名」。
#
# 0.7.1 踩过：原地签名写出来的封条和磁盘内容对不上，codesign -v 报
# “invalid resource directory (directory or signature have been modified)”。
# 原因是 TIS 只要发现这个输入法被选中（系统记住的选择不会因为 pkill 而消失），
# 就会立刻把刚落地的 bundle 拉起来执行；而 codesign 是「先把主二进制拷成
# xxx.cstemp、改完再挪回去」的原地操作，对着一个正在被执行的 bundle 干这事，
# 封条必然对不上。改成暂存区签名后 rename 换上去，落地的瞬间签名就是有效的。
STAGE="$DEST_DIR/.SimpleFly.app.stage"
echo "==> 复制到暂存目录并签名"
# 残留的暂存副本**挪走**而不是 `rm -rf`：少一次批量删除动作，也留得下现场
# （上一轮为什么没装成，翻那份残骸最快）。挪到 Caches，**不要**留在
# ~/Library/Input Methods/ —— 那个目录会被 TIS 当输入法扫描，堆 .app 会污染输入源列表。
BAK_DIR="$HOME/Library/Caches/SimpleFly"
mkdir -p "$BAK_DIR"
if [ -d "$STAGE" ]; then
  mv "$STAGE" "$BAK_DIR/stale-stage-$(date +%Y%m%d-%H%M%S)"
fi
cp -R "$SRC" "$STAGE"
codesign --force --sign - "$STAGE" >/dev/null 2>&1
# 判据用 codesign 自己的退出码，**不要**写 `codesign --verify ... | grep -q`：
# 在 `set -o pipefail` 下 grep -q 命中即退出，codesign 后续的写入会吃到 SIGPIPE
# 而非零退出，于是「签名有效」反被判成失败（0.7.1 正好踩到）。
if codesign --verify "$STAGE" >/dev/null 2>&1; then
  echo "    签名有效  ✓"
else
  echo "    ✗ 暂存副本签名校验未通过，已中止（$DEST 未被改动）" >&2
  codesign --verify --verbose=2 "$STAGE" >&2 || true
  mv "$STAGE" "$BAK_DIR/failed-stage-$(date +%Y%m%d-%H%M%S)"
  exit 1
fi

echo "==> 替换到 $DEST"
# 旧版本**改名挪走**当回滚副本，再把暂存副本 rename 上去 —— 不再 `rm -rf`。
# 两个理由：① rename 是原子操作，不存在「旧版已删、新版还没拷进去」的空窗；
# ② 旧版留在手边，装上新版发现不对可以立刻换回来。
# 备份放 Caches 不放 Input Methods（后者会被 TIS 扫描），带版本号命名，不覆盖上一份。
if [ -d "$DEST" ]; then
  OLD_VER=$(plutil -extract CFBundleShortVersionString raw "$DEST/Contents/Info.plist" 2>/dev/null || echo "unknown")
  OLD_BLD=$(plutil -extract CFBundleVersion raw "$DEST/Contents/Info.plist" 2>/dev/null || echo "0")
  OLD_BAK="$BAK_DIR/SimpleFly-$OLD_VER-$OLD_BLD.app.bak"
  mv "$DEST" "$OLD_BAK"
  echo "    旧版已备份：$OLD_BAK"
fi
mv "$STAGE" "$DEST"

echo "==> 签名复核"
if codesign --verify "$DEST" >/dev/null 2>&1; then
  echo "    $DEST 签名有效  ✓"
else
  echo "    ⚠ 签名校验未通过（ad-hoc 自签，通常不影响本机使用）：" >&2
  codesign --verify --verbose=2 "$DEST" >&2 || true
fi

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
