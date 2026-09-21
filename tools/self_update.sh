#!/bin/bash
# SimpleFly 自更新器（由输入法菜单「更新到最新版」以分离进程方式调用）。
#
# 两种模式，自动选择：
#   A) 源码模式（开发者）：当 $REPO/.git 存在且含 build.sh 时，
#      git fetch + merge --ff-only → build.sh → install.sh → 免登刷新。
#      需要本机已装 git 与 Xcode Command Line Tools（clang）。
#   B) 预编译模式（普通用户）：无本地仓库时，从 GitHub Release 下载打包好的
#      SimpleFly.app.zip，解压即装。只需 macOS 自带的 curl / ditto / xattr，
#      无需 git，也无需 Xcode Command Line Tools。
#
# 安全约束（务必遵守）：
#   1. 绝不删除 ~/Library/Application Support/SimpleFly（用户配置：phrase.txt /
#      simplefly.dict / webdav.conf / freq.txt），也绝不 defaults delete。
#      只做一份「时间戳备份」供极端情况回滚，从不自动清理。
#   2. 源码模式 git 默认 --ff-only：本地与远程分叉（非快进）直接报错退出，
#      绝不静默丢弃工作；工作树有未提交改动时先 stash、拉取后 stash pop。
#   3. HTTPS 匿名拉取公共仓库 / 下载公共 Release，避免依赖 SSH agent。
#   4. 构建/安装复用仓库自带 build.sh / install.sh；install.sh 末尾的
#      pkill -x SimpleFly 会杀掉旧输入法进程——本脚本由输入法以 NSTask 启动、
#      是独立的 zsh 进程（进程名不是 SimpleFly），不会被一起带走。
#   5. 安装后用 tis_register --enable 免登刷新（重注册并启用，免去注销重登）。
#      预编译模式用 bundle 内嵌的 tis_register（由 package_release.sh 在打包时
#      编译嵌入到 Contents/Resources/）；源码模式回退到现场用 clang 编译。
#
# 用法（Objective-C 端拼好参数调用）：
#   self_update.sh <本地仓库路径> <远程 HTTPS URL> [<预编译下载 URL>]
#   仓库路径与远程 URL 在预编译模式下可省略/任意（脚本不使用）。
#
# 注意：本脚本由输入法以 /bin/zsh 启动（见 SFInputController.m），也可能被
# 直接以 bash 运行。两者都要兼容，故下面用 set -u + set -o pipefail 而非组合短选项。

# 自拷贝到临时文件再 exec：更新器自身位于 $DEST/Contents/Resources/self_update.sh，
# 而下面的安装步骤会 rm -rf $DEST（删掉旧 bundle）。若不脱离，shell 读到一半会因
# 源文件被删而 EOF 中断（两种模式都会 rm -rf，故必须做）。拷到 /tmp 后 exec 替换进程，
# 之后删 bundle 不影响正在执行的这份副本。
if [ -z "${_SF_SELF_COPIED:-}" ]; then
  _SF_TMP="$(mktemp -t simplefly_update.XXXXXX.sh)"
  cp "$0" "$_SF_TMP" && chmod +x "$_SF_TMP" && exec env _SF_SELF_COPIED=1 /bin/zsh "$_SF_TMP" "$@"
  echo "自拷贝失败，无法安全更新" >&2
  exit 1
fi
trap 'rm -f "$_SF_TMP" 2>/dev/null' EXIT

set -u
set -o pipefail

REPO="${1:-}"
REMOTE="${2:-https://github.com/xiaoman-cmd/SimpleFly.git}"
RELEASE_URL="${3:-https://github.com/xiaoman-cmd/SimpleFly/releases/latest/download/SimpleFly.app.zip}"
API_URL="https://api.github.com/repos/xiaoman-cmd/SimpleFly/releases/latest"

DEST="$HOME/Library/Input Methods/SimpleFly.app"
ASD="$HOME/Library/Application Support/SimpleFly"
LOG="/tmp/simplefly_update.log"

