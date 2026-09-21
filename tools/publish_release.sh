#!/bin/bash
# 建 GitHub Release 并上传 SimpleFly.app.zip（给「预编译模式」自更新用）。
#
# 用法：
#   GH_TOKEN=<fine-grained PAT> ./tools/publish_release.sh [--body <说明.md>] [--repo owner/name]
#
# token 需要 **Contents: Read and write**（fine-grained → Repository permissions 那份列表里，
# 不在 Account permissions）。token 只走环境变量，本脚本不落盘、不打印。
#
# 前置：先跑 ./tools/package_release.sh 生成仓库根目录的 SimpleFly.app.zip，
#       并且已经把 tag push 上去（脚本不建 tag —— tag 该随提交一起推，见 README 发版流程）。
#
# 脚本做的事：读版本号 → 校验 token 身份 → 确认同 tag 还没有 Release（防重复建）
#             → 建 Release → 上传 asset → **匿名端到端复核**（tag / 体积 / sha256 / 解压后
#             版本号与签名）。任何一步不过就非零退出。
#
# ⚠️ 写这个脚本时踩过的两个坑，改的时候别踩回去：
#   1) shell 里变量**紧贴中文全角标点**（如 "$CODE）"）会被 bash 当成变量名的一部分，
#      `set -u` 下直接报 unbound variable —— 变量一律写成 "${CODE}"。
#   2) 内嵌的 python heredoc 用 <<'PY'（带引号）时**不展开 bash 变量**，
#      "tag_name": TAG 会 NameError —— 要传值就走环境变量或写死在 heredoc 里。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO=""
BODY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo 需要 owner/name}"; shift 2 ;;
    --body) BODY_FILE="${2:?--body 需要文件路径}"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（-h 看用法）"; exit 2 ;;
  esac
done

: "${GH_TOKEN:?需要 GH_TOKEN 环境变量（fine-grained PAT，Contents: Read and write）}"
[ -n "$REPO" ] || REPO="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
[ -n "$REPO" ] || { echo "取不到仓库名，用 --repo owner/name 指定"; exit 2; }

VERSION="$(plutil -extract CFBundleShortVersionString raw resources/Info.plist)"
BUILD="$(plutil -extract CFBundleVersion raw resources/Info.plist)"
TAG="v${VERSION}"
ZIP="$ROOT/SimpleFly.app.zip"

[ -f "$ZIP" ] || { echo "找不到 ${ZIP}，先跑 ./tools/package_release.sh"; exit 2; }
grep -q "<string>${BUILD}</string>" resources/Info.plist || { echo "Info.plist 版本号读出来不对"; exit 2; }

API="https://api.github.com/repos/${REPO}"
H_AUTH="Authorization: Bearer ${GH_TOKEN}"
H_ACC="Accept: application/vnd.github+json"
LOCAL_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
LOCAL_SIZE="$(stat -f%z "$ZIP")"

echo "==> 仓库 ${REPO}   tag ${TAG}   (build ${BUILD})"
echo "==> asset: ${LOCAL_SIZE} 字节  sha256 ${LOCAL_SHA:0:12}…"

echo "==> 1/5 校验 token"
ME="$(curl -s -H "${H_AUTH}" -H "${H_ACC}" https://api.github.com/user)"
printf '%s' "$ME" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("    identity:",d.get("login") or d)' \
  || { printf '%s\n' "$ME" | head -20; exit 1; }

echo "==> 2/5 确认 tag 已 push 且还没建过 Release"
git ls-remote --tags origin "refs/tags/${TAG}" | grep -q "refs/tags/${TAG}$" \
  || { echo "!!! 远端没有 tag ${TAG}，先 git tag -a ${TAG} && git push origin ${TAG}"; exit 3; }
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "${H_AUTH}" -H "${H_ACC}" "${API}/releases/tags/${TAG}")"
if [ "${CODE}" = "200" ]; then
  echo "!!! ${TAG} 的 Release 已存在，终止（先只读核对线上状态，别盲目重跑）"
  exit 3
fi
echo "    无同 tag Release (HTTP ${CODE})，继续"

echo "==> 3/5 建 Release"
PAYLOAD_FILE="$(mktemp)"
SF_VERSION="${VERSION}" SF_BODY_FILE="${BODY_FILE}" python3 - > "${PAYLOAD_FILE}" <<'PY'
import json, os
vf = os.environ.get("SF_BODY_FILE") or ""
if vf and os.path.isfile(vf):
    body = open(vf, encoding="utf-8").read()
