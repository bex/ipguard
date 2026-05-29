#!/bin/bash

# ==========================================================
# install.sh  (standalone edition)
# Deploys the IPGuard edge agent from a LOCAL clone of this
# repository. No master / Telegram / webhook / telemetry.
#
# Interaction is minimal: you only pick the geographic region to
# anchor to (continent -> country -> state). The city is auto-selected
# (first/default), and everything else -- egress IP, node id, schedule
# -- is detected and configured automatically.
#
# The agent then maintains the host IP reputation on a schedule:
#   - runner.sh   : picks mod_google / mod_trust each cycle (every 20 min)
#   - updater.sh  : refreshes data (UA pool, keywords, probe) daily
#   - report.sh   : prints a daily local summary (journal + log) daily
#   - mod_quality : on-demand "deep sea sonar" IP quality check
#
# Usage (run from inside the cloned repo):
#   sudo bash core/install.sh
#
# To uninstall:
#   sudo bash core/uninstall.sh
# ==========================================================

set -u

# ----------------------------------------------------------
# Root check
# ----------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m[X] Permission denied: deploying IPGuard requires root.\033[0m"
  echo -e "    Switch to root (su root / sudo -i) and re-run."
  exit 1
fi

# ----------------------------------------------------------
# Locate the repository this script was launched from.
# Everything is copied from here -- nothing is fetched from a
# remote command center.
# ----------------------------------------------------------
SELF="$0"
command -v readlink >/dev/null 2>&1 && SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -f "$REPO_ROOT/data/map.json" ] || [ ! -f "$REPO_ROOT/core/runner.sh" ]; then
  echo -e "\033[31m[X] Could not find the repository payload.\033[0m"
  echo -e "    Run this script from inside the cloned repo, e.g.:"
  echo -e "      git clone <repo> && cd <repo> && sudo bash core/install.sh"
  exit 1
fi

INSTALL_DIR="/opt/ipguard"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
MAP_FILE="${REPO_ROOT}/data/map.json"

# Disposable scratch dir, wiped on exit.
SECURE_TMP=$(mktemp -d /tmp/ips_install.XXXXXX)
trap 'rm -rf "$SECURE_TMP"' EXIT HUP INT QUIT TERM

is_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [ -d /run/systemd/system ] || return 1
    return 0
}

get_os_info() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$PRETTY_NAME"
    else
        uname -srm
    fi
}

echo -e "\n======================================"
echo -e "  IPGuard (standalone) installer"
echo -e "--------------------------------------"
echo -e "  OS        : $(get_os_info)"
if is_systemd; then
    echo -e "  Init      : systemd"
else
    echo -e "  Init      : non-systemd (cron / loop fallback)"
fi
echo -e "  Source    : $REPO_ROOT"
echo -e "======================================\n"

# (this standalone build does not carry a version string)

# ==========================================================
# [1/5] Dependencies
# ==========================================================
echo -e "[1/5] Checking base dependencies (curl, jq, cron, procps)..."
REQUIRED_CMDS=("curl" "jq" "crontab" "pgrep")
MISSING_CMDS=()
for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING_CMDS+=("$cmd")
done

