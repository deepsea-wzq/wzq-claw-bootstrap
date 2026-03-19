#!/bin/bash

# OpenClaw 环境清理脚本
# 功能：停止服务、移除配置、清理缓存、卸载 Crontab 任务

set -e

# --- 业务目录定义 ---
OPS_DIR="${WZQ_OPS_DIR:-$HOME/.wzq-claw-ops}"
OPENCLAW_HOME="$HOME/.openclaw"
MONITOR_SCRIPT="$OPS_DIR/bootstrap/monitor_updates.sh"

echo ">>> [1/6] 正在停止 OpenClaw 服务..."
if command -v openclaw >/dev/null 2>&1; then
    openclaw gateway stop || true
    echo "服务已停止。"
else
    echo "未发现 openclaw 命令，跳过停止服务步骤。"
fi

echo ">>> [2/6] 正在移除定时监控任务 (Crontab)..."
(crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT" || true) | crontab - || echo "Crontab 已清理或为空。"

echo ">>> [3/6] 正在还原 wzq-claw-md 替换前的备份文件..."
MD_BACKUP="$OPS_DIR/backup/openclaw-pre-md"
MD_DONE_FLAG="$OPS_DIR/.wzq-claw-md-done"
if [ -d "$MD_BACKUP" ]; then
    BACKUP_COUNT=$(find "$MD_BACKUP" -type f 2>/dev/null | wc -l)
    if [ "$BACKUP_COUNT" -gt 0 ]; then
        echo "发现 $BACKUP_COUNT 个备份文件，正在还原到 $OPENCLAW_HOME ..."
        # 按原目录结构将备份文件覆盖回去
        find "$MD_BACKUP" -type f | while read -r bak; do
            rel="${bak#$MD_BACKUP/}"
            target="$OPENCLAW_HOME/$rel"
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

echo ">>> [4/6] 正在清理业务运行目录..."
if [ -d "$OPS_DIR" ]; then
    echo "清理 $OPS_DIR ..."
    rm -rf "$OPS_DIR"
fi

echo ">>> [5/6] 正在重置 OpenClaw 配置与技能..."
if [ -d "$OPENCLAW_HOME" ]; then
    echo "清理 $OPENCLAW_HOME 中的技能与扩展..."
    rm -rf "$OPENCLAW_HOME/skills"
    rm -rf "$OPENCLAW_HOME/extensions/wzq-channel"
    # 保留主配置文件 openclaw.json 的备份（可选），或者直接清理相关配置项
    # 这里选择清理相关配置项以恢复环境纯净
    if command -v openclaw >/dev/null 2>&1; then
        echo "卸载 wzq-channel 插件..."
        openclaw plugins uninstall wzq-channel || true
    fi

    if [ -f "$OPENCLAW_HOME/openclaw.json" ] && command -v jq >/dev/null 2>&1; then
        echo "使用 jq 重置 openclaw 配置项..."
        # 批量移除相关配置，包括 minimax、wzq-channel 通道及插件相关节点
        # 并从 plugins.allow 列表中过滤掉 wzq-channel
        TMP_JSON=$(mktemp)
        jq 'del(.models.providers["finance-gateway"], .channels["wzq-channel"], .agents.defaults.model.primary, .plugins.entries["wzq-channel"]) | if .plugins.allow then .plugins.allow |= map(select(. != "wzq-channel")) else . end' "$OPENCLAW_HOME/openclaw.json" > "$TMP_JSON" && mv "$TMP_JSON" "$OPENCLAW_HOME/openclaw.json"
    elif command -v openclaw >/dev/null 2>&1; then
        echo "重置 openclaw 配置项..."
        # 使用 unset 彻底移除配置节点，而非设为 null
        openclaw config unset "models.providers.finance-gateway" || true
        openclaw config unset "channels.wzq-channel" || true
        openclaw config unset "agents.defaults.model.primary" || true
        openclaw config unset "plugins.entries.wzq-channel" || true
        openclaw config unset "plugins.allow" || true
    fi
fi

echo ">>> [6/6] 正在清理环境变量 (.bashrc 永久清理与当前会话)..."
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
