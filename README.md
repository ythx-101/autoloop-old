<div align="center">

# 🦞 AutoLoop

**Issue-driven autonomous agent pipeline — zero glue, fully automatic.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![OpenClaw Skill](https://img.shields.io/badge/OpenClaw-Skill-blue.svg)](https://github.com/openclaw/openclaw)
[![GitHub stars](https://img.shields.io/github/stars/ythx-101/autoloop?style=social)](https://github.com/ythx-101/autoloop)

*Issue → Cron → Claude Code fix → Delayed verify → Auto-close · Works on any GitHub repo*

[Quick Start](#-quick-start) · [Core Mechanism](#-core-mechanism-zero-glue) · [Issue Format](#-issue-format) · [Scripts](#-scripts) · [Logs & Debug](#-logs--debug)

</div>

---

## 😤 Problem

```
Ops alert fires at 3 AM.
You: create a GitHub issue, assign someone, wait for morning standup…
3 hours later the fix is a one-liner.
```

Most incidents don't need a human in the loop — they need a **loop**. AutoLoop watches your GitHub issues, dispatches Claude Code to fix them, verifies the result, and closes the issue. If it fails 3 times, *then* it pings a human.

## 🚀 Quick Start

```bash
# One-line install for any GitHub repo
bash <(curl -sL https://raw.githubusercontent.com/ythx-101/autoloop/main/install.sh) --repo user/repo
```

### Custom parameters

```bash
bash <(curl -sL https://raw.githubusercontent.com/ythx-101/autoloop/main/install.sh) \
    --repo myorg/myapp \
    --user agent \
    --cron-interval 15 \
    --max-retries 5 \
    --work-dir /opt/workspace
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--repo` | (required) | Target GitHub repo `OWNER/REPO` |
| `--user` | `ccworker` | CC execution user |
| `--work-dir` | `/root/clawd` | Working directory |
| `--log-dir` | `/var/log/autoloop` | Log directory |
| `--cron-interval` | `30` | Cron poll interval (minutes) |
| `--max-retries` | `3` | Max auto-fix retries per issue |
| `--tg-script` | (none) | Telegram notification script path |
| `--skip-user` | — | Skip user creation |
| `--skip-cron` | — | Skip cron setup |

## ⚙️ Core Mechanism (Zero Glue)

AutoLoop is a **zero-glue** pipeline — no orchestrator, no queue, no database. GitHub Issues *are* the state machine. Labels *are* the transitions. Cron *is* the scheduler.

```
GitHub Issue (type:service label)
    ↓  cron */30
gh-issue-router.sh — route by label
    ↓
auto-fix.sh — Claude Code executes fix
    ↓  outputs FIXED:
mark pending-verify
    ↓  next cron cycle
delayed verification (verify block or CC verify)
    ↓  pass → auto-close issue
    ↓  fail ≥3 times
mark needs-decision + TG notify human
```

### Why "Zero Glue"?

| Traditional | AutoLoop |
|-------------|----------|
| Jira + webhook + Lambda + SQS + worker | GitHub Issue + cron + shell script |
| Redis/DB for state | GitHub Labels for state |
| Custom retry logic | Cron = built-in retry |
| Dashboard for monitoring | `gh issue list` = dashboard |

### Key Features

| Feature | How it works |
|---------|-------------|
| **Issue-driven** | Open a GitHub Issue → pipeline picks it up automatically |
| **Memory retry** | Each retry carries context from prior attempts — CC learns from failures |
| **Delayed verification** | Fixes aren't trusted immediately; next cron cycle re-verifies |
| **Human escalation** | After N failures, labels `needs-decision` and pings Telegram |
| **Inline verify blocks** | Embed test commands in issue body — auto-fix runs them to validate |
| **Label routing** | `type:service`, `type:bug`, `type:enhancement` → different handlers |

## 📝 Issue Format

Title is for humans. Body is for Claude Code:

```markdown
Title: Redis connection pool exhausted causing API 500

Body:
Check /root/clawd/services/api Redis connection config.
Current max_connections=10 is insufficient, increase to 50.

Modify REDIS_MAX_CONNECTIONS in config.py.
Restart service and verify API returns 200.
```

### Optional: Inline verify block

Add a ` ```verify ` code block for automatic validation:

````markdown
```verify
curl -s http://localhost:8080/health | grep -q '"status":"ok"'
```
````

### Labels

| Label | Meaning |
|-------|---------|
| `type:service` | Service/ops — auto-fix |
| `type:bug` | Bug — CC fix |
| `type:enhancement` | Feature — human handles |
| `type:reading` | Research task |
| `pending-verify` | Awaiting next-cycle verification |
| `needs-decision` | Retries exhausted, needs human |

## 📦 Dependencies

| Dependency | Install |
|------------|---------|
| `gh` (GitHub CLI) | https://cli.github.com/ |
| `claude` (Claude Code) | `npm install -g @anthropic-ai/claude-code` |
| `python3` | System default or `apt install python3` |
| `setfacl` (optional) | `apt install acl` |

## 🔧 Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | One-line install & config |
| `scripts/cc.sh` | CC invocation wrapper |
| `scripts/auto-fix.sh` | Main loop: scan issues → CC fix → verify → close |
| `scripts/gh-issue-router.sh` | Route issues by label |

## 📊 Logs & Debug

```bash
# Live logs
tail -f /var/log/autoloop/auto-fix.log

# Cron logs
tail -f /var/log/autoloop/cron.log

# Manual trigger
source /root/clawd/skills/our/autoloop/.env
bash /root/clawd/skills/our/autoloop/scripts/auto-fix.sh

# Check cron
crontab -l | grep autoloop
```

## 🗑️ Uninstall

```bash
# Remove cron
crontab -l | grep -v 'autoloop' | crontab -

# Delete logs
rm -rf /var/log/autoloop

# Delete skill directory
rm -rf skills/our/autoloop
```

## 🤝 Contributing

Issues and PRs welcome! AutoLoop is part of the [OpenClaw](https://github.com/openclaw/openclaw) ecosystem.

## 📄 License

[MIT](LICENSE)

---

<div align="center">

*Issue-driven. Zero glue. Fully automatic.* 🦞

**[GitHub](https://github.com/ythx-101/autoloop)** · **[Issues](https://github.com/ythx-101/autoloop/issues)** · **[OpenClaw](https://github.com/openclaw/openclaw)**

</div>
