#!/bin/bash
# AutoLoop: Issue 驱动的自动修复轮询
# 扫描 open issues → CC 修复 → 延迟验证 → close
# cron: */30 * * * *
set -euo pipefail

# ── 配置（可通过环境变量覆盖） ──
REPO="${AUTOLOOP_REPO:?请设置 AUTOLOOP_REPO 环境变量，如 user/repo}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CC_SCRIPT="${SKILL_DIR}/scripts/cc.sh"
LOG="${AUTOLOOP_LOG_DIR:-/var/log/autoloop}/auto-fix.log"
LOCK="/tmp/autoloop-auto-fix.lock"
TG="${AUTOLOOP_TG_SCRIPT:-}"   # 可选：Telegram 通知脚本路径
WORK_CWD="${AUTOLOOP_WORK_DIR:-/root/clawd}"
MAX_RETRIES="${AUTOLOOP_MAX_RETRIES:-3}"

mkdir -p "$(dirname "$LOG")"

# 防并发
if [ -f "$LOCK" ]; then
    pid=$(cat "$LOCK" 2>/dev/null || echo "0")
    if kill -0 "$pid" 2>/dev/null; then
        echo "[$(date '+%H:%M')] skip: already running (pid $pid)" >> "$LOG"
        exit 0
    fi
fi
echo $$ > "$LOCK"
trap "rm -f $LOCK" EXIT

log() { echo "[$(date '+%m-%d %H:%M')] $*" >> "$LOG"; }
log "=== auto-fix start ==="

python3 << PYEOF
import json, subprocess, sys, os, re, time

REPO = "$REPO"
CC_SCRIPT = "$CC_SCRIPT"
TG = "$TG"
WORK_CWD = "$WORK_CWD"
MAX_RETRIES = int("$MAX_RETRIES")

# 获取 open issues
r = subprocess.run(["gh", "api", f"repos/{REPO}/issues?state=open&per_page=20"],
    capture_output=True, text=True)
if r.returncode != 0:
    print(f"[error] gh api failed: {r.stderr[:200]}")
    sys.exit(1)

issues = json.loads(r.stdout)
fixed = 0
failed = 0
verified = 0
verify_failed = 0

# ── 阶段1: 验证 pending-verify 的 issue ──
for issue in issues:
    num = issue["number"]
    title = issue["title"]
    body = (issue.get("body") or "").strip()
    labels = [l["name"] for l in issue.get("labels", [])]

    if "pending-verify" not in labels:
        continue

    print(f"[verify] #{num}: {title}")

    verify_block = ""
    m = re.search(r'\`\`\`verify\s*\n(.*?)\`\`\`', body, re.DOTALL)
    if m:
        verify_block = m.group(1).strip()

    if verify_block:
        try:
            vr = subprocess.run(["bash", "-c", verify_block],
                capture_output=True, text=True, timeout=120, cwd=WORK_CWD)
            v_ok = vr.returncode == 0
            v_out = (vr.stdout + vr.stderr)[-500:]
        except Exception as e:
            v_ok = False
            v_out = str(e)
    else:
        v_prompt = f"验证以下问题是否已修复（不要修改任何东西，只检查）：{title}\n\n{body}\n\n如果已修复输出 VERIFIED，否则输出 NOT_FIXED: 原因"
        try:
            vr = subprocess.run(
                ["bash", CC_SCRIPT, v_prompt, "--cwd", "/"],
                capture_output=True, text=True, timeout=600)
            v_out = vr.stdout[-1000:] if vr.stdout else ""
            v_ok = "VERIFIED" in v_out and "NOT_FIXED" not in v_out
        except Exception as e:
            v_ok = False
            v_out = str(e)

    if v_ok:
        subprocess.run(["gh", "issue", "comment", str(num), "--repo", REPO,
            "--body", f"✅ 延迟验证通过，关闭 issue\n\n\`\`\`\n{v_out[-300:]}\n\`\`\`"],
            capture_output=True)
        subprocess.run(["gh", "issue", "close", str(num), "--repo", REPO],
            capture_output=True)
        subprocess.run(["gh", "api", f"repos/{REPO}/issues/{num}/labels/pending-verify",
            "--method", "DELETE"], capture_output=True)
        print(f"[verified] #{num} closed")
        verified += 1
    else:
        subprocess.run(["gh", "api", f"repos/{REPO}/issues/{num}/labels/pending-verify",
            "--method", "DELETE"], capture_output=True)
        subprocess.run(["gh", "issue", "comment", str(num), "--repo", REPO,
            "--body", f"❌ 延迟验证未通过，CC 将在下一轮重试\n\n\`\`\`\n{v_out[-300:]}\n\`\`\`"],
            capture_output=True)
        print(f"[verify-fail] #{num}")
        verify_failed += 1

