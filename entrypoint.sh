#!/bin/bash
# ==========================================================
# entrypoint.sh
# Container entrypoint for the standalone IPGuard agent.
#
# Responsibilities:
#   1. Generate /opt/ipguard/config.conf from environment variables
#      (Docker is non-interactive, so there is no install.sh prompt flow).
#   2. Run the maintenance loop as PID 1 (runner every 20m, updater daily,
#      report at 16:00 UTC), streaming module logs to the container stdout.
#
# Modes (first argument, default "daemon"):
#   daemon   - generate config + run the maintenance loop forever
#   once|run - run one maintenance cycle (runner.sh) and exit
#   quality  - run one IP quality check (mod_quality.sh) and exit
#   report   - print a local summary (report.sh) and exit
#   update   - refresh data (updater.sh) and exit
#   shell    - drop into an interactive bash
#   <other>  - exec the given command verbatim
#
# Environment variables (all optional, with defaults):
#   IPS_REGION         country code, e.g. US, JP, DE
#                      (unset = auto-detect from egress IP geo, fallback US)
#   IPS_REGION_FILE    explicit rule path under data/regions,
#                      e.g. US/CA/San_Jose.json             (overrides IPS_REGION pick)
#   IPS_IP_PREF        4 or 6                                (default 4)
#   IPS_PUBLIC_IP      pin the egress IP instead of detecting it
#   IPS_ENABLE_GOOGLE  true/false                            (default true)
#   IPS_ENABLE_TRUST   true/false                            (default true)
#   IPS_NODE_NAME      override the derived node id
#   IPS_NODE_ALIAS     friendly display name                 (default = node id)
#   IPS_RECONFIG       true to regenerate config even if one exists
#   IPS_LOG_STDOUT     auto (default: mirror logs to stdout only on a TTY),
#                      true (always mirror), false (never; keep docker logs quiet)
# ==========================================================

set -u

INSTALL_DIR="${INSTALL_DIR:-/opt/ipguard}"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
LOG_FILE="${INSTALL_DIR}/logs/ipguard.log"
HEARTBEAT="${INSTALL_DIR}/logs/.docker_heartbeat"

mkdir -p "${INSTALL_DIR}/logs"

log()  { echo "[entrypoint] $*"; }
die()  { echo "[entrypoint][FATAL] $*" >&2; exit 1; }

# ----------------------------------------------------------
# Keep only the selected region rule file under data/regions.
# The image bakes in EVERY country's rule files, but mod_trust.sh and
# updater.sh locate "the" region with `find regions -name '*.json' | head -1`.
# Pruning to a single file restores that invariant so they pick the
# configured region instead of an arbitrary one.
# ----------------------------------------------------------
prune_regions() {
    local keep="$1"
    local base="${INSTALL_DIR}/data/regions"
    [ -n "$keep" ] && [ -s "$keep" ] || return 0
    local rel="${keep#"${base}"/}"
    local tmp="${INSTALL_DIR}/data/.regions_keep"
    rm -rf "$tmp"
    mkdir -p "$tmp/$(dirname "$rel")"
    cp -f "$keep" "$tmp/$rel"
    rm -rf "$base"
    mv "$tmp" "$base"
    log "Region store pruned to: ${rel}"
}

# ----------------------------------------------------------
# Detect the egress IP country code via public geo APIs.
# Echoes an uppercase ISO code, or empty on total failure.
# ----------------------------------------------------------
detect_region() {
    local cc=""
    # Primary: Cloudflare trace (HTTPS, global CDN) -> "loc=US" line.
    cc=$(curl -s -m 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^loc=' | cut -d= -f2 | tr -d '[:space:]')
    # Fallbacks (also HTTPS, no key required).
    [ -z "$cc" ] && cc=$(curl -s -m 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -E '^loc=' | cut -d= -f2 | tr -d '[:space:]')
    [ -z "$cc" ] && cc=$(curl -s -m 5 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]')
    [ -z "$cc" ] && cc=$(curl -s -m 5 https://api.ip.sb/geoip 2>/dev/null | jq -r '.country_code // empty' 2>/dev/null)
    # Accept only a clean 2-letter code; reject error blobs / rate-limit text.
    cc=$(printf '%s' "$cc" | tr 'a-z' 'A-Z' | tr -cd 'A-Z')
    case "$cc" in [A-Z][A-Z]) printf '%s' "$cc" ;; *) printf '' ;; esac
}

# Map ISO codes to this repo's region directory names (it uses UK, not GB).
normalize_region() {
    local r
    r=$(printf '%s' "$1" | tr 'a-z' 'A-Z' | tr -cd 'A-Z')
    case "$r" in
        GB) r="UK" ;;
    esac
    printf '%s' "$r"
}

