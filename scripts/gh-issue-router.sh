#!/bin/bash
# AutoLoop: Issue 路由器 - 按 label 分发任务
# cron: */30 * * * *
set -euo pipefail

REPO="${AUTOLOOP_REPO:?请设置 AUTOLOOP_REPO 环境变量，如 user/repo}"
LOG="${AUTOLOOP_LOG_DIR:-/var/log/autoloop}/issue-router.log"
mkdir -p "$(dirname "$LOG")"

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] router start" >> "$LOG"

issues=$(gh api "repos/$REPO/issues?state=open&per_page=50" 2>/dev/null)
count=$(echo "$issues" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
echo "[router] $count open issues" >> "$LOG"

echo "$issues" | python3 -c "
import sys, json, subprocess

REPO = '$REPO'
issues = json.load(sys.stdin)
for issue in issues:
    num = issue['number']
    title = issue['title']
    labels = [l['name'] for l in issue.get('labels', [])]

    if 'auto-fixed' in labels or 'needs-decision' in labels or 'stale' in labels:
        continue

    if 'type:service' in labels:
        print(f'[route] #{num} -> auto-fix: {title}')
    elif 'type:reading' in labels:
        print(f'[route] #{num} -> reading: {title}')
    elif 'type:bug' in labels:
        print(f'[route] #{num} -> CC fix: {title}')
    elif 'type:enhancement' in labels:
        print(f'[route] #{num} -> enhancement (manual): {title}')
" >> "$LOG" 2>&1

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] router done" >> "$LOG"
