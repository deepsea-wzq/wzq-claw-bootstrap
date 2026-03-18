# wzq-claw-bootstrap

`wzq-claw-bootstrap` 是针对腾讯自选股（WZQ）环境设计的 OpenClaw 轻量化引导与运维工具包。它通过一组精简的 Shell 脚本实现跨环境的快速部署、配置注入及自动化运维。

## 1. 核心组件

- **`deploy_entry.sh` (部署入口)**: 客户机器上的首个执行脚本。负责初始化业务目录（`~/.wzq-claw-ops`）、注入必要的环境变量，并拉取完整的运维代码。
- **`init_openclaw.sh` (初始化脚本)**: 核心配置逻辑。完成技能仓库拉取、Channel 插件配置、生成 `openclaw.json` 并启动/重启网关服务。
- **`monitor_updates.sh` (自动监控)**: 通过 Crontab 定时触发。具备 **脚本自更新** 机制，能自动同步代码仓库、部署新技能，并确保服务在更新后自动重启。

## 2. 核心特性

- **一键部署**: 支持通过远程 URL 直接 Pipe 到 Bash 执行。
- **服务自愈**: 监控逻辑会自动执行 `gateway install` 修复 systemd 单元文件，确保服务持续可用。
- **静默更新**: 全量逻辑（脚本自身、技能仓库、插件代码）均支持 Git 增量静默更新。
- **按天滚动日志**: 运维日志存储于 `~/.wzq-claw-ops/logs/`，文件名包含日期，方便回溯。

## 3. 快速开始

在目标机器执行（需预先设置环境变量）：

```bash
WZQ_APIKEY=xxx WZQ_LLMKEY=yyy WZQ_SKILLS_TOKEN=your_github_pat_here bash <(curl -sL https://raw.githubusercontent.com/deepsea-wzq/wzq-claw-bootstrap/main/deploy_entry.sh)
```

## 4. 运维指南

- **日志查看**: `tail -f ~/.wzq-claw-ops/logs/monitor_$(date +%Y%m%d).log`
- **手动触发监控**: `~/.wzq-claw-ops/bootstrap/monitor_updates.sh`
- **配置文件路径**: `~/.openclaw/openclaw.json`

## 5. 项目结构 (现状)

项目目前专注于 Shell 引导逻辑，以保证在各种 Linux 环境下的零依赖执行能力。
- `deploy_entry.sh`: 入口分发
- `init_openclaw.sh`: 初始化安装
- `monitor_updates.sh`: 持续监控与自更新
- `README.md`: 项目说明文件