# Fetch the IP-quality probe (xykt/IPQuality ip.sh) ONCE, then reuse it.
# It is NOT re-downloaded on a schedule (updater.sh no longer fetches it).
ensure_probe() {
    local probe="${INSTALL_DIR}/core/ip_probe.sh"
    if [ -s "$probe" ] && grep -q "xykt" "$probe" 2>/dev/null; then
        return 0
    fi
    log "Fetching IP-quality probe once (ip.sh)..."
    curl -fsSL -m 20 "https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh" -o "$probe" 2>/dev/null || true
    if grep -q "xykt" "$probe" 2>/dev/null; then
        chmod +x "$probe"
        log "Probe ready: ${probe}"
    else
        rm -f "$probe" 2>/dev/null
        log "WARN: probe fetch failed; the 'quality' check will retry on first use."
    fi
}

# Map an ISO country code to its continent code, fully offline (no extra API
# call -- the egress country is already known reliably from the geo lookup).
# Returns EU/AS/NA/SA/OC/AF or empty for unknown.
country_continent() {
    case "$(printf '%s' "$1" | tr 'a-z' 'A-Z')" in
        AL|AD|AT|AX|BA|BE|BG|BY|CH|CY|CZ|DE|DK|EE|ES|FI|FO|FR|GB|GG|GI|GR|HR|HU|IE|IM|IS|IT|JE|LI|LT|LU|LV|MC|MD|ME|MK|MT|NL|NO|PL|PT|RO|RS|RU|SE|SI|SJ|SK|SM|UA|UK|VA|XK) echo EU ;;
        AE|AF|AM|AZ|BD|BH|BN|BT|CN|GE|HK|ID|IL|IN|IQ|IR|JO|JP|KG|KH|KP|KR|KW|KZ|LA|LB|LK|MM|MN|MO|MV|MY|NP|OM|PH|PK|PS|QA|SA|SG|SY|TH|TJ|TM|TR|TW|UZ|VN|YE) echo AS ;;
        AG|AI|AW|BB|BL|BM|BS|BZ|CA|CR|CU|CW|DM|DO|GD|GL|GP|GT|HN|HT|JM|KN|KY|LC|MF|MQ|MS|MX|NI|PA|PR|SV|SX|TC|TT|US|VC|VG|VI) echo NA ;;
        AR|BO|BR|CL|CO|EC|FK|GF|GY|PE|PY|SR|UY|VE) echo SA ;;
        AU|CK|FJ|FM|GU|KI|MH|MP|NC|NF|NR|NU|NZ|PF|PG|PN|PW|SB|TK|TO|TV|VU|WF|WS) echo OC ;;
        AO|BF|BI|BJ|BW|CD|CF|CG|CI|CM|CV|DJ|DZ|EG|EH|ER|ET|GA|GH|GM|GN|GQ|GW|KE|KM|LR|LS|LY|MA|MG|ML|MR|MU|MW|MZ|NA|NE|NG|RW|SC|SD|SL|SN|SO|SS|ST|SZ|TD|TG|TN|TZ|UG|ZA|ZM|ZW) echo AF ;;
        *) echo "" ;;
    esac
}

# A bundled supported country to use as the same-continent fallback hub.
# Empty result means no supported country exists on that continent.
continent_default() {
    case "$1" in
        EU) echo "DE" ;;
        AS) echo "SG" ;;
        NA) echo "US" ;;
        OC) echo "AU" ;;
        AF) echo "NG" ;;
        *)  echo "" ;;   # SA / AN / unknown have no bundled region
    esac
}

