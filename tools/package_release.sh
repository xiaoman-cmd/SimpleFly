#!/bin/bash
# 打包 SimpleFly 发布产物（供「预编译模式」自更新下载）。
#
# 产出：仓库根目录下的 SimpleFly.app.zip —— 一个已签名、内嵌 tis_register 与
# self_update.sh 的 SimpleFly.app。把它作为 asset 名「SimpleFly.app.zip」上传到
# GitHub Release（tag 建议与 Info.plist 的 CFBundleShortVersionString 一致，例如
# 0.7.1），自更新器才能正确比较版本并下载。
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

echo "==> 打 zip（asset 名须为 SimpleFly.app.zip）"
cd build
rm -f ../SimpleFly.app.zip
zip -r -q ../SimpleFly.app.zip SimpleFly.app
cd ..

# 注意：必须用绝对路径。defaults read 只认绝对路径，相对路径会报
# “domain/default pair ... does not exist”而失败；配合 set -e 会直接中断脚本。
VER="$(plutil -extract CFBundleShortVersionString raw "$ROOT/$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
VER="${VER:-?}"
echo
echo "已生成：$(pwd)/SimpleFly.app.zip  （版本 v${VER}）"
echo "上传到 GitHub Release，asset 名务必为 SimpleFly.app.zip；tag 建议用 ${VER}。"
