#!/bin/bash

# ==========================================================
# 脚本名称: uninstall.sh
# 核心功能: 无痕追踪溯源、全面抹杀幽灵进程、清空宿主脏数据残留
# ==========================================================

# ----------------------------------------------------------
# [权限鉴权] 防止非管理员误触导致组件残留挂起
# ----------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m❌ 权限被拒绝: 卸载 IPGuard 需要最高系统权限。\033[0m"
  echo -e "💡 请切换到 root 用户 (执行 su root 或 sudo -i) 后重新运行指令。"
  exit 1
fi

INSTALL_DIR="/opt/ipguard"

echo "========================================================"
echo "      🗑️ 准备卸载 IPGuard (边缘节点 Edge Agent)"

echo "========================================================"

# ----------------------------------------------------------
# [进程抹杀] 阻塞并卸除底层 Systemd 强绑定服务单元
# ----------------------------------------------------------
echo "[1/4] 正在停止并删除 Systemd 服务..."
if command -v systemctl >/dev/null 2>&1; then
    echo "💡 检测到 Systemd 环境，正在抹除 Systemd 服务单元..."
    # 强制压制守护状态，发送 SIGKILL 剥夺其产生遗言及重启的机会
    systemctl kill --signal=SIGKILL ipguard-agent-daemon.service >/dev/null 2>&1 || true
    systemctl disable --now ipguard-runner.service ipguard-runner.timer \
        ipguard-updater.service ipguard-updater.timer \
        ipguard-report.service ipguard-report.timer \
        ipguard-agent-daemon.service >/dev/null 2>&1
    rm -f /etc/systemd/system/ipguard-runner.service
    rm -f /etc/systemd/system/ipguard-runner.timer
    rm -f /etc/systemd/system/ipguard-updater.service
    rm -f /etc/systemd/system/ipguard-updater.timer
    rm -f /etc/systemd/system/ipguard-report.service
    rm -f /etc/systemd/system/ipguard-report.timer
    rm -f /etc/systemd/system/ipguard-agent-daemon.service
    systemctl daemon-reload
    systemctl reset-failed
else
    echo "💡 未检测到 Systemd，跳过此步骤..."
fi

# ----------------------------------------------------------
# [内存清洗] 全面追踪并镇压游离状态的挂起业务逻辑
# ----------------------------------------------------------
echo "[2/4] 正在终止后台守护进程与所有养护任务..."
pkill -9 -f "tg_daemon.sh" >/dev/null 2>&1
pkill -9 -f "agent_daemon.sh" >/dev/null 2>&1
pkill -9 -f "python3.*webhook.py" >/dev/null 2>&1
pkill -9 -f "webhook.py" >/dev/null 2>&1
pkill -9 -f "runner.sh" >/dev/null 2>&1
pkill -9 -f "updater.sh" >/dev/null 2>&1
pkill -9 -f "tg_report.sh" >/dev/null 2>&1
pkill -9 -f "report.sh" >/dev/null 2>&1
pkill -9 -f "mod_google.sh" >/dev/null 2>&1
pkill -9 -f "mod_trust.sh" >/dev/null 2>&1
pkill -9 -f "mod_quality.sh" >/dev/null 2>&1
pkill -9 -f "ipguard_scheduler.sh" >/dev/null 2>&1

# ----------------------------------------------------------
# [任务清洗] 基于内存管道流彻底擦除系统底层调度劫持
# ----------------------------------------------------------
echo "[3/4] 正在清理系统定时任务 (Cron)..."
# 通过管道原位清洗避免落地到 /tmp，免疫提权或外部劫持探测
crontab -l 2>/dev/null | grep -v "ipguard" | crontab - >/dev/null 2>&1 || true

# 扫除高受限环境 (如 Alpine) 中的额外触发隐患
for CRON_FILE in "/var/spool/cron/crontabs/root" "/etc/crontabs/root"; do
    if [ -f "$CRON_FILE" ]; then
        grep -v "ipguard" "$CRON_FILE" > "${CRON_FILE}.tmp" 2>/dev/null || true
        cat "${CRON_FILE}.tmp" > "$CRON_FILE" 2>/dev/null || true
        rm -f "${CRON_FILE}.tmp" 2>/dev/null
    fi
done
rm -f /etc/local.d/ipguard.start 2>/dev/null
rm -f /etc/local.d/ipguard_scheduler.start 2>/dev/null

if grep -q "ipguard_scheduler.sh" /etc/profile 2>/dev/null; then
    sed -i '/ipguard_scheduler\.sh/d' /etc/profile 2>/dev/null || true
fi

# ----------------------------------------------------------
# [物理销毁] 抹杀持久化特征，销毁系统沙盒痕迹
# ----------------------------------------------------------
echo "[4/4] 正在抹除核心程序、配置文件与系统痕迹..."
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
fi

echo "========================================================"
echo "✅ 卸载彻底完成！IPGuard 已从您的系统中无痕移除。"
echo "💡 提示：如果安装时在防火墙放行了 Webhook 随机端口，请您按需手动关闭。"
echo "👋 感谢您的使用，期待未来再次为您守护资产！"
echo "========================================================"