# ----------------------------------------------------------
# Build config.conf from environment variables.
# ----------------------------------------------------------
gen_config() {
    # Region priority:
    #   1. IPS_REGION_FILE  (exact rule path, e.g. US/CA/San_Jose.json)
    #   2. IPS_REGION       (country code, e.g. US, JP, DE)
    #   3. auto-detect the egress IP country via geo API
    #   4. fall back to US
    local region src
    if [ -n "${IPS_REGION_FILE:-}" ]; then
        src="${INSTALL_DIR}/data/regions/${IPS_REGION_FILE}"
        region="$(echo "$IPS_REGION_FILE" | cut -d/ -f1)"
        [ -s "$src" ] || die "IPS_REGION_FILE points to a missing rule file: ${IPS_REGION_FILE}"
    else
        if [ -n "${IPS_REGION:-}" ]; then
            region="$(normalize_region "$IPS_REGION")"
        else
            region="$(detect_region)"
            if [ -n "$region" ]; then
                region="$(normalize_region "$region")"
                log "IPS_REGION not set; auto-detected egress region: ${region}"
            else
                region="US"
                log "IPS_REGION not set and geo lookup failed; defaulting to US."
            fi
        fi
        src="$(find "${INSTALL_DIR}/data/regions/${region}" -name '*.json' 2>/dev/null | sort | head -n 1)"
        if [ -z "$src" ] || [ ! -s "$src" ]; then
            # Detected region has no bundled rules. Prefer a supported country
            # on the SAME continent before the final US fallback.
            local cont fb fbsrc
            cont="$(country_continent "$region")"
            fb="$(continent_default "$cont")"
            if [ -n "$fb" ]; then
                fbsrc="$(find "${INSTALL_DIR}/data/regions/${fb}" -name '*.json' 2>/dev/null | sort | head -n 1)"
                if [ -n "$fbsrc" ] && [ -s "$fbsrc" ]; then
                    log "No rules for '${region}'; using same-continent (${cont:-?}) region: ${fb}"
                    region="$fb"
                    src="$fbsrc"
                fi
            fi
            if [ -z "$src" ] || [ ! -s "$src" ]; then
                log "WARN: no same-continent region for '${region}' (continent ${cont:-?}); falling back to US."
                region="US"
                src="$(find "${INSTALL_DIR}/data/regions/US" -name '*.json' 2>/dev/null | sort | head -n 1)"
            fi
        fi
    fi

    if [ -z "$src" ] || [ ! -s "$src" ]; then
        die "Could not resolve any region rule file (is data/regions present in the image?)."
    fi
    log "Region rule: ${src#"${INSTALL_DIR}"/}"

    local region_name base_lat base_lon lang_params valid_suffix
    region_name=$(jq -r '.region_name' "$src")
    base_lat=$(jq -r '.google_module.base_lat' "$src")
    base_lon=$(jq -r '.google_module.base_lon' "$src")
    lang_params=$(jq -r '.google_module.lang_params' "$src")
    valid_suffix=$(jq -r '.google_module.valid_url_suffix' "$src")

    if [ ! -s "${INSTALL_DIR}/data/keywords/kw_${region}.txt" ]; then
        log "WARN: keyword file kw_${region}.txt not found; the Google module will have no search terms."
    fi

    # Egress IP: IPv4 is preferred by default. The detected address family
    # and IP_PREF are always kept consistent. Override the preference with
    # IPS_IP_PREF=6, or pin a specific address with IPS_PUBLIC_IP.
    local pub="${IPS_PUBLIC_IP:-}"
    local ip_pref="4"
    if [ -n "$pub" ]; then
        # Explicit override: infer family from the address.
        [[ "$pub" == *":"* ]] && ip_pref="6" || ip_pref="4"
    else
        local want="${IPS_IP_PREF:-4}"
        local v4 v6
        v4=$( (curl -4 -s -m 5 api.ip.sb/ip || curl -4 -s -m 5 ifconfig.me || curl -4 -s -m 5 ipv4.icanhazip.com) 2>/dev/null | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -n 1 | tr -d '[:space:]')
        v6=$( (curl -6 -s -m 5 api.ip.sb/ip || curl -6 -s -m 5 ifconfig.me || curl -6 -s -m 5 ipv6.icanhazip.com) 2>/dev/null | grep -E "^[0-9a-fA-F:]+.*:" | head -n 1 | tr -d '[:space:]')
        if [ "$want" = "6" ]; then
            # Prefer IPv6 only when explicitly requested.
            if   [ -n "$v6" ]; then pub="$v6"; ip_pref="6"
            elif [ -n "$v4" ]; then pub="$v4"; ip_pref="4"
            fi
        else
            # Default: prefer IPv4, fall back to IPv6.
            if   [ -n "$v4" ]; then pub="$v4"; ip_pref="4"
            elif [ -n "$v6" ]; then pub="$v6"; ip_pref="6"
            fi
        fi
    fi
    if [ -z "$pub" ]; then
        pub="127.0.0.1"; ip_pref="4"
    fi
    if [[ "$pub" == *":"* ]] && [[ "$pub" != *"["* ]]; then
        pub="[${pub}]"
    fi

    local node_name="${IPS_NODE_NAME:-}"
    if [ -z "$node_name" ]; then
        local h
        h=$(echo "$pub" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
        node_name="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${h}"
    fi
    local node_alias="${IPS_NODE_ALIAS:-$node_name}"

    cat > "$CONFIG_FILE" << EOF
# IPGuard container config (generated by docker entrypoint)
REGION_CODE="${region}"
REGION_NAME="${region_name}"
BASE_LAT="${base_lat}"
BASE_LON="${base_lon}"
LANG_PARAMS="${lang_params}"
VALID_URL_SUFFIX="${valid_suffix}"

# Module switches
ENABLE_GOOGLE="${IPS_ENABLE_GOOGLE:-true}"
ENABLE_TRUST="${IPS_ENABLE_TRUST:-true}"

INSTALL_DIR="${INSTALL_DIR}"
LOG_FILE="${LOG_FILE}"

IP_PREF="${ip_pref}"
PUBLIC_IP="${pub}"
# Inside a container we let the kernel route; no interface pinning.
BIND_IP=""

NODE_NAME="${node_name}"
NODE_ALIAS="${node_alias}"
EOF
    chmod 600 "$CONFIG_FILE"
    prune_regions "$src"
    log "Config ready: region=${region} (${region_name}) ip=${pub} node=${node_alias}"
}

ensure_config() {
    if [ -f "$CONFIG_FILE" ] && [ "${IPS_RECONFIG:-false}" != "true" ]; then
        log "Existing config found; keeping it (set IPS_RECONFIG=true to regenerate)."
        # Still prune the region store to match the kept config, so the trust
        # module and updater do not latch onto an arbitrary baked-in region.
        local region src
        region=$(grep '^REGION_CODE=' "$CONFIG_FILE" | cut -d'"' -f2)
        if [ -n "${IPS_REGION_FILE:-}" ] && [ -s "${INSTALL_DIR}/data/regions/${IPS_REGION_FILE}" ]; then
            src="${INSTALL_DIR}/data/regions/${IPS_REGION_FILE}"
        else
            src="$(find "${INSTALL_DIR}/data/regions/${region}" -name '*.json' 2>/dev/null | sort | head -n 1)"
        fi
        prune_regions "$src"
    else
        gen_config
    fi
}

TAIL_PID=""
shutdown() {
    log "Caught stop signal, shutting down."
    [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null
    exit 0
}

run_loop() {
    log "Maintenance loop starting (runner ~20m, updater daily, report 16:00 UTC)."
    touch "$LOG_FILE"

    # Pre-fetch the IP-quality probe once at startup so `docker exec ... quality`
    # is instant later and nothing has to download it on a schedule.
    ensure_probe

    # Whether to mirror module logs onto the container stdout (`docker logs`).
    #   IPS_LOG_STDOUT=auto  (default) -> only when attached to a TTY (run -it)
    #   IPS_LOG_STDOUT=true            -> always mirror
    #   IPS_LOG_STDOUT=false           -> never mirror
    # In detached mode (docker run -d, no TTY) the default is quiet, so the
    # docker json log does not grow unbounded. The full log is always kept in
    # ${LOG_FILE} (updater.sh caps it at the latest 2000 lines daily).
    local stream="${IPS_LOG_STDOUT:-auto}"
    case "$stream" in
        true)  stream="yes" ;;
        false) stream="no" ;;
        *)     if [ -t 1 ]; then stream="yes"; else stream="no"; fi ;;
    esac
    if [ "$stream" = "yes" ]; then
        tail -n 0 -F "$LOG_FILE" 2>/dev/null &
        TAIL_PID=$!
    else
        log "stdout log streaming off (non-TTY / quiet). Full log: ${LOG_FILE}"
    fi

    trap shutdown TERM INT

    local now last_runner=0 last_report=0

    # Do NOT refresh data at startup. The image already ships current data, and
    # updater.sh rotates the log (mv replace), which makes the `tail -F` above
    # reopen the file and re-print the whole log to the container stdout (the
    # "duplicate" output). The daily updater run handles refresh instead.
    local last_updater
    last_updater=$(date -u +%s)

    while true; do
        now=$(date -u +%s)
        echo "$now" > "$HEARTBEAT"

        if [ $(( now - last_runner )) -ge 1200 ]; then
            bash "${INSTALL_DIR}/core/runner.sh" >/dev/null 2>&1 &
            last_runner=$now
        fi
        if [ $(( now - last_updater )) -ge 86400 ]; then
            bash "${INSTALL_DIR}/core/updater.sh" >/dev/null 2>&1 &
            last_updater=$now
        fi
        if [ "$(date -u +%H)" = "16" ] && [ $(( now - last_report )) -ge 79200 ]; then
            bash "${INSTALL_DIR}/core/report.sh" >/dev/null 2>&1 &
            last_report=$now
        fi

        sleep 60
    done
}

MODE="${1:-daemon}"
case "$MODE" in
    daemon)
        ensure_config
        run_loop
        ;;
    once|run|runner)
        ensure_config
        bash "${INSTALL_DIR}/core/runner.sh"
        tail -n 60 "$LOG_FILE" 2>/dev/null || true
        ;;
    quality)
        ensure_config
        bash "${INSTALL_DIR}/core/mod_quality.sh"
        ;;
    report)
        ensure_config
        bash "${INSTALL_DIR}/core/report.sh"
        ;;
    update|updater)
        ensure_config
        bash "${INSTALL_DIR}/core/updater.sh"
        tail -n 40 "$LOG_FILE" 2>/dev/null || true
        ;;
    shell|bash)
        exec bash
        ;;
    *)
        exec "$@"
        ;;
esac