# ── 阶段2: 处理需要修复的 issue ──
for issue in issues:
    num = issue["number"]
    title = issue["title"]
    body = (issue.get("body") or "").strip()
    labels = [l["name"] for l in issue.get("labels", [])]

    skip_labels = {"needs-decision", "stale", "auto-fixed", "pending-verify"}
    if skip_labels & set(labels):
        continue
    if "type:service" not in labels:
        continue

    print(f"[fix] #{num}: {title}")

    cr = subprocess.run(["gh", "api", f"repos/{REPO}/issues/{num}/comments?per_page=10"],
        capture_output=True, text=True)
    comments = json.loads(cr.stdout) if cr.returncode == 0 else []
    fail_comments = [c for c in comments if "auto-fix 无法修复" in (c.get("body") or "")]

    if len(body) > 50:
        prompt = body + "\n\n最后一行必须输出：FIXED: 简述 或 NEEDS_HUMAN: 原因"
    else:
        prompt = f"""修复以下问题：{title}

{body}

在 {WORK_CWD} 目录下操作。修完验证。
最后一行必须输出：FIXED: 简述 或 NEEDS_HUMAN: 原因"""

    if fail_comments:
        last_fail_body = fail_comments[-1].get("body", "")
        prompt += f"\n\n上次尝试失败原因：{last_fail_body}\n请避免同样的错误。"

    try:
        result = subprocess.run(
            ["bash", CC_SCRIPT, prompt, "--cwd", "/"],
            capture_output=True, text=True, timeout=1800
        )
        output = result.stdout[-2000:] if result.stdout else "no output"
    except subprocess.TimeoutExpired:
        output = "NEEDS_HUMAN: CC 执行超时（30分钟）"
    except Exception as e:
        output = f"NEEDS_HUMAN: 执行异常 {e}"

    if "FIXED:" in output:
        fix_msg = output.split("FIXED:")[-1].strip()[:500]
        subprocess.run(["gh", "issue", "comment", str(num), "--repo", REPO,
            "--body", f"✅ CC 报告修复完成：{fix_msg}\n\n⏳ 已标记 \`pending-verify\`，下一轮 cron 将自动验证"],
            capture_output=True)
        subprocess.run(["gh", "api", f"repos/{REPO}/issues/{num}/labels",
            "--method", "POST", "--input", "-"],
            input=json.dumps({"labels":["pending-verify"]}).encode(),
            capture_output=True)
        print(f"[pending] #{num} marked pending-verify")
        fixed += 1
    else:
        reason = output[-300:].strip() if output else "CC 无输出"
        if "NEEDS_HUMAN:" in output:
            reason = output.split("NEEDS_HUMAN:")[-1].strip()[:500]
        attempt_count = len(fail_comments) + 1
        subprocess.run(["gh", "issue", "comment", str(num), "--repo", REPO,
            "--body", f"🤖 auto-fix 无法修复（第 {attempt_count} 次尝试）\n\n{reason}"], capture_output=True)
        if attempt_count >= MAX_RETRIES:
            subprocess.run(["gh", "api", f"repos/{REPO}/issues/{num}/labels",
                "--method", "POST", "--input", "-"],
                input=json.dumps({"labels":["needs-decision"]}).encode(),
                capture_output=True)
            if TG and os.path.exists(TG):
                subprocess.run(["bash", TG, f"🔧 issue #{num} 已失败 {attempt_count} 次，需要你看: {title}\n{reason[:200]}"],
                    capture_output=True)
            print(f"[human] #{num}: 失败 {attempt_count} 次, {reason[:100]}")
        else:
            print(f"[retry-later] #{num}: 失败 {attempt_count} 次, 下轮重试")
        failed += 1

print(f"\n[summary] fixed={fixed} needs_human={failed} verified={verified} verify_failed={verify_failed}")
PYEOF

log "=== auto-fix done ==="
