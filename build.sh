#!/bin/bash
# 构建 SimpleFly.app —— 只用 Command Line Tools 里的 clang，不需要 Xcode 工程。
#
#   ./build.sh            构建 app
#   ./build.sh --test     构建并跑全部单测（引擎 / 标点 / 控制器），不产出 app
#   ./build.sh --symbols  从码表生成 docs/符号速查.md（快符 / 特殊符号 / emoji）
#   ./build.sh --preview  离线渲染各主题候选窗拼图，改配色后先看效果
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/SimpleFly.app"
SDK="$(xcrun --show-sdk-path)"
# 默认 11.0；老版 Command Line Tools（clang < 12 不认识 11.0）可外部覆盖：
#   SIMPLEFLY_MIN_MACOS=10.15 ./build.sh
MIN_MACOS="${SIMPLEFLY_MIN_MACOS:-11.0}"
DICT="$ROOT/resources/simplefly.dict"

# 本仓库不含码表（版权归小鹤官方，见 NOTICE）。优先用 resources/ 下自己生成的那份，
# 没有就回退到运行时目录 —— 这样「仓库干净」和「本地能跑测试」可以同时成立。
if [ ! -f "$DICT" ]; then
    _user_dict="$HOME/Library/Application Support/SimpleFly/simplefly.dict"
    if [ -f "$_user_dict" ]; then
        DICT="$_user_dict"
    fi
    unset _user_dict
fi

CFLAGS=(-O2 -Wall -Wextra -Wno-unused-command-line-argument
        -isysroot "$SDK" -mmacosx-version-min="$MIN_MACOS")

# 交叉架构：默认跟随本机（M 系列 → arm64、Intel → x86_64），指定时才加 -arch。
# 只在一种场景用到：
#   SIMPLEFLY_ARCH=x86_64 ./build.sh --test   在 M 系列机上预演「移植到 Intel」
#                                             （Rosetta 下跑同一套单测，验证 x86 语义）
# 实测 346 项全通过。产物不能直接跨机器安装 —— arm64 二进制在 Intel 上加载不了，
# 换机器只能拷源码重编译（详见 用户手册.md §九）。
#
# 注意：这里必须判空后再前置展开，不能写 "${ARR[@]}"。
# macOS 自带 bash 是 3.2，在 `set -u` 下展开空数组会报 unbound variable（踩过）。
if [ -n "${SIMPLEFLY_ARCH:-}" ]; then
  CFLAGS=(-arch "$SIMPLEFLY_ARCH" "${CFLAGS[@]}")
fi

