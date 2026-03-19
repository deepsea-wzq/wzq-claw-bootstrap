#!/bin/bash

# OpenClaw 客户环境一键部署入口脚本 (业务独立目录版)
# 功能：建立业务目录 -> 注入变量 -> 下载 bootstrap -> 启动初始化

set -e

# --- 业务目录规划 ---
OPS_DIR="$HOME/.wzq-claw-ops"
LOG_DIR="$OPS_DIR/logs"
BOOTSTRAP_DIR="$OPS_DIR/bootstrap"
CURRENT_DATE=$(date +%Y%m%d)
LOG_FILE="$LOG_DIR/deploy_$CURRENT_DATE.log"

# 初始化业务目录
mkdir -p "$LOG_DIR"
echo ">>> 日志将记录在: $LOG_FILE"

# 将后续输出同时输出到屏幕和日志文件
exec > >(tee -a "$LOG_FILE") 2>&1

echo ">>> [1/4] 检查并获取业务变量..."

# 建议通过: WZQ_APIKEY=xxx WZQ_LLMKEY=yyy WZQ_SKILLS_TOKEN=zzz bash deploy_entry.sh 方式调用
API_KEY=${WZQ_APIKEY}
LLM_KEY=${WZQ_LLMKEY}
SKILLS_TOKEN=${WZQ_SKILLS_TOKEN}

if [ -z "$API_KEY" ] || [ -z "$LLM_KEY" ]; then
    echo "错误: 必须提供 WZQ_APIKEY 和 WZQ_LLMKEY"
    echo "用法: WZQ_APIKEY=xxx WZQ_LLMKEY=yyy $0"
    exit 1
fi

echo ">>> [2/4] 正在注入环境变量到用户环境..."
ENV_FILE="$HOME/.bashrc"
# 确保本地二进制目录在 PATH 中
mkdir -p "$HOME/.local/bin"

inject_env() {
    local key=$1
    local value=$2
    if grep -q "export $key=" "$ENV_FILE"; then
        sed -i "s|export $key=.*|export $key=\"$value\"|g" "$ENV_FILE"
    else
        echo "export $key=\"$value\"" >> "$ENV_FILE"
    fi
    export "$key"="$value"
}

inject_env "WZQ_APIKEY" "$API_KEY"
inject_env "WZQ_LLMKEY" "$LLM_KEY"
[ -n "$SKILLS_TOKEN" ] && inject_env "WZQ_SKILLS_TOKEN" "$SKILLS_TOKEN"
inject_env "WZQ_OPS_DIR" "$OPS_DIR"
# 修改 inject_env 调用方式，对 PATH 使用特殊的检查逻辑
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    inject_env "PATH" "$HOME/.local/bin:\$PATH"
fi

# --- 生成独立的环境变量文件，供 crontab 等非交互式环境使用 ---
# 该文件不依赖 .bashrc，脚本直接 source 即可获取所有业务变量
ENV_SH="$OPS_DIR/env.sh"
echo "正在生成环境变量文件: $ENV_SH"
cat > "$ENV_SH" <<ENVEOF
#!/bin/bash
# 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')，由 deploy_entry.sh 写入
# 供 monitor_updates.sh 等 crontab 触发的脚本 source 使用

export WZQ_APIKEY="$API_KEY"
export WZQ_LLMKEY="$LLM_KEY"
export WZQ_SKILLS_TOKEN="$SKILLS_TOKEN"
export WZQ_OPS_DIR="$OPS_DIR"

# NVM (Node.js 版本管理)
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"

# PNPM
export PNPM_HOME="\$HOME/.local/share/pnpm"
case ":\$PATH:" in
  *":\$PNPM_HOME:"*) ;;
  *) export PATH="\$PNPM_HOME:\$PATH" ;;
esac

# 确保常用路径在 PATH 中
export PATH="\$HOME/.local/bin:/usr/local/bin:\$PATH"
ENVEOF
chmod 600 "$ENV_SH"
echo "环境变量文件已生成 (权限: 600)"

echo ">>> [2.5/4] 正在安装 SkillHub CLI 工具..."
if ! command -v skillhub &> /dev/null; then
    timeout 120s bash -c 'curl -fsSL --connect-timeout 15 --max-time 90 https://skillhub-1388575217.cos.ap-guangzhou.myqcloud.com/install/install.sh | bash -s -- --cli-only' || echo "SkillHub 安装失败，稍后尝试通过初始化脚本安装"
else
    echo "SkillHub CLI 已安装，跳过"
fi

echo ">>> [3/4] 正在下载 wzq-claw-bootstrap 运维代码"
rm -rf "$BOOTSTRAP_DIR"
timeout 60s git clone --depth 1 https://github.com/deepsea-wzq/wzq-claw-bootstrap "$BOOTSTRAP_DIR"

echo ">>> [4/4] 启动初始化脚本..."
cd "$BOOTSTRAP_DIR"
chmod +x init_openclaw.sh monitor_updates.sh manage_skills.sh

# 传递变量并执行
./init_openclaw.sh

echo ">>> 部署入口脚本执行完毕。业务目录: $OPS_DIR"