if [ ${#MISSING_CMDS[@]} -gt 0 ]; then
    echo "    Missing: ${MISSING_CMDS[*]} -- attempting auto-install..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y --no-install-recommends curl jq cron procps >/dev/null 2>&1
        systemctl enable cron >/dev/null 2>&1 && systemctl start cron >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 || command -v microdnf >/dev/null 2>&1; then
        PKG_MGR="yum"
        command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf"
        command -v microdnf >/dev/null 2>&1 && PKG_MGR="microdnf"
        $PKG_MGR install -y epel-release >/dev/null 2>&1 || true
        $PKG_MGR install -y curl jq cronie procps-ng
        systemctl enable crond >/dev/null 2>&1 && systemctl start crond >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl jq cronie procps bash || apk add --no-cache curl jq procps bash
        mkdir -p /var/spool/cron/crontabs
        rc-update add crond default >/dev/null 2>&1
        service crond start >/dev/null 2>&1
    elif command -v pacman >/dev/null 2>&1; then
        pacman -S --needed --noconfirm curl jq cronie procps-ng >/dev/null 2>&1
        systemctl enable cronie >/dev/null 2>&1 && systemctl start cronie >/dev/null 2>&1
    else
        echo -e "\033[31m[X] Unknown package manager. Install manually: curl jq cron procps\033[0m"
        exit 1
    fi
fi

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "\033[31m[X] Fatal: required command '$cmd' is still missing.\033[0m"
        exit 1
    fi
done
echo -e "\033[32m[OK] Dependencies ready.\033[0m"

# ==========================================================
# [2/5] Region selection (continent -> country -> state; city auto)
# ==========================================================
echo -e "\n[2/5] Select the region to anchor this node to."

echo -e "\n  Continent:"
jq -r '.continents[] | "\(.id)|\(.name)"' "$MAP_FILE" > "${SECURE_TMP}/continents.txt"
i=1; CONT_MAP=()
while IFS="|" read -r cont_id cont_name; do
    echo "    $i) $cont_name"
    CONT_MAP[$i]="$cont_id"
    ((i++))
done < "${SECURE_TMP}/continents.txt"
read -p "  Enter choice [1-$((i-1))] (default 1): " CONT_SEL
CONT_SEL=${CONT_SEL:-1}
CONT_ID="${CONT_MAP[$CONT_SEL]:-}"
[ -z "$CONT_ID" ] && CONT_ID="${CONT_MAP[1]}"

echo -e "\n  Country / region:"
jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | \"\(.id)|\(.name)|\(.keyword_file)\"" "$MAP_FILE" > "${SECURE_TMP}/countries.txt"
i=1; COUNTRY_MAP=(); KEYWORD_MAP=()
while IFS="|" read -r c_id c_name k_file; do
    echo "    $i) $c_name"
    COUNTRY_MAP[$i]="$c_id"
    KEYWORD_MAP[$i]="$k_file"
    ((i++))
done < "${SECURE_TMP}/countries.txt"
read -p "  Enter choice [1-$((i-1))] (default 1): " C_SEL
C_SEL=${C_SEL:-1}
COUNTRY_ID="${COUNTRY_MAP[$C_SEL]:-}"
KEYWORD_FILE="${KEYWORD_MAP[$C_SEL]:-}"
if [ -z "$COUNTRY_ID" ]; then
    COUNTRY_ID="${COUNTRY_MAP[1]}"
    KEYWORD_FILE="${KEYWORD_MAP[1]}"
fi
REGION_CODE="$COUNTRY_ID"

echo -e "\n  State / province:"
jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | select(.id==\"$COUNTRY_ID\") | .states[] | \"\(.id)|\(.name)\"" "$MAP_FILE" > "${SECURE_TMP}/states.txt"
STATE_COUNT=$(wc -l < "${SECURE_TMP}/states.txt")
if [ "$STATE_COUNT" -eq 1 ]; then
    IFS="|" read -r STATE_ID STATE_NAME < "${SECURE_TMP}/states.txt"
    echo "    (single option [$STATE_NAME], auto-selected)"
else
    i=1; STATE_MAP=()
    while IFS="|" read -r s_id s_name; do
        echo "    $i) $s_name"
        STATE_MAP[$i]="$s_id"
        ((i++))
    done < "${SECURE_TMP}/states.txt"
    read -p "  Enter choice [1-$((i-1))] (default 1): " S_SEL
    S_SEL=${S_SEL:-1}
    STATE_ID="${STATE_MAP[$S_SEL]:-}"
    [ -z "$STATE_ID" ] && STATE_ID="${STATE_MAP[1]}"
fi

# City: no prompt -- auto-select the first (default) city for this state.
jq -r ".continents[] | select(.id==\"$CONT_ID\") | .countries[] | select(.id==\"$COUNTRY_ID\") | .states[] | select(.id==\"$STATE_ID\") | .cities[] | \"\(.id)|\(.name)\"" "$MAP_FILE" > "${SECURE_TMP}/cities.txt"
IFS="|" read -r CITY_ID CITY_NAME < "${SECURE_TMP}/cities.txt"
if [ -z "${CITY_ID:-}" ]; then
    echo -e "\033[31m[X] No city found for the selected region.\033[0m"
    exit 1
fi
echo -e "\n  City: auto-selected [\033[32m${CITY_NAME:-$CITY_ID}\033[0m]"

# Both maintenance modules on by default (runner picks per cycle).
ENABLE_GOOGLE="true"
ENABLE_TRUST="true"

# ==========================================================
# [3/5] Egress IP auto-detection (IPv4 preferred), no prompt
# ==========================================================
echo -e "\n[3/5] Detecting egress IP..."
DETECT_V4=$( (curl -4 -s -m 3 api.ip.sb/ip || curl -4 -s -m 3 ifconfig.me || curl -4 -s -m 3 ipv4.icanhazip.com) 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n 1 | tr -d '[:space:]')
DETECT_V6=$( (curl -6 -s -m 3 api.ip.sb/ip || curl -6 -s -m 3 ifconfig.me || curl -6 -s -m 3 ipv6.icanhazip.com) 2>/dev/null | grep -E "^[0-9a-fA-F:]+.*:" | head -n 1 | tr -d '[:space:]')

if [ -n "$DETECT_V4" ]; then
    PUBLIC_IP="$DETECT_V4"; IP_PREF="4"
elif [ -n "$DETECT_V6" ]; then
    PUBLIC_IP="$DETECT_V6"; IP_PREF="6"
else
    PUBLIC_IP="127.0.0.1"; IP_PREF="4"
    echo -e "\033[33m    [!] Could not auto-detect a public IP; using a placeholder.\033[0m"
fi

# Bracket-wrap IPv6 for downstream tooling
if [[ "$PUBLIC_IP" == *":"* ]] && [[ "$PUBLIC_IP" != *"["* ]]; then
    SAFE_PUBLIC_IP="[${PUBLIC_IP}]"
else
    SAFE_PUBLIC_IP="$PUBLIC_IP"
fi

# Decide whether to pin curl to the interface (skip under NAT)
RAW_TEST_IP=$(echo "$SAFE_PUBLIC_IP" | tr -d '[]')
if [[ "$RAW_TEST_IP" == *":"* ]]; then
    TEST_TARGET="https://[2606:4700:4700::1111]"
else
    TEST_TARGET="https://1.1.1.1"
fi
if curl --interface "$RAW_TEST_IP" -sI -m 3 "$TEST_TARGET" >/dev/null 2>&1; then
    BIND_IP="$SAFE_PUBLIC_IP"
    echo -e "\033[32m[OK] Egress anchor: $SAFE_PUBLIC_IP (interface pinned)\033[0m"
else
    BIND_IP=""
    echo -e "\033[32m[OK] Egress anchor: $SAFE_PUBLIC_IP (NAT / kernel routing)\033[0m"
fi

# Node identity (no prompt; alias == derived node name)
IP_HASH=$(echo "${SAFE_PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
NODE_NAME="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${IP_HASH}"
NODE_ALIAS="$NODE_NAME"

# Region rule file (from local clone)
SRC_REGION_JSON="${REPO_ROOT}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json"
if [ ! -s "$SRC_REGION_JSON" ]; then
    echo -e "\033[31m[X] Region rule file missing: $SRC_REGION_JSON\033[0m"
    exit 1
fi
REGION_NAME=$(jq -r '.region_name' "$SRC_REGION_JSON")
BASE_LAT=$(jq -r '.google_module.base_lat' "$SRC_REGION_JSON")
BASE_LON=$(jq -r '.google_module.base_lon' "$SRC_REGION_JSON")
LANG_PARAMS=$(jq -r '.google_module.lang_params' "$SRC_REGION_JSON")
VALID_URL_SUFFIX=$(jq -r '.google_module.valid_url_suffix' "$SRC_REGION_JSON")

# ==========================================================
# [4/5] Deploy core engine + data from the local clone
# ==========================================================
echo -e "\n[4/5] Deploying engine and data into ${INSTALL_DIR}..."

# Stop any running instance (including legacy services from upstream installs)
if is_systemd; then
    systemctl stop ipguard-runner.timer ipguard-updater.timer \
        ipguard-report.timer ipguard-agent-daemon.service >/dev/null 2>&1 || true
    systemctl disable ipguard-agent-daemon.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/ipguard-agent-daemon.service 2>/dev/null
fi
pkill -9 -f "webhook.py"            >/dev/null 2>&1 || true
pkill -9 -f "agent_daemon.sh"       >/dev/null 2>&1 || true
pkill -9 -f "ipguard/core"      >/dev/null 2>&1 || true
pkill -9 -f "ipguard_scheduler.sh" >/dev/null 2>&1 || true

# Clean previous schedule entries (cron) before redeploy
crontab -l 2>/dev/null | grep -v "ipguard" > "${SECURE_TMP}/cron_clean" || true
[ -f "${SECURE_TMP}/cron_clean" ] && crontab "${SECURE_TMP}/cron_clean" >/dev/null 2>&1
rm -f "${SECURE_TMP}/cron_clean"
for CRON_FILE in "/var/spool/cron/crontabs/root" "/etc/crontabs/root"; do
    if [ -f "$CRON_FILE" ]; then
        grep -v "ipguard" "$CRON_FILE" > "${CRON_FILE}.tmp" 2>/dev/null || true
        cat "${CRON_FILE}.tmp" > "$CRON_FILE" 2>/dev/null || true
        rm -f "${CRON_FILE}.tmp" 2>/dev/null
    fi
done
rm -f /etc/local.d/ipguard.start /etc/local.d/ipguard_scheduler.start 2>/dev/null

mkdir -p "${INSTALL_DIR}/core" "${INSTALL_DIR}/data/keywords" "${INSTALL_DIR}/logs"

# Stage core scripts in a temp dir, then swap in atomically.
TMP_CORE="${SECURE_TMP}/core_update"
mkdir -p "$TMP_CORE"
for f in runner.sh updater.sh report.sh mod_google.sh mod_trust.sh mod_quality.sh uninstall.sh; do
    if [ ! -s "${REPO_ROOT}/core/${f}" ]; then
        echo -e "\033[31m[X] Missing core script in clone: core/${f}\033[0m"
        exit 1
    fi
    cp -f "${REPO_ROOT}/core/${f}" "${TMP_CORE}/${f}"
done
rm -rf "${INSTALL_DIR}/core" 2>/dev/null
mv "$TMP_CORE" "${INSTALL_DIR}/core"
chmod +x "${INSTALL_DIR}/core/"*.sh

# Fetch the IP-quality probe (ip.sh) ONCE now and reuse it. updater.sh does
# NOT re-download it on a schedule; mod_quality.sh only re-fetches if missing.
PROBE="${INSTALL_DIR}/core/ip_probe.sh"
if [ ! -s "$PROBE" ] || ! grep -q "xykt" "$PROBE" 2>/dev/null; then
    echo "    Fetching IP quality probe (ip.sh) once..."
    curl -fsSL -m 20 "https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh" -o "$PROBE" 2>/dev/null || true
    if grep -q "xykt" "$PROBE" 2>/dev/null; then
        chmod +x "$PROBE"
        echo -e "\033[32m[OK] IP quality probe installed.\033[0m"
    else
        rm -f "$PROBE" 2>/dev/null
        echo -e "\033[33m    [!] Probe fetch failed; mod_quality will retry on first use.\033[0m"
    fi
fi

# Data: UA pool + keyword file + region rule file (logs are preserved)
cp -f "${REPO_ROOT}/data/user_agents.txt" "${INSTALL_DIR}/data/user_agents.txt" 2>/dev/null || true
[ -n "${KEYWORD_FILE:-}" ] && cp -f "${REPO_ROOT}/data/keywords/${KEYWORD_FILE}" "${INSTALL_DIR}/data/keywords/${KEYWORD_FILE}" 2>/dev/null || true
mkdir -p "${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}"
cp -f "$SRC_REGION_JSON" "${INSTALL_DIR}/data/regions/${COUNTRY_ID}/${STATE_ID}/${CITY_ID}.json"

# Write config
cat > "$CONFIG_FILE" << EOF
# IPGuard standalone config (generated: $(date '+%Y-%m-%d %H:%M:%S'))
REGION_CODE="$REGION_CODE"
REGION_NAME="$REGION_NAME"
BASE_LAT="$BASE_LAT"
BASE_LON="$BASE_LON"
LANG_PARAMS="$LANG_PARAMS"
VALID_URL_SUFFIX="$VALID_URL_SUFFIX"

# Module switches
ENABLE_GOOGLE="$ENABLE_GOOGLE"
ENABLE_TRUST="$ENABLE_TRUST"

INSTALL_DIR="$INSTALL_DIR"
LOG_FILE="${INSTALL_DIR}/logs/ipguard.log"

IP_PREF="$IP_PREF"
PUBLIC_IP="$SAFE_PUBLIC_IP"
BIND_IP="$BIND_IP"

NODE_NAME="$NODE_NAME"
NODE_ALIAS="$NODE_ALIAS"
EOF
chmod 600 "$CONFIG_FILE"

# ==========================================================
# [5/5] Scheduling
# ==========================================================
echo -e "\n[5/5] Installing scheduler..."
DEPLOY_UTC_HOUR=$(date -u +%H)
DEPLOY_UTC_MIN=$(date -u +%M)
echo "$(date -u +%s)" > "${INSTALL_DIR}/core/.ua_last_update"

if is_systemd; then
    echo "    systemd detected, installing native timers..."

    cat > /etc/systemd/system/ipguard-runner.service << EOF
[Unit]
Description=IPGuard Runner Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ipguard
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/runner.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/ipguard-runner.timer << EOF
[Unit]
Description=Timer for IPGuard Runner Service
[Timer]
OnCalendar=*:0/20
RandomizedDelaySec=180
Persistent=true
Unit=ipguard-runner.service
[Install]
WantedBy=timers.target
EOF

    cat > /etc/systemd/system/ipguard-updater.service << EOF
[Unit]
Description=IPGuard Updater Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ipguard
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/updater.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/ipguard-updater.timer << EOF
[Unit]
Description=Timer for IPGuard Updater Service
[Timer]
OnCalendar=*-*-* ${DEPLOY_UTC_HOUR}:${DEPLOY_UTC_MIN}:00 UTC
Persistent=true
Unit=ipguard-updater.service
[Install]
WantedBy=timers.target
EOF

    cat > /etc/systemd/system/ipguard-report.service << EOF
[Unit]
Description=IPGuard Local Report Service
After=network.target
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ipguard
Type=oneshot
ExecStart=/bin/bash ${INSTALL_DIR}/core/report.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
EOF

    cat > /etc/systemd/system/ipguard-report.timer << EOF
[Unit]
Description=Timer for IPGuard Local Report Service
[Timer]
OnCalendar=*-*-* 16:00:00 UTC
Persistent=true
Unit=ipguard-report.service
[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now ipguard-runner.timer ipguard-updater.timer ipguard-report.timer >/dev/null 2>&1
    echo -e "\033[32m[OK] systemd timers enabled (runner / updater / report).\033[0m"
else
    echo "    No systemd; configuring fallback scheduler..."
    IS_RESTRICTED_ALPINE="false"
    if [ -f /etc/alpine-release ]; then
        if [ -d /proc/vz ] || grep -qa container=lxc /proc/1/environ 2>/dev/null || [ -f /.dockerenv ]; then
            IS_RESTRICTED_ALPINE="true"
        fi
    fi

    if [ "$IS_RESTRICTED_ALPINE" == "true" ]; then
        echo "    Restricted Alpine/LXC: installing self-managed loop scheduler."
        rc-update del crond default >/dev/null 2>&1 || true
        rc-service crond stop >/dev/null 2>&1 || true

        cat > "${INSTALL_DIR}/core/ipguard_scheduler.sh" << EOF
#!/bin/bash
while true; do
    MIN=\$(date -u +%M)
    HOUR=\$(date -u +%H)
    if [ "\$MIN" == "00" ] || [ "\$MIN" == "20" ] || [ "\$MIN" == "40" ]; then
        /bin/bash ${INSTALL_DIR}/core/runner.sh >/dev/null 2>&1
    fi
    if [ "\$HOUR" == "${DEPLOY_UTC_HOUR}" ] && [ "\$MIN" == "${DEPLOY_UTC_MIN}" ]; then
        /bin/bash ${INSTALL_DIR}/core/updater.sh >/dev/null 2>&1
    fi
    if [ "\$HOUR" == "16" ] && [ "\$MIN" == "00" ]; then
        /bin/bash ${INSTALL_DIR}/core/report.sh >/dev/null 2>&1
    fi
    sleep 60
done
EOF
        chmod +x "${INSTALL_DIR}/core/ipguard_scheduler.sh"

        if command -v rc-update >/dev/null 2>&1 && [ -d "/etc/local.d" ]; then
            echo "nohup bash ${INSTALL_DIR}/core/ipguard_scheduler.sh >/dev/null 2>&1 &" > /etc/local.d/ipguard_scheduler.start
            chmod +x /etc/local.d/ipguard_scheduler.start
            rc-update add local default >/dev/null 2>&1
        else
            grep -q "ipguard_scheduler" /etc/profile 2>/dev/null || echo "nohup bash ${INSTALL_DIR}/core/ipguard_scheduler.sh >/dev/null 2>&1 &" >> /etc/profile
        fi
        nohup bash "${INSTALL_DIR}/core/ipguard_scheduler.sh" >/dev/null 2>&1 &
        echo -e "\033[32m[OK] Loop scheduler started.\033[0m"
    else
        crontab -l 2>/dev/null | grep -v "ipguard" > "${SECURE_TMP}/cron_backup" || true
        echo "*/20 * * * * ${INSTALL_DIR}/core/runner.sh >/dev/null 2>&1" >> "${SECURE_TMP}/cron_backup"
        echo "${DEPLOY_UTC_MIN} ${DEPLOY_UTC_HOUR} * * * ${INSTALL_DIR}/core/updater.sh >/dev/null 2>&1" >> "${SECURE_TMP}/cron_backup"
        echo "0 16 * * * ${INSTALL_DIR}/core/report.sh >/dev/null 2>&1" >> "${SECURE_TMP}/cron_backup"
        crontab "${SECURE_TMP}/cron_backup" >/dev/null 2>&1
        rm -f "${SECURE_TMP}/cron_backup"

        if [ -d "/etc/crontabs" ] && [ -f "/var/spool/cron/crontabs/root" ]; then
            cp -f /var/spool/cron/crontabs/root /etc/crontabs/root 2>/dev/null || true
            chmod 600 /etc/crontabs/root 2>/dev/null || true
        fi
        if command -v rc-service >/dev/null 2>&1; then
            rc-service crond restart >/dev/null 2>&1 || crond -b >/dev/null 2>&1
        fi
        echo -e "\033[32m[OK] cron schedule installed (runner / updater / report).\033[0m"
    fi
fi

# ==========================================================
# Done
# ==========================================================
echo -e "\n========================================================"
echo "IPGuard standalone agent is deployed."
echo "  Region   : ${REGION_NAME:-$REGION_CODE}"
echo "  Schedule : runner every 20 min, updater + report daily (UTC)."
echo ""
echo "Manual commands:"
echo "  One maintenance cycle : bash ${INSTALL_DIR}/core/runner.sh"
echo "  IP quality check      : bash ${INSTALL_DIR}/core/mod_quality.sh"
echo "  Local summary report  : bash ${INSTALL_DIR}/core/report.sh"
echo "  Live log              : tail -f ${INSTALL_DIR}/logs/ipguard.log"
echo "  Uninstall             : bash ${INSTALL_DIR}/core/uninstall.sh"
echo "========================================================"
