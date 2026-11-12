#!/bin/bash
# AutoLoop 一键安装脚本
# 用法: bash install.sh --repo user/repo [--user ccworker] [--work-dir /root/clawd] [--cron-interval 30]
set -euo pipefail

# ── 默认值 ──
REPO=""
CC_USER="ccworker"
WORK_DIR="/root/clawd"
LOG_DIR="/var/log/autoloop"
CRON_INTERVAL=30
MAX_RETRIES=3
TG_SCRIPT=""
SKIP_USER=false
SKIP_CRON=false

# ── 颜色 ──
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }

usage() {
    cat <<'EOF'
AutoLoop Installer
===========================
为任意 GitHub 仓库部署 issue 驱动的全自动 Agent 管线。

用法:
  bash install.sh --repo user/repo [选项]

必需参数:
  --repo OWNER/REPO       目标 GitHub 仓库

可选参数:
  --user USERNAME          CC 执行用户 (默认: ccworker)
  --work-dir PATH          工作目录 (默认: /root/clawd)
  --log-dir PATH           日志目录 (默认: /var/log/autoloop)
  --cron-interval MINS     cron 轮询间隔分钟 (默认: 30)
  --max-retries N          最大重试次数 (默认: 3)
  --tg-script PATH         Telegram 通知脚本路径 (可选)
  --skip-user              跳过用户创建
  --skip-cron              跳过 cron 配置
  -h, --help               显示帮助

示例:
  bash install.sh --repo myorg/myapp
  bash install.sh --repo myorg/myapp --user agent --cron-interval 15
EOF
    exit "${1:-0}"
}

# ── 解析参数 ──
while [[ $# -gt 0 ]]; do
    case $1 in
        --repo)           REPO="$2"; shift 2;;
        --user)           CC_USER="$2"; shift 2;;
        --work-dir)       WORK_DIR="$2"; shift 2;;
        --log-dir)        LOG_DIR="$2"; shift 2;;
        --cron-interval)  CRON_INTERVAL="$2"; shift 2;;
        --max-retries)    MAX_RETRIES="$2"; shift 2;;
        --tg-script)      TG_SCRIPT="$2"; shift 2;;
        --skip-user)      SKIP_USER=true; shift;;
        --skip-cron)      SKIP_CRON=true; shift;;
        -h|--help)        usage;;
        *)                error "未知参数: $1"; usage 1;;
    esac
done

[ -z "$REPO" ] && { error "必须指定 --repo 参数"; usage 1; }

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="${SKILL_DIR}/scripts"

echo "============================================"
echo "  AutoLoop Installer"
echo "  目标仓库: $REPO"
echo "============================================"
echo ""

# ── Step 1: 检查依赖 ──
info "检查依赖..."

check_dep() {
    if ! command -v "$1" &>/dev/null; then
        error "缺少依赖: $1"
        echo "  请先安装: $2"
        return 1
    fi
    info "  $1 ✓"
}

DEPS_OK=true
check_dep "gh"      "https://cli.github.com/" || DEPS_OK=false
check_dep "claude"  "npm install -g @anthropic-ai/claude-code" || DEPS_OK=false
check_dep "python3" "apt install python3" || DEPS_OK=false

if [ "$DEPS_OK" = false ]; then
    error "请先安装缺失的依赖"
    exit 1
fi

# 检查 gh 认证
if ! gh auth status &>/dev/null; then
    warn "gh CLI 未认证，请先运行: gh auth login"
    exit 1
fi
info "  gh 认证状态 ✓"

# 验证仓库可访问
if ! gh api "repos/$REPO" &>/dev/null; then
    error "无法访问仓库 $REPO，请检查权限"
    exit 1
fi
info "  仓库 $REPO 可访问 ✓"

# ── Step 2: 创建 ccworker 用户 ──
if [ "$SKIP_USER" = false ]; then
    if id "$CC_USER" &>/dev/null; then
        info "用户 $CC_USER 已存在"
    else
        info "创建用户 $CC_USER ..."
        useradd -r -m -s /bin/bash "$CC_USER"
        info "用户 $CC_USER 创建完成"
    fi

    # 配置 ACL 权限：让 ccworker 能读写工作目录
    info "配置 ACL 权限..."
    mkdir -p "$WORK_DIR"

    if command -v setfacl &>/dev/null; then
        setfacl -R -m "u:${CC_USER}:rwx" "$WORK_DIR" 2>/dev/null || true
        setfacl -R -d -m "u:${CC_USER}:rwx" "$WORK_DIR" 2>/dev/null || true
        info "ACL 权限设置完成"
    else
        warn "setfacl 不可用，使用 chmod 兜底"
        chmod -R o+rwx "$WORK_DIR" 2>/dev/null || true
    fi

    # 复制 gh 认证给 ccworker
    CC_HOME=$(eval echo "~${CC_USER}")
    CALLER_HOME="$HOME"
    if [ -d "${CALLER_HOME}/.config/gh" ]; then
        mkdir -p "${CC_HOME}/.config"
        cp -r "${CALLER_HOME}/.config/gh" "${CC_HOME}/.config/" 2>/dev/null || true
        chown -R "${CC_USER}:${CC_USER}" "${CC_HOME}/.config/gh" 2>/dev/null || true
        info "gh 认证已同步到 $CC_USER"
    else
        warn "未检测到 ${CALLER_HOME}/.config/gh，安装后请自行在 ${CC_USER} 用户下执行 gh auth login"
    fi

    # 复制 claude 认证给 ccworker
    if [ -f "${CALLER_HOME}/.claude.json" ]; then
        cp "${CALLER_HOME}/.claude.json" "${CC_HOME}/.claude.json" 2>/dev/null || true
        chown "${CC_USER}:${CC_USER}" "${CC_HOME}/.claude.json" 2>/dev/null || true
        info "claude 认证已同步到 $CC_USER"
    fi
    if [ -d "${CALLER_HOME}/.claude" ]; then
        cp -r "${CALLER_HOME}/.claude" "${CC_HOME}/" 2>/dev/null || true
        chown -R "${CC_USER}:${CC_USER}" "${CC_HOME}/.claude" 2>/dev/null || true
        info "claude 凭证目录已同步到 $CC_USER"
    else
        warn "未检测到 ${CALLER_HOME}/.claude，安装后请自行在 ${CC_USER} 用户下执行 claude login"
    fi
