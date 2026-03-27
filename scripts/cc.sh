#!/bin/bash
# CC 调用模板：通过 ccworker 用户以 bypassPermissions 模式调用 Claude Code
# 用法: cc.sh "任务"
#       cc.sh "任务" --cwd /path --max-turns 50 --timeout 600
#       cc.sh --file prompt.md
set -euo pipefail

MAX_TURNS=200
CWD="${AUTOLOOP_WORK_DIR:-/root/clawd}"
TIMEOUT=0
TASK=""
FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --cwd)        CWD="$2"; shift 2;;
        --max-turns)  MAX_TURNS="$2"; shift 2;;
        --timeout)    TIMEOUT="$2"; shift 2;;
        --file)       FILE="$2"; shift 2;;
        -*)           shift;;
        *)            [ -z "$TASK" ] && TASK="$1"; shift;;
    esac
done

if [ -n "$FILE" ] && [ -f "$FILE" ]; then
    TASK=$(cat "$FILE")
fi

[ -z "$TASK" ] && { echo "用法: cc.sh \"任务\" 或 cc.sh --file prompt.md" >&2; exit 1; }

TOOLS="Bash(python3:*) Bash(gh:*) Bash(curl:*) Bash(cat:*) Bash(ls:*) Bash(grep:*) Bash(sed:*) Bash(awk:*)"
TOOLS="$TOOLS Bash(date:*)"
TOOLS="$TOOLS Bash(head:*) Bash(tail:*) Bash(wc:*) Bash(find:*) Bash(sort:*) Bash(uniq:*)"
TOOLS="$TOOLS Bash(mkdir:*) Bash(cp:*) Bash(mv:*) Bash(rm:*) Bash(chmod:*) Bash(diff:*) Bash(tar:*)"
TOOLS="$TOOLS Bash(pip:*) Bash(npm:*) Bash(node:*) Bash(git:*) Bash(touch:*) Bash(tee:*)"
TOOLS="$TOOLS Read Write Edit"

ESCAPED_TASK=$(printf '%s' "$TASK" | sed "s/'/'\\\\''/g")
CC_CMD="cd '$CWD' && claude -p '$ESCAPED_TASK' --permission-mode bypassPermissions --allowedTools '$TOOLS' --output-format text --max-turns $MAX_TURNS"

CC_USER="${AUTOLOOP_CC_USER:-ccworker}"

if [ "$TIMEOUT" -gt 0 ] 2>/dev/null; then
    exec timeout "$TIMEOUT" su -s /bin/bash "$CC_USER" -c "$CC_CMD"
else
    exec su -s /bin/bash "$CC_USER" -c "$CC_CMD"
fi
