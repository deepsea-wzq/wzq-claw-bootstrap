#!/bin/bash

# OpenClaw 监控与自动更新脚本 (业务独立目录版)
# 职责：检查插件、技能仓库及运维代码更新 -> 自动同步并重启

# --- 环境初始化 ---
# 显式加载用户环境变量，确保 Crontab 等非交互式环境下 WZQ_SKILLS_TOKEN 可用
if [ -f "$HOME/.bashrc" ]; then
    # shellcheck source=/dev/null
    source "$HOME/.bashrc"
fi

# --- 业务目录配置 ---
OPS_DIR="${WZQ_OPS_DIR:-$HOME/.wzq-claw-ops}"
# 优先使用脚本当前所在目录，以便在 bootstrap/ 目录下也能正常运行
BOOTSTRAP_DIR="$(cd "$(dirname "$0")" && pwd)"
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
    
    timeout 60s git -C "$dir" fetch --quiet || { echo "git fetch 超时或失败: $dir"; return 1; }
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
    timeout 60s git -C "$BOOTSTRAP_DIR" pull --quiet || echo "警告: 运维脚本 git pull 超时或失败"
    echo "运维脚本已更新，继续执行后续检查流程。"
    NEED_RESTART=1
fi

# --- 1. 检查 wzq-channel 插件更新 ---
EXT_DIR="$EXT_CACHE_DIR/wzq-channel"
if [ -d "$EXT_DIR/.git" ]; then
    if check_git_update "$EXT_DIR"; then
        echo "检测到插件 wzq-channel 更新, 正在拉取并重新安装..."
        timeout 60s git -C "$EXT_DIR" pull --quiet || { echo "警告: 插件 git pull 超时或失败"; }
        
        # 关键修复：处理可能存在的死锁。如果当前插件更新导致配置校验失败（CLI 无法启动），直接修正配置文件
        CLAW_CONFIG="$OPENCLAW_HOME/openclaw.json"
        if [ -f "$CLAW_CONFIG" ]; then
            if ! timeout 15s openclaw config get "plugins.allow" &>/dev/null; then
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
                timeout 180s npm install
            elif command -v pnpm &> /dev/null; then
                echo "警告: npm 不可用，回退到 pnpm install --prod"
                timeout 180s pnpm install --prod
            else
                echo "错误: 未找到 npm 或 pnpm"
                exit 1
            fi
        }) || { echo "插件依赖安装失败"; exit 1; }
        
        # 补齐配置：增量启用插件并加入信任名单
        timeout 15s openclaw config set "plugins.enabled" true
        timeout 15s openclaw config set "plugins.entries.wzq-channel.enabled" true
        
        CURRENT_ALLOW=$(timeout 15s openclaw config get "plugins.allow" 2>/dev/null || echo "[]")
        if [[ $CURRENT_ALLOW != *"wzq-channel"* ]]; then
            if [ "$CURRENT_ALLOW" == "[]" ] || [ -z "$CURRENT_ALLOW" ]; then
                timeout 15s openclaw config set "plugins.allow" "[\"wzq-channel\"]" --strict-json
            else
                NEW_ALLOW="${CURRENT_ALLOW%]*},\"wzq-channel\"]"
                timeout 15s openclaw config set "plugins.allow" "$NEW_ALLOW" --strict-json
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
    timeout 60s openclaw gateway restart || echo "警告: gateway 重启超时或失败"
    echo "更新处理完成。"
else
    echo "未发现更新。"
fi