else
    info "跳过用户创建 (--skip-user)"
fi

# ── Step 3: 创建目录与日志 ──
mkdir -p "$LOG_DIR"
info "日志目录: $LOG_DIR"

# ── Step 4: 创建环境配置文件 ──
ENV_FILE="${SKILL_DIR}/.env"
cat > "$ENV_FILE" <<EOF
# AutoLoop 环境配置
# 由 install.sh 自动生成于 $(date -u +%Y-%m-%dT%H:%M:%SZ)
export AUTOLOOP_REPO="$REPO"
export AUTOLOOP_CC_USER="$CC_USER"
export AUTOLOOP_WORK_DIR="$WORK_DIR"
export AUTOLOOP_LOG_DIR="$LOG_DIR"
export AUTOLOOP_MAX_RETRIES="$MAX_RETRIES"
export AUTOLOOP_TG_SCRIPT="$TG_SCRIPT"
EOF
info "环境配置写入: $ENV_FILE"

# ── Step 5: 确保 GitHub Labels 存在 ──
info "检查/创建 GitHub Labels..."
ensure_label() {
    local name="$1" color="$2" desc="$3"
    if ! gh api "repos/$REPO/labels/$name" &>/dev/null 2>&1; then
        gh api "repos/$REPO/labels" --method POST \
            -f name="$name" -f color="$color" -f description="$desc" \
            &>/dev/null 2>&1 || true
        info "  创建 label: $name"
    fi
}

ensure_label "type:service"      "d73a4a" "服务/运维类问题"
ensure_label "type:bug"          "fc2929" "Bug"
ensure_label "type:enhancement"  "0e8a16" "功能增强"
ensure_label "type:reading"      "1d76db" "阅读/研究任务"
ensure_label "pending-verify"    "fbca04" "等待自动验证"
ensure_label "needs-decision"    "e4e669" "需要人工决策"
ensure_label "auto-fixed"        "0e8a16" "已自动修复"
ensure_label "stale"             "cccccc" "过期"

# ── Step 6: 设置脚本可执行权限 ──
chmod +x "${SCRIPTS_DIR}/cc.sh"
chmod +x "${SCRIPTS_DIR}/auto-fix.sh"
chmod +x "${SCRIPTS_DIR}/gh-issue-router.sh"
info "脚本权限设置完成"

# ── Step 7: 配置 Cron ──
if [ "$SKIP_CRON" = false ]; then
    info "配置 cron 定时任务..."

    CRON_TAG="# autoloop:${REPO}"

    # 构建 cron 行（source .env 注入环境变量）
    CRON_AUTO_FIX="*/${CRON_INTERVAL} * * * * . ${ENV_FILE} && bash ${SCRIPTS_DIR}/auto-fix.sh >> ${LOG_DIR}/cron.log 2>&1 ${CRON_TAG}"
    CRON_ROUTER="*/${CRON_INTERVAL} * * * * . ${ENV_FILE} && bash ${SCRIPTS_DIR}/gh-issue-router.sh >> ${LOG_DIR}/cron.log 2>&1 ${CRON_TAG}"

    # 移除旧条目，追加新条目
    (crontab -l 2>/dev/null | grep -v "$CRON_TAG" || true; echo "$CRON_AUTO_FIX"; echo "$CRON_ROUTER") | crontab -

    info "cron 任务已安装 (每 ${CRON_INTERVAL} 分钟):"
    info "  - auto-fix.sh"
    info "  - gh-issue-router.sh"
else
    info "跳过 cron 配置 (--skip-cron)"
    warn "请手动将以下内容加入 crontab:"
    echo "  */${CRON_INTERVAL} * * * * . ${ENV_FILE} && bash ${SCRIPTS_DIR}/auto-fix.sh"
    echo "  */${CRON_INTERVAL} * * * * . ${ENV_FILE} && bash ${SCRIPTS_DIR}/gh-issue-router.sh"
fi

# ── 完成 ──
echo ""
echo "============================================"
info "AutoLoop 安装完成!"
echo "============================================"
echo ""
echo "配置摘要:"
echo "  仓库:       $REPO"
echo "  执行用户:   $CC_USER"
echo "  工作目录:   $WORK_DIR"
echo "  日志目录:   $LOG_DIR"
echo "  轮询间隔:   每 ${CRON_INTERVAL} 分钟"
echo "  最大重试:   $MAX_RETRIES 次"
echo "  环境文件:   $ENV_FILE"
echo ""
echo "常用命令:"
echo "  查看日志:   tail -f $LOG_DIR/auto-fix.log"
echo "  查看 cron:  crontab -l | grep autoloop"
echo "  手动触发:   . $ENV_FILE && bash ${SCRIPTS_DIR}/auto-fix.sh"
echo "  创建 issue: gh issue create --repo $REPO --title '问题' --label type:service"
echo ""
