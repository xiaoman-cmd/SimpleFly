#!/bin/bash
# 打包 SimpleFly 发布产物（供「预编译模式」自更新下载）。
#
# 产出：仓库根目录下的 SimpleFly.app.zip —— 一个已签名、内嵌 tis_register 与
# self_update.sh 的 SimpleFly.app。把它作为 asset 名「SimpleFly.app.zip」上传到
# GitHub Release（tag 建议与 Info.plist 的 CFBundleShortVersionString 一致，例如
# 0.7.2），自更新器才能正确比较版本并下载。
#
# 需要：本机已装 Xcode Command Line Tools（clang / xcrun / zip / codesign）。
# 普通用户不需要这些——他们只下载上面那个 zip。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 与 build.sh / self_update.sh 一致的部署目标回退：clang < 12 不认识 11.0。
CLANG_VER="$(clang --version 2>/dev/null | sed -n 's/.*clang version \([0-9]*\).*/\1/p')"
if [ -n "$CLANG_VER" ] && [ "$CLANG_VER" -lt 12 ]; then
  export SIMPLEFLY_MIN_MACOS="${SIMPLEFLY_MIN_MACOS:-10.15}"
else
  export SIMPLEFLY_MIN_MACOS="${SIMPLEFLY_MIN_MACOS:-11.0}"
fi

echo "==> 构建 app（SIMPLEFLY_MIN_MACOS=${SIMPLEFLY_MIN_MACOS}）"
./build.sh

APP="build/SimpleFly.app"

# 内嵌 tis_register：预编译模式免登刷新用，避免终端用户依赖 Xcode CLT。
echo "==> 编译并内嵌 tis_register → $APP/Contents/Resources/tis_register"
clang -O2 -isysroot "$(xcrun --show-sdk-path)" \
      tools/tis_register.c -o "$APP/Contents/Resources/tis_register" -framework Carbon
chmod +x "$APP/Contents/Resources/tis_register" \
         "$APP/Contents/Resources/self_update.sh"

# 必须重签名：build.sh 的签名发生在内嵌 tis_register 之前，嵌完不改签的话资源封条对不上
# （codesign -v 报 "a sealed resource is missing or invalid / file added: tis_register"），
# 发出去的 zip 里就是个签名无效的 app —— 0.7.0 / 0.7.1 都踩过这个坑。
echo "==> 重新签名（内嵌 tis_register 破坏了 build.sh 的封条）"
codesign --force --sign - "$APP" >/dev/null 2>&1
# 判据用退出码，别写 `codesign --verify ... | grep -q`：pipefail 下 grep -q 提前退出
# 会让 codesign 吃 SIGPIPE 而非零退出，把「签名有效」误判成失败。
if codesign --verify "$APP" >/dev/null 2>&1; then
  echo "    签名有效  ✓"
else
  echo "    ✗ 签名校验未通过，别发这个包：" >&2
  codesign --verify --verbose=2 "$APP" >&2 || true
  exit 1
fi

echo "==> 打 zip（asset 名须为 SimpleFly.app.zip）"
cd build
rm -f ../SimpleFly.app.zip
zip -r -q ../SimpleFly.app.zip SimpleFly.app
cd ..

# 解出来再验一遍：确认 zip 没有把签名（Mach-O 内嵌签名 + _CodeSignature 目录）弄坏。
# 用户下载到的就是解压后的这份，所以这一步才算真正替用户验过。
echo "==> 复核 zip 内 app 的签名"
ZTMP="$(mktemp -d)"
ditto -x -k SimpleFly.app.zip "$ZTMP"
if codesign --verify "$ZTMP/SimpleFly.app" >/dev/null 2>&1; then
  echo "    签名有效  ✓"
else
  echo "    ✗ zip 内 app 签名无效，别发这个包：" >&2
  codesign --verify --verbose=2 "$ZTMP/SimpleFly.app" >&2 || true
  rm -rf "$ZTMP"
  exit 1
fi
rm -rf "$ZTMP"

# 注意：必须用绝对路径。defaults read 只认绝对路径，相对路径会报
# “domain/default pair ... does not exist”而失败；配合 set -e 会直接中断脚本。
VER="$(plutil -extract CFBundleShortVersionString raw "$ROOT/$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
VER="${VER:-?}"
echo
echo "已生成：$(pwd)/SimpleFly.app.zip  （版本 v${VER}）"
echo "上传到 GitHub Release，asset 名务必为 SimpleFly.app.zip；tag 建议用 ${VER}。"