build_app() {
  echo "==> SDK: $SDK"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

  echo "==> 编译（ObjC + C，ARC）"
  clang -fobjc-arc "${CFLAGS[@]}" \
        -framework Cocoa -framework InputMethodKit \
        "$ROOT"/src/*.m "$ROOT"/src/*.c \
        -o "$APP/Contents/MacOS/SimpleFly"

  echo "==> 组装 bundle"
  cp "$ROOT/resources/Info.plist" "$APP/Contents/Info.plist"

  # 图标。三个产出，用途完全不同：
  #
  #   SimpleFly.pdf   22x16 pt 矢量 PDF —— 菜单栏图标（0.5.0 及以前也是列表图标）。
  #     必须是 **PDF 且页面尺寸 = 22x16 pt**（与鼠须管 rime.pdf 一致）：系统的输入法图标按
  #     PDF 页面尺寸当逻辑尺寸用，不按像素 —— 早先用 128x128、72dpi 的 TIFF，
  #     被理解成 128 pt 见方，在输入法菜单里就是「图标太大」。
  #     而且它会被**当模板图渲染**（系统只看 alpha、自己涂成单色），所以底板必须配
  #     **挖空**的字形；实心白字会被涂成一整块纯黑方块，字全没了。详见 tools/make_icon.m 头部。
  #
  #   SimpleFly.tiff  16x16@72dpi + 32x32 双帧 TIFF —— **模式图标（0.5.1 起）**，
  #     Info.plist 三个 tsInputMode*IconFileKey 指向它。0.5.0 及以前的 22x16pt PDF 在 macOS 26 的
  #     「系统设置 › 键盘 › 输入法」列表不被采用（实测回退 .icns 的 16x16 表示，
  #     徽标只有 26x26 px）；解剖 SCIM.app 的 pinyin.tiff 得到 Apple 自家规格
  #     （双帧 TIFF、黑墨挖空底板），同一列表里「拼」徽标即此格式、显示正常。
  #
  #   SimpleFly.icns  macOS 应用图标 —— Finder / 系统设置里那个方块。
  #     **同样必须挖空**（0.4.1 修）：系统设置的输入源列表、输入法切换菜单都会把
  #     应用图标当模板图渲染（只看 alpha），不挖空就是一整块纯色方块。
  #     Info.plist 用 CFBundleIconFile + CFBundleIconName 指向它。
  #
  # （TIS 把「每个 input mode 要有图标」列在必需项里，缺了可能静默不注册 —— Apple TN2128。）
  ICON="$ROOT/resources/SimpleFly.pdf"
  ICNS="$ROOT/resources/SimpleFly.icns"
  TIFF="$ROOT/resources/SimpleFly.tiff"
  if [ ! -f "$ICON" ] || [ ! -f "$ICNS" ] || [ ! -f "$TIFF" ] || \
     [ "$ROOT/tools/make_icon.m" -nt "$ICON" ] || [ "$ROOT/tools/make_icon.m" -nt "$TIFF" ]; then
    echo "    生成图标（22x16 pt PDF + 16/32 双帧 TIFF + icns）"
    clang -fobjc-arc "${CFLAGS[@]}" \
          -framework Foundation -framework CoreGraphics -framework CoreText -framework ImageIO \
          "$ROOT/tools/make_icon.m" -o "$ROOT/build/make_icon"
    "$ROOT/build/make_icon" -o "$ICON" --icns "$ICNS" --tiff "$TIFF" | sed 's/^/      /'
  fi
  cp "$ICON" "$APP/Contents/Resources/SimpleFly.pdf"
  cp "$ICNS" "$APP/Contents/Resources/SimpleFly.icns"
  cp "$TIFF" "$APP/Contents/Resources/SimpleFly.tiff"

  # 本地化显示名：输入法菜单里显示的名字来自各 lproj 的 InfoPlist.strings
  for LP in "$ROOT"/resources/*.lproj; do
    [ -d "$LP" ] || continue
    cp -R "$LP" "$APP/Contents/Resources/"
    echo "    本地化: $(basename "$LP")"
  done

  if [ -f "$DICT" ]; then
    cp "$DICT" "$APP/Contents/Resources/simplefly.dict"
    echo "    码表: $(wc -l < "$DICT" | tr -d ' ') 行"
  else
    echo "    ! 缺少 ${DICT}，先跑: python3 tools/build_dict.py <rime-flypy 的 flypy 目录>" >&2
  fi
  if [ -f "$ROOT/resources/s2t.tsv" ]; then
    cp "$ROOT/resources/s2t.tsv" "$APP/Contents/Resources/s2t.tsv"
    echo "    简→繁: $(grep -c -v '^#' "$ROOT/resources/s2t.tsv") 对"
  else
    echo "    ! 缺少 s2t.tsv，先跑: python3 tools/gen_s2t.py" >&2
  fi
  if [ -f "$ROOT/resources/t2s.tsv" ]; then
    cp "$ROOT/resources/t2s.tsv" "$APP/Contents/Resources/t2s.tsv"
    echo "    繁→简: $(grep -c -v '^#' "$ROOT/resources/t2s.tsv") 对"
  else
    echo "    ! 缺少 t2s.tsv，先跑: python3 tools/gen_t2s.py" >&2
  fi

  echo "==> ad-hoc 签名（本机自用，不做 Developer ID / 公证）"
  codesign --force --sign - "$APP"

  echo "==> 校验"
  plutil -lint "$APP/Contents/Info.plist"
  codesign --verify --verbose=1 "$APP" 2>&1 | tail -2
  echo
  echo "构建完成：$APP"
  echo "下一步：./install.sh"
}

# ---------------------------------------------------------------- 单测
#
# 各套测试的分工：
#   engine_test      纯 C 引擎：前缀查询 + 上屏策略 + 查表性能
#   reverse_test     纯 C 引擎反查：词条 -> 编码（「查编码」功能的地基）
#   punct_test       纯 C 标点表：逐条对照 Rime punctuation.yaml
#   pinyin_test      纯 C 全拼 -> 小鹤双拼键位表
#   phrase_test      纯 C 自定义快捷输入表（含前缀查询与热重载判断）
#   controller_test  控制器按键路由：假客户端 + 合成 NSEvent，断言「最终上屏了什么」
#
# 最后一套是关键 —— 输入法在真机上只能靠手打验证，某个分支写错的表现是
# 「某个键没反应」，极难定位。有了它，按键路由可以像普通代码一样回归。

run_tests() {
  mkdir -p "$ROOT/build"
  local fail=0

  # 本仓库不含码表（版权归小鹤官方，见 README §6）。clone 之后没码表是常态，
  # 依赖码表的套件要「明确跳过」而不是报一堆莫名的失败 —— 更不能因为 cp 一个
  # 不存在的文件被 set -e 打断，那样连后面不依赖码表的套件都跑不到了。
  local have_dict=1
  if [ ! -f "$DICT" ]; then
    have_dict=0
    echo "==> 注意：没有码表（${DICT}），依赖码表的套件将跳过 —— 见 README §6 获取方式" >&2
  fi

  echo "==> [1/8] 引擎单测（纯 C）"
  if [ "$have_dict" -eq 1 ]; then
    clang "${CFLAGS[@]}" "$ROOT/src/engine.c" "$ROOT/tools/engine_test.c" \
          -o "$ROOT/build/engine_test"
    "$ROOT/build/engine_test" "$DICT" --selftest && echo "    ✓ 通过" || fail=1
  else
    echo "    – 跳过（无码表）"
  fi

  echo
  echo "==> [2/8] 引擎反查单测（纯 C）"
  if [ "$have_dict" -eq 1 ]; then
    clang "${CFLAGS[@]}" -I "$ROOT/src" "$ROOT/src/engine.c" "$ROOT/tools/reverse_test.c" \
          -o "$ROOT/build/reverse_test"
    "$ROOT/build/reverse_test" "$DICT" && echo "    ✓ 通过" || fail=1
  else
    echo "    – 跳过（无码表）"
  fi

  echo
  echo "==> [3/8] 标点单测（纯 C）"
  clang "${CFLAGS[@]}" "$ROOT/src/punctuation.c" "$ROOT/tools/punct_test.c" \
        -o "$ROOT/build/punct_test"
  "$ROOT/build/punct_test" && echo "    ✓ 通过" || fail=1

  echo
  echo "==> [4/8] 拼音键位表单测（纯 C）"
  clang "${CFLAGS[@]}" -I "$ROOT/src" "$ROOT/src/pinyin.c" "$ROOT/tools/pinyin_test.c" \
        -o "$ROOT/build/pinyin_test"
  "$ROOT/build/pinyin_test" && echo "    ✓ 通过" || fail=1

  echo
  echo "==> [5/8] 自定义快捷输入表单测（纯 C）"
  clang "${CFLAGS[@]}" -I "$ROOT/src" "$ROOT/src/phrase.c" "$ROOT/tools/phrase_test.c" \
        -o "$ROOT/build/phrase_test"
  "$ROOT/build/phrase_test" && echo "    ✓ 通过" || fail=1

  echo
  echo "==> [6/8] 控制器按键路由单测"
  # 这里要排除 src/main.m（它自带 main()），所以不能图省事写 src/*.m；.c 也逐个列
  clang -fobjc-arc "${CFLAGS[@]}" -I "$ROOT/src" \
        -framework Cocoa -framework InputMethodKit \
        "$ROOT/src/SFInputController.m" "$ROOT/src/SFCandidatePanel.m" \
        "$ROOT/src/SFCandidateTheme.m" \
        "$ROOT/src/engine.c" "$ROOT/src/punctuation.c" \
        "$ROOT/src/pinyin.c" "$ROOT/src/phrase.c" "$ROOT/src/freq.c" "$ROOT/src/s2t.c" \
        "$ROOT/tools/controller_test.m" -o "$ROOT/build/controller_test"
  # 测试二进制从自己旁边读码表（SFSharedEngine 找不到 bundle 资源时的兜底路径）。
  # 缺码表时必须把上一次残留的旧表删掉 —— 留着会让 controller_test 以为有表，
  # 「缺表」这条分支就永远测不到。
  if [ "$have_dict" -eq 1 ]; then cp "$DICT" "$ROOT/build/simplefly.dict"
  else rm -f "$ROOT/build/simplefly.dict"; fi
  cp "$ROOT/resources/s2t.tsv" "$ROOT/build/s2t.tsv"
  cp "$ROOT/resources/t2s.tsv" "$ROOT/build/t2s.tsv"
  # 注意：这里不能用 `cmd; rc=$?` —— set -e 会在 cmd 返回非 0 时立刻退出脚本，
  # 根本走不到下一行（controller_test 缺表时返回 2）。必须走 `|| rc=$?` 吃掉退出码。
  local rc=0
  ( cd "$ROOT/build" && ./controller_test ) || rc=$?
  if   [ "$rc" -eq 2 ]; then echo "    – 无码表：只跑了缺表守卫用例（不吞键 / 不上屏 / 有提示）"
  elif [ "$rc" -ne 0 ]; then fail=1
  else echo "    ✓ 通过"; fi

  echo
  echo "==> [7/8] 重码记忆单测（纯 C）"
  clang "${CFLAGS[@]}" -I "$ROOT/src" "$ROOT/src/freq.c" "$ROOT/tools/freq_test.c" \
        -o "$ROOT/build/freq_test"
  "$ROOT/build/freq_test" && echo "    ✓ 通过" || fail=1

  echo
  echo "==> [8/8] 简繁转换单测（纯 C，双向两张表）"
  clang "${CFLAGS[@]}" -I "$ROOT/src" "$ROOT/src/s2t.c" "$ROOT/tools/s2t_test.c" \
        -o "$ROOT/build/s2t_test"
  ( cd "$ROOT/build" && ./s2t_test s2t.tsv t2s.tsv ) && echo "    ✓ 通过" || fail=1

  echo
  if [ "$fail" -eq 0 ]; then echo "全部单测通过"; else echo "有单测失败" >&2; fi
  return "$fail"
}

case "${1:-}" in
  --test|test) run_tests ;;
  --icon|icon)
    # 只重做图标（改了 make_icon.m 或想换字 / 换底色时用）
    clang -fobjc-arc "${CFLAGS[@]}" \
          -framework Foundation -framework CoreGraphics -framework CoreText -framework ImageIO \
          "$ROOT/tools/make_icon.m" -o "$ROOT/build/make_icon"
    "$ROOT/build/make_icon" -o "$ROOT/resources/SimpleFly.pdf" \
                            --icns "$ROOT/resources/SimpleFly.icns" \
                            --tiff "$ROOT/resources/SimpleFly.tiff"
    echo
    echo "想先看效果：build/tile <输出.png> resources/SimpleFly.pdf:标题"
    ;;
  --symbols|symbols)
    # 从码表抽出「非汉字」内容，生成 docs/符号速查.md。
    # 码表里其实塞了快符 / of 特殊符号 / emoji / 微信表情名四类能被直接打出来的东西，
    # 但码表本身没有任何说明，用户不知道它们存在。换码表后重跑一次即可。
    python3 "$ROOT/tools/gen_symbols.py"
    ;;
  --suggest|suggest)
    # 从打错日志（mislog.tsv）生成短语建议。日志要先把 LogMisses 开关打开才会产生。
    python3 "$ROOT/tools/suggest_phrases.py" "$@"
    ;;
  --preview|preview)
    # 离线渲染各主题的候选窗拼图（改配色后先看效果，不用注销重登）
    clang -fobjc-arc "${CFLAGS[@]}" -I "$ROOT/src" -framework Cocoa \
          "$ROOT/src/SFCandidatePanel.m" "$ROOT/src/SFCandidateTheme.m" \
          "$ROOT/tools/theme_preview.m" -o "$ROOT/build/theme_preview"
    ( cd "$ROOT/build" && ./theme_preview )   # 默认输出 docs/主题预览.png
    ;;
  *)           build_app ;;
esac
