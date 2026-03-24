#!/bin/bash

# OpenClaw 环境清理脚本
# 功能：删除定时任务、停止服务、移除配置、清理缓存、卸载 Crontab 任务
# 注意：cron 删除必须在 gateway 停止之前执行，否则 openclaw CLI 无法操作 cron

set -e

# --- 业务目录定义 ---
OPS_DIR="${WZQ_OPS_DIR:-$HOME/.wzq-claw-ops}"
OPENCLAW_HOME="$HOME/.openclaw"
MONITOR_SCRIPT="$OPS_DIR/bootstrap/monitor_updates.sh"
JOBS_FILE="$OPENCLAW_HOME/cron/jobs.json"

echo ">>> [1/7] 正在删除 market-pulse 定时任务（gateway 运行中才能操作）..."
if command -v openclaw >/dev/null 2>&1; then
    openclaw cron delete --name "market-pulse-premarket" 2>/dev/null && echo "market-pulse-premarket 已删除" || echo "market-pulse-premarket 删除失败或不存在"
    openclaw cron delete --name "market-pulse-postmarket" 2>/dev/null && echo "market-pulse-postmarket 已删除" || echo "market-pulse-postmarket 删除失败或不存在"
else
    echo "未发现 openclaw 命令，跳过 CLI 删除。"
fi

echo ">>> [2/7] 正在停止 OpenClaw 服务..."
if command -v openclaw >/dev/null 2>&1; then
    openclaw gateway stop || true
    echo "服务已停止。"
else
    echo "未发现 openclaw 命令，跳过停止服务步骤。"
fi

# 兜底：gateway 停止后直接清理 jobs.json（避免竞态）
if [ -f "$JOBS_FILE" ] && command -v jq >/dev/null 2>&1; then
    echo "使用 jq 兜底清理 jobs.json 中的 market-pulse 任务..."
    TMP_JOBS=$(mktemp)
    jq '.jobs |= map(select(.name != "market-pulse-premarket" and .name != "market-pulse-postmarket"))' "$JOBS_FILE" > "$TMP_JOBS" && mv "$TMP_JOBS" "$JOBS_FILE"
    echo "jobs.json 已清理。"
elif [ -f "$JOBS_FILE" ]; then
    echo "警告: jq 不可用，无法兜底清理 jobs.json。请手动检查 $JOBS_FILE"
fi

echo ">>> [3/7] 正在移除定时监控任务 (Crontab)..."
if crontab -l 2>/dev/null | grep -q "$MONITOR_SCRIPT"; then
    (crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" || true) | crontab -
    echo "Crontab 任务已移除。"
else
    echo "Crontab 中未发现相关任务，跳过。"
fi

echo ">>> [4/7] 正在还原 wzq-claw-md 替换前的备份文件..."
MD_BACKUP="$OPS_DIR/backup/openclaw-pre-md"
MD_DONE_FLAG="$OPS_DIR/.wzq-claw-md-done"
OPENCLAW_WORKSPACE="$OPENCLAW_HOME/workspace"
if [ -d "$MD_BACKUP" ]; then
    BACKUP_COUNT=$(find "$MD_BACKUP" -type f 2>/dev/null | wc -l)
    if [ "$BACKUP_COUNT" -gt 0 ]; then
        echo "发现 $BACKUP_COUNT 个备份文件，正在还原到 $OPENCLAW_WORKSPACE ..."
        # 按原目录结构将备份文件覆盖回去
        find "$MD_BACKUP" -type f | while read -r bak; do
            rel="${bak#$MD_BACKUP/}"
            target="$OPENCLAW_WORKSPACE/$rel"
            mkdir -p "$(dirname "$target")"
            cp -f "$bak" "$target"
        done
        echo "备份还原完成。"
    else
        echo "备份目录为空，跳过还原。"
    fi
    # 清理备份目录和标记文件
    rm -rf "$MD_BACKUP"
    rm -f "$MD_DONE_FLAG"
else
    echo "未发现 wzq-claw-md 备份目录，跳过还原。"
    rm -f "$MD_DONE_FLAG"
fi

echo ">>> [5/7] 正在清理业务运行目录..."
if [ -d "$OPS_DIR" ]; then
    echo "清理 $OPS_DIR ..."
    rm -rf "$OPS_DIR"
fi

echo ">>> [6/7] 正在重置 OpenClaw 配置与技能..."
if [ -d "$OPENCLAW_HOME" ]; then
    echo "清理 $OPENCLAW_HOME 中的技能与扩展..."
    rm -rf "$OPENCLAW_HOME/skills"
    rm -rf "$OPENCLAW_HOME/extensions/wzq-channel"

    # 使用 jq 直接清理 openclaw.json（最可靠的方式，不依赖 openclaw CLI）
    if [ -f "$OPENCLAW_HOME/openclaw.json" ] && command -v jq >/dev/null 2>&1; then
        echo "使用 jq 重置 openclaw.json 配置项..."
        TMP_JSON=$(mktemp)
        jq 'del(.models.providers["finance-gateway"], .channels["wzq-channel"], .agents.defaults.model.primary, .plugins.entries["wzq-channel"], .env.vars.WZQ_APIKEY) | if .plugins.allow then .plugins.allow |= map(select(. != "wzq-channel")) else . end' "$OPENCLAW_HOME/openclaw.json" > "$TMP_JSON" && mv "$TMP_JSON" "$OPENCLAW_HOME/openclaw.json"
        echo "openclaw.json 配置项已清理。"
    elif command -v openclaw >/dev/null 2>&1; then
        echo "jq 不可用，尝试使用 openclaw config unset..."
        # 预修复被误杀的非法 JSON 结构
        if [ -f "$OPENCLAW_HOME/openclaw.json" ]; then
            sed -i 's/^[[:space:]]*: {/"wzq-channel": {/g' "$OPENCLAW_HOME/openclaw.json"
        fi
        openclaw config unset "models.providers.finance-gateway" || true
        openclaw config unset "channels.wzq-channel" || true
        openclaw config unset "agents.defaults.model.primary" || true
        openclaw config unset "plugins.entries.wzq-channel" || true
        openclaw config unset "plugins.allow" || true
        openclaw config unset "env.vars.WZQ_APIKEY" || true
    else
        echo "警告: jq 和 openclaw 均不可用，无法清理 openclaw.json。请手动编辑 $OPENCLAW_HOME/openclaw.json"
    fi
fi

echo ">>> [7/7] 正在清理环境变量 (.bashrc 永久清理与当前会话)..."
ENV_FILE="$HOME/.bashrc"
if [ -f "$ENV_FILE" ]; then
    echo "从 $ENV_FILE 中移除 WZQ 相关环境变量..."
    sed -i '/export WZQ_APIKEY=/d' "$ENV_FILE"
    sed -i '/export WZQ_LLMKEY=/d' "$ENV_FILE"
    sed -i '/export WZQ_SKILLS_TOKEN=/d' "$ENV_FILE"
    sed -i '/export WZQ_OPS_DIR=/d' "$ENV_FILE"
fi

unset WZQ_APIKEY
unset WZQ_LLMKEY
unset WZQ_SKILLS_TOKEN
unset WZQ_OPS_DIR

echo "环境清理完毕！"
echo "提示：由于 bash 机制，当前已打开的终端窗口环境变量可能仍存在，新打开的窗口将彻底生效。"
