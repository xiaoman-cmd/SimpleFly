#!/bin/bash
# 卸载：从用户输入法目录移除 SimpleFly。只动自己这一个 bundle。
set -euo pipefail

DEST="$HOME/Library/Input Methods/SimpleFly.app"

pkill -x SimpleFly 2>/dev/null || true
sleep 0.5

if [ -d "$DEST" ]; then
  case "$DEST" in
    "$HOME/Library/Input Methods/SimpleFly.app") rm -rf "$DEST" ;;
    *) echo "路径检查未通过，已中止：$DEST" >&2; exit 1 ;;
  esac
  echo "已移除 $DEST"
else
  echo "$DEST 不存在，无需卸载"
fi

echo
echo "系统设置里的输入法条目会在下一次注销/重启后消失；"
echo "如果想立刻清掉，也可以现在就去「系统设置 › 键盘 › 输入法」把它删掉。"
