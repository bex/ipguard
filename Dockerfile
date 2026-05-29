# ==========================================================
# IPGuard (standalone) container image
#
# Debian slim base is used on purpose: the maintenance modules are
# bash scripts that rely on GNU coreutils / grep -E / sed -E / awk and
# on `flock` (util-linux). Debian gives the most compatible behavior
# and a reliable flock; runtime memory footprint stays tiny.
#
# Build:
#   docker build -t ipguard:standalone .
#
# Run (long-running maintenance daemon; egresses via the host public IP
# on a normal single-IP VPS using default bridge networking):
#   docker run -d --name ipguard --restart unless-stopped \
#     -e IPS_REGION=US \
#     -v ips-logs:/opt/ipguard/logs \
#     ipguard:standalone
#
# One-shot helpers:
#   docker run --rm ipguard:standalone quality   # IP quality check
#   docker run --rm ipguard:standalone once      # single maintenance cycle
#   docker run --rm ipguard:standalone report    # local summary
# ==========================================================
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        jq \
        gawk \
        util-linux \
        procps \
        iproute2 \
        dnsutils \
        openssl \
        netcat-openbsd \
        bc \
        iputils-ping \
    && rm -rf /var/lib/apt/lists/*

ENV INSTALL_DIR=/opt/ipguard

# Bake the agent payload (core scripts + region/keyword/UA data) into the image.
COPY . ${INSTALL_DIR}

RUN chmod +x ${INSTALL_DIR}/core/*.sh ${INSTALL_DIR}/entrypoint.sh \
    && mkdir -p ${INSTALL_DIR}/logs

WORKDIR ${INSTALL_DIR}

# Sensible defaults; override any of these with `-e` at run time.
# IPS_REGION is intentionally NOT set here: when unset, the entrypoint
# auto-detects the region from the egress IP geolocation (fallback US).
ENV IPS_IP_PREF=4 \
    IPS_ENABLE_GOOGLE=true \
    IPS_ENABLE_TRUST=true

# The daemon writes a heartbeat each loop iteration; report unhealthy if stale.
HEALTHCHECK --interval=2m --timeout=10s --start-period=45s --retries=3 \
    CMD test -f ${INSTALL_DIR}/logs/.docker_heartbeat \
        && test $(( $(date -u +%s) - $(cat ${INSTALL_DIR}/logs/.docker_heartbeat) )) -lt 180

ENTRYPOINT ["/opt/ipguard/entrypoint.sh"]
CMD ["daemon"]