else:
    body = ("详见仓库 docs/开发笔记.md 的「版本变更总览」。\n\n"
            "**安装**：解压 `SimpleFly.app.zip`，把 `SimpleFly.app` 放进 `~/Library/Input Methods/`，"
            "然后注销重登；或用源码仓库的 `./install.sh`。\n\n"
            "**若更新后图标没变化**：TIS 按「文件路径」缓存图标，注销重登一次即可。")
print(json.dumps({
    "tag_name": "v" + os.environ["SF_VERSION"],
    "name": "v" + os.environ["SF_VERSION"],
    "body": body,
    "draft": False,
    "make_latest": "true",   # 注意：必须是**字符串** "true"，JSON 布尔会 422
}))
PY
[ -s "${PAYLOAD_FILE}" ] || { echo "生成 payload 失败"; exit 4; }
RESP="$(curl -s -X POST -H "${H_AUTH}" -H "${H_ACC}" --data-binary "@${PAYLOAD_FILE}" "${API}/releases")"
rm -f "${PAYLOAD_FILE}"
RID="$(printf '%s' "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
if [ -z "${RID}" ]; then
  echo "!!! 建 Release 失败："
  printf '%s\n' "$RESP" | head -30
  echo "    （403 且响应头 x-accepted-github-permissions 提示 contents=write → token 少了 Contents 写权限）"
  exit 4
fi
echo "    release id = ${RID}"

echo "==> 4/5 上传 asset（名字必须是 SimpleFly.app.zip，自更新器按此名找）"
curl -s -X POST -H "${H_AUTH}" -H "Content-Type: application/zip" \
  --data-binary "@${ZIP}" \
  "https://uploads.github.com/repos/${REPO}/releases/${RID}/assets?name=SimpleFly.app.zip" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print("    asset:",d.get("name"),d.get("size"),"字节")'

echo "==> 5/5 匿名端到端复核"
curl -s --http1.1 "${API}/releases/latest" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("    latest tag :", d.get("tag_name"))
print("    latest name:", d.get("name"))
for a in d.get("assets", []):
    print("    asset      :", a.get("name"), a.get("size"), "字节")
'
TMPD="$(mktemp -d)"
curl -sL --http1.1 -o "${TMPD}/SimpleFly.app.zip" \
  "https://github.com/${REPO}/releases/latest/download/SimpleFly.app.zip"
REMOTE_SHA="$(shasum -a 256 "${TMPD}/SimpleFly.app.zip" | awk '{print $1}')"
REMOTE_SIZE="$(stat -f%z "${TMPD}/SimpleFly.app.zip")"
echo "    匿名下载   : ${REMOTE_SIZE} 字节  sha256 ${REMOTE_SHA:0:12}…"
OK=1
[ "${REMOTE_SHA}" = "${LOCAL_SHA}" ] || { echo "!!! sha256 不一致"; OK=0; }
[ "${REMOTE_SIZE}" = "${LOCAL_SIZE}" ] || { echo "!!! 体积不一致"; OK=0; }
if [ "${OK}" = "1" ]; then echo "    sha256 / 体积与本地一致 ✓"; fi

if ditto -x -k "${TMPD}/SimpleFly.app.zip" "${TMPD}"; then
  ZAPP="${TMPD}/SimpleFly.app"
  ZV="$(plutil -extract CFBundleShortVersionString raw "${ZAPP}/Contents/Info.plist")"
  ZB="$(plutil -extract CFBundleVersion raw "${ZAPP}/Contents/Info.plist")"
  echo "    包内版本   : ${ZV} / ${ZB}"
  [ "${ZV}" = "${VERSION}" ] && [ "${ZB}" = "${BUILD}" ] || { echo "!!! 包内版本号对不上"; OK=0; }
  if codesign --verify --deep --strict "${ZAPP}" >/dev/null 2>&1; then
    echo "    签名       : 有效 ✓"
  else
    echo "    签名       : !!! 无效"; OK=0
  fi
else
  echo "!!! 解压失败"; OK=0
fi
rm -rf "${TMPD}"

[ "${OK}" = "1" ] || { echo "!!! 复核未全过，别急着宣布成功"; exit 5; }
echo "==> 完成：${TAG} 已上线"
