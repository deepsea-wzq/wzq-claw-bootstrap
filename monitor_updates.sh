#!/bin/bash

# OpenClaw 监控与自动更新脚本 (业务独立目录版)
# 职责：检查插件、技能仓库及运维代码更新 -> 自动同步并重启

# --- 业务目录配置 ---
OPS_DIR="${WZQ_OPS_DIR:-$HOME/.wzq-claw-ops}"
BOOTSTRAP_DIR="$OPS_DIR/bootstrap"
LOG_DIR="$OPS_DIR/logs"
SKILLS_CACHE_DIR="$OPS_DIR/cache/deepsea-skills"
EXT_CACHE_DIR="$OPS_DIR/cache/extensions"
OPENCLAW_HOME="$HOME/.openclaw"
CURRENT_DATE=$(date +%Y%m%d)
LOG_FILE="$LOG_DIR/monitor_$CURRENT_DATE.log"

# 初始化日志记录
mkdir -p "$LOG_DIR"
exec >> "$LOG_FILE" 2>&1

echo "--- $(date '+%Y-%m-%d %H:%M:%S') 开始检查更新 ---"

# --- 通用工具函数 ---
check_git_update() {
    local dir=$1
    if [ ! -d "$dir" ]; then return 1; fi
    
    git -C "$dir" fetch --quiet
    LOCAL=$(git -C "$dir" rev-parse @)
    REMOTE=$(git -C "$dir" rev-parse '@{u}')
    
    if [ "$LOCAL" != "$REMOTE" ]; then
        return 0 # 有更新
    else
        return 1 # 无更新
    fi
}

NEED_RESTART=0

# --- 0. 脚本自更新机制 (运维代码变更) ---
if check_git_update "$BOOTSTRAP_DIR"; then
    echo "检测到运维脚本更新, 正在拉取最新代码..."
    git -C "$BOOTSTRAP_DIR" pull --quiet
    echo "运维脚本已更新，继续执行后续检查流程。"
    NEED_RESTART=1
fi

# --- 1. 检查 wzq-channel 插件更新 ---
EXT_DIR="$EXT_CACHE_DIR/wzq-channel"
if [ -d "$EXT_DIR/.git" ]; then
    if check_git_update "$EXT_DIR"; then
        echo "检测到插件 wzq-channel 更新, 正在拉取并重新安装..."
        git -C "$EXT_DIR" pull --quiet
        
        # 关键修复：处理可能存在的死锁。如果当前插件更新导致配置校验失败（CLI 无法启动），直接修正配置文件
        CLAW_CONFIG="$OPENCLAW_HOME/openclaw.json"
        if [ -f "$CLAW_CONFIG" ]; then
            if ! openclaw config get "plugins.allow" &>/dev/null; then
                echo "检测到 wzq-channel 可能导致配置死锁，正在执行强力清理以解除限制..."
                sed -i 's/"wzq-channel"//g; s/,,/,/g; s/\[,/[/g; s/,]/]/g' "$CLAW_CONFIG"
            fi
        fi
        
        echo "正在执行插件手动安装 (复制源码与安装依赖)..."
        PLUGIN_TARGET_DIR="$OPENCLAW_HOME/extensions/wzq-channel"
        mkdir -p "$OPENCLAW_HOME/extensions"
        rm -rf "$PLUGIN_TARGET_DIR"
        cp -r "$EXT_DIR" "$PLUGIN_TARGET_DIR"

        # 手动安装依赖 (优先使用 npm)
        echo "正在执行插件依赖安装 (npm install)..."
        (cd "$PLUGIN_TARGET_DIR" && {
            if command -v npm &> /dev/null; then
                npm install
            elif command -v pnpm &> /dev/null; then
                echo "警告: npm 不可用，回退到 pnpm install --prod"
                pnpm install --prod
            else
                echo "错误: 未找到 npm 或 pnpm"
                exit 1
            fi
        }) || { echo "插件依赖安装失败"; exit 1; }
        
        # 补齐配置：增量启用插件并加入信任名单
        openclaw config set "plugins.enabled" true
        openclaw config set "plugins.entries.wzq-channel.enabled" true
        
        CURRENT_ALLOW=$(openclaw config get "plugins.allow" 2>/dev/null || echo "[]")
        if [[ $CURRENT_ALLOW != *"wzq-channel"* ]]; then
            if [ "$CURRENT_ALLOW" == "[]" ] || [ -z "$CURRENT_ALLOW" ]; then
                openclaw config set "plugins.allow" "[\"wzq-channel\"]" --strict-json
            else
                NEW_ALLOW="${CURRENT_ALLOW%]*},\"wzq-channel\"]"
                openclaw config set "plugins.allow" "$NEW_ALLOW" --strict-json
            fi
        fi
        
        NEED_RESTART=1
    fi
fi

# --- 2. 检查技能仓库更新与同步 (调用管理脚本) ---
set +e # 临时关闭，以便手动检查 exit code
bash "$BOOTSTRAP_DIR/manage_skills.sh"
SKILL_SYNC_RC=$?
set -e

if [ $SKILL_SYNC_RC -eq 2 ]; then
    NEED_RESTART=1
fi

# --- 4. 如果有更新，执行重启 ---
if [ $NEED_RESTART -eq 1 ]; then
    echo "执行服务重启以应用更新..."
    openclaw gateway restart
    echo "更新处理完成。"
else
    echo "未发现更新。"
fi