log()    { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
notify() { osascript -e "display notification \"$2\" with title \"SimpleFly 更新\" subtitle \"$1\"" 2>/dev/null || true; }
fail()   { log "失败：$1"; notify "更新失败" "$1"; exit 1; }

# ---- 0. 用户配置备份（只备份，不删除） ----
if [ -d "$ASD" ]; then
  BAK="$ASD.bak-$(date '+%Y%m%d-%H%M%S')"
  cp -R "$ASD" "$BAK" && log "已备份用户配置 → $BAK" || log "备份失败（继续，不影响更新）"
fi

# ---- 模式选择 ----
if [ -n "$REPO" ] && [ -d "$REPO/.git" ] && [ -f "$REPO/build.sh" ]; then
  MODE=source
else
  MODE=release
fi
log "更新模式：$MODE"

if [ "$MODE" = source ]; then
  # ============================ 源码模式 ============================
  REPO="$(cd "$REPO" 2>/dev/null && pwd)" || fail "本地仓库路径不存在：$REPO"
  cd "$REPO" || fail "无法进入仓库目录：$REPO"

  # 工作树有改动先 stash，拉取后还原（不丢工作）
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    log "工作树有未提交改动，先 stash"
    if git stash push -m "simplefly-auto-update" 2>>"$LOG"; then STASHED=1; else log "stash 失败，尝试直接拉取"; fi
  fi

  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  log "git fetch $REMOTE $BRANCH …"
  git fetch "$REMOTE" "$BRANCH" 2>&1 | tee -a "$LOG" || { [ -n "${STASHED:-}" ] && git stash pop 2>>"$LOG"; fail "git fetch 失败（检查网络 / 远程是否公开 / 是否安装 git）"; }

  log "git merge --ff-only FETCH_HEAD …"
  if ! git merge --ff-only FETCH_HEAD 2>&1 | tee -a "$LOG"; then
    [ -n "${STASHED:-}" ] && git stash pop 2>>"$LOG"
    fail "非快进：本地与远程分叉，请先处理（或手动 pull 后再点更新）"
  fi
  [ -n "${STASHED:-}" ] && { git stash pop 2>&1 | tee -a "$LOG" || log "stash pop 失败，改动留在 stash，请手动恢复"; }

  # 构建（与 build.sh 一致的部署目标回退：clang < 12 不认识 11.0，自动降到 10.15）
  CLANG_VER="$(clang --version 2>/dev/null | sed -n 's/.*clang version \([0-9]*\).*/\1/p')"
  if [ -n "$CLANG_VER" ] && [ "$CLANG_VER" -lt 12 ]; then
    export SIMPLEFLY_MIN_MACOS="${SIMPLEFLY_MIN_MACOS:-10.15}"
  else
    export SIMPLEFLY_MIN_MACOS="${SIMPLEFLY_MIN_MACOS:-11.0}"
  fi
  log "build.sh（SIMPLEFLY_MIN_MACOS=${SIMPLEFLY_MIN_MACOS}） …"
  ./build.sh 2>&1 | tee -a "$LOG" || fail "构建失败，详见 $LOG"

  log "install.sh …"
  ./install.sh 2>&1 | tee -a "$LOG" || fail "安装失败，详见 $LOG"
else
  # ============================ 预编译模式 ============================
  # 查询最新版本（优先用 API 拿 tag 与精确下载地址；失败则回退到静态 latest 链接）
  INSTALLED_VER="$(defaults read "$DEST/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null | sed 's/^v//')"
  LATEST_TAG=""; DL=""
  if REL_JSON="$(curl -fsS --max-time 30 "$API_URL" 2>/dev/null)"; then
    LATEST_TAG="$(printf '%s' "$REL_JSON" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 | sed 's/^v//')"
    DL="$(printf '%s' "$REL_JSON" | grep -m1 '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*SimpleFly\.app\.zip"' | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  fi
  [ -n "$DL" ] || DL="$RELEASE_URL"

  if [ -n "$LATEST_TAG" ] && [ "$LATEST_TAG" = "$INSTALLED_VER" ]; then
    log "已是最新（v$INSTALLED_VER），无需下载"
    notify "已是最新" "SimpleFly v$INSTALLED_VER 已是最新版"
    exit 0
  fi
  if [ -n "$LATEST_TAG" ]; then
    log "最新版本 v$LATEST_TAG，当前 ${INSTALLED_VER:-未安装}，开始下载…"
  else
    log "无法获取版本信息，直接下载最新包…"
  fi

  ZIP="/tmp/simplefly_latest.zip"
  curl -fL --max-time 180 "$DL" -o "$ZIP" || fail "下载失败（检查网络 / Release 是否存在）"
  TMPD="$(mktemp -d)"
  if ! ditto -x -k "$ZIP" "$TMPD" 2>/dev/null && ! unzip -q -o "$ZIP" -d "$TMPD" 2>/dev/null; then
    rm -rf "$TMPD" "$ZIP"
    fail "解压失败（压缩包可能损坏）"
  fi
  APP="$TMPD/SimpleFly.app"
  if [ ! -d "$APP" ]; then
    rm -rf "$TMPD" "$ZIP"
    fail "压缩包内未找到 SimpleFly.app"
  fi
  # 去除 quarantine 标记：ad-hoc 签名包从网络下载会被 Gatekeeper 当成「不明开发者」，
  # 去掉这个 xattr 后可直接运行（系统设置里仍可在「仍要打开」里放行）。
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

  # 签名校验 / 补签：必须在**还没放到 $DEST**的时候做。
  # 一是不让用户装上一个签名无效的 bundle（0.7.0 / 0.7.1 的线上包就是这种，
  # package_release.sh 内嵌 tis_register 后没重签）；二是绝不能在 $DEST 原地补签 ——
  # TIS 会在输入法被选中时立刻把落地的 bundle 拉起来执行，对着正在执行的 bundle
  # 原地签名写出来的封条对不上（报 "invalid resource directory"）。
  if codesign --verify "$APP" >/dev/null 2>&1; then
    log "包内签名校验通过"
  else
    log "包内签名无效，重新 ad-hoc 签名…"
    codesign --force --sign - "$APP" >/dev/null 2>&1 || log "重新签名失败（继续安装）"
    codesign --verify "$APP" >/dev/null 2>&1 \
      && log "补签后签名校验通过" \
      || log "警告：签名仍无效，继续安装（ad-hoc 自签，通常不影响本机使用）"
  fi

  # 先停旧进程，再「暂存 → 替换」换上去。用 rename 换而不是直接 cp 到 $DEST，
  # 是为了让 $DEST 一出现就是完整且已签好的 bundle（避免半成品被系统拉起）。
  pkill -x SimpleFly 2>/dev/null || true
  sleep 1
  DESTDIR_L="$HOME/Library/Input Methods"
  STAGE="$DESTDIR_L/.SimpleFly.app.stage"
  rm -rf "$STAGE"
  cp -R "$APP" "$STAGE" || { rm -rf "$TMPD" "$ZIP" "$STAGE"; fail "暂存 bundle 失败"; }
  rm -rf "$DEST" || { rm -rf "$TMPD" "$ZIP" "$STAGE"; fail "无法移除旧 bundle（可能被占用），请稍后重试"; }
  mv "$STAGE" "$DEST" || { rm -rf "$TMPD" "$ZIP"; fail "替换 bundle 失败"; }
  rm -rf "$TMPD" "$ZIP"
