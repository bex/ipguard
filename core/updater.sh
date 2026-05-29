#!/bin/bash

# ==========================================================
# 脚本名称: updater.sh
# 核心功能: 指纹防惊群错峰轮换、LBS 底层静默分发、深度探针签名防伪
# ==========================================================

INSTALL_DIR="/opt/ipguard"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
UA_TIME_FILE="${INSTALL_DIR}/core/.ua_last_update"

REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"

# --- [底层数据链装载] ---
if [ ! -f "$CONFIG_FILE" ]; then
    exit 1
fi
source "$CONFIG_FILE"

# --- [全局态势日志系统] ---
log() {
    
    mkdir -p "${INSTALL_DIR}/logs"

    local core_msg=$(printf "[%-5s] [%-7s] [%s] %s" "$2" "$1" "$REGION_CODE" "$3")
    # 强制剔除节点宿主机本地时差，严格对齐指挥部 UTC 基准
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $core_msg" >> "$LOG_FILE"

    if command -v logger >/dev/null 2>&1; then
        logger -t ipguard "$core_msg"
    else
        echo "$core_msg"
    fi
}

log "Updater" "INFO " "========== 触发后台静默 OTA 热数据更新 =========="

# ==========================================================
# [网络路由锁定] 构建强锚定出站屏障，彻底阻断跨协议溢出逃逸
# ==========================================================
CURL_CMD="curl -${IP_PREF:-4} -sL"

if [ -n "$BIND_IP" ]; then
    RAW_BIND_IP=$(echo "$BIND_IP" | tr -d '[]')
    if ! ip addr show 2>/dev/null | grep -qw "$RAW_BIND_IP"; then
        log "Updater" "WARN " "检测到绑定的出口 IP ($RAW_BIND_IP) 已丢失，自动退回默认路由！"
    else
        CURL_CMD="$CURL_CMD --interface $RAW_BIND_IP"
    fi
fi

# ==========================================================
# [指纹池滚动更新] 错峰调度防惊群风暴算法
# 强制设定 30 天超长冷静期以规避 Github 限流与特征同构
# ==========================================================
NOW=$(date +%s)
LAST_UPDATE=0

if [ -f "$UA_TIME_FILE" ]; then
    LAST_UPDATE=$(cat "$UA_TIME_FILE" | tr -d '\r\n')
fi

if ! [[ "$LAST_UPDATE" =~ ^[0-9]+$ ]]; then
    LAST_UPDATE=0
fi

DIFF=$((NOW - LAST_UPDATE))

if [ "$DIFF" -ge 2592000 ] || [ "$LAST_UPDATE" -eq 0 ]; then
    TMP_UA="/tmp/ipguard_ua.txt"
    $CURL_CMD "${REPO_RAW_URL}/data/user_agents.txt" -o "$TMP_UA"
    
    if [ -s "$TMP_UA" ]; then
        mv "$TMP_UA" "${INSTALL_DIR}/data/user_agents.txt"
        echo "$NOW" > "$UA_TIME_FILE"
        log "Updater" "INFO " "✅ 设备指纹池 (User-Agents) 30天错峰滚动更新成功"
    else
        log "Updater" "WARN " "❌ UA 池拉取失败，保留本地旧数据防崩溃"
        rm -f "$TMP_UA"
    fi
else
    DAYS_LEFT=$(((2592000 - DIFF) / 86400))
    log "Updater" "INFO " "⏳ 设备指纹池处于 30 天静默期 (剩余约 ${DAYS_LEFT} 天)，跳过拉取"
fi

# ----------------------------------------------------------
# [态势感知热更] 动态注入本土高权热搜及战区 LBS 规则
# ----------------------------------------------------------
TMP_KW="/tmp/ipguard_kw.txt"
$CURL_CMD "${REPO_RAW_URL}/data/keywords/kw_${REGION_CODE}.txt" -o "$TMP_KW"

if [ -s "$TMP_KW" ]; then
    mv "$TMP_KW" "${INSTALL_DIR}/data/keywords/kw_${REGION_CODE}.txt"
    log "Updater" "INFO " "✅ 区域搜索词库 (kw_${REGION_CODE}) 每日同步成功"
else
    log "Updater" "WARN " "❌ 搜索词库拉取失败，保留本地旧数据防崩溃"
    rm -f "$TMP_KW"
fi

REGION_JSON_FILE=$(find "${INSTALL_DIR}/data/regions" -name "*.json" 2>/dev/null | head -n 1)

if [ -n "$REGION_JSON_FILE" ] && [ -f "$REGION_JSON_FILE" ]; then
    REL_PATH=${REGION_JSON_FILE#*${INSTALL_DIR}/}
    TMP_JSON="/tmp/ipguard_region.json"
    
    $CURL_CMD "${REPO_RAW_URL}/${REL_PATH}" -o "$TMP_JSON"
    
    if [ -s "$TMP_JSON" ]; then
        mv "$TMP_JSON" "$REGION_JSON_FILE"
        log "Updater" "INFO " "✅ 核心战区规则库 ($REL_PATH) 每日同步成功"
    else
        log "Updater" "WARN " "❌ 战区规则库拉取失败，保留本地旧数据"
        rm -f "$TMP_JSON"
    fi
fi

# [standalone] The IP-quality probe (ip_probe.sh) is fetched ONCE at install /
# first startup and then reused. It is intentionally NOT re-downloaded on a
# schedule here -- avoids a daily third-party fetch and supply-chain exposure.
# mod_quality.sh still self-heals (re-fetches) only if the file is missing.

# ==========================================================
# [空间瘦身] 长效健康清理与爆栈预防机制
# ==========================================================
if [ -f "$LOG_FILE" ]; then
    tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "$LOG_FILE"
    log "Updater" "INFO " "🧹 系统日志已完成定期清理瘦身 (保留最新 2000 行)"
fi

log "Updater" "INFO " "========== OTA 养料注入与系统维护结束 =========="