fi

# ---- 免登刷新：重注册并启用输入法 ----
if [ -d "$DEST" ]; then
  TISREG=""
  if [ -x "$DEST/Contents/Resources/tis_register" ]; then
    TISREG="$DEST/Contents/Resources/tis_register"   # 预编译模式：用 bundle 内嵌的
  elif [ "$MODE" = source ] && [ -n "${REPO:-}" ] && [ -f "$REPO/tools/tis_register.c" ]; then
    clang -O2 -isysroot "$(xcrun --show-sdk-path)" "$REPO/tools/tis_register.c" \
          -o /tmp/tisreg -framework Carbon 2>>"$LOG" && TISREG=/tmp/tisreg   # 源码模式：现场编译
  fi
  if [ -n "$TISREG" ]; then
    log "免登刷新（tis_register --enable）…"
    if "$TISREG" "$DEST" --enable >>"$LOG" 2>&1; then
      log "免登刷新成功"
    else
      log "免登刷新失败（可能需要注销重登）—— 更新已生效，仅输入法列表未刷新"
    fi
  else
    log "未找到 tis_register，跳过免登刷新（可能需要注销重登）"
  fi
fi

log "更新完成"
notify "更新完成" "SimpleFly 已更新到最新版。如输入法列表未变，切走再切回即可。"
exit 0
