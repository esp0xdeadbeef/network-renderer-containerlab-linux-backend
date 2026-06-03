ARG CLAB_FRR_BASE_IMAGE=frrouting/frr@sha256:990e83490108b686fd6df3b1cafa6bdbb2714acb00eedb9a89693946f46f45ce
FROM ${CLAB_FRR_BASE_IMAGE}

USER root

RUN if command -v tcpdump >/dev/null 2>&1 \
        && command -v ping >/dev/null 2>&1 \
        && command -v traceroute >/dev/null 2>&1 \
        && command -v curl >/dev/null 2>&1 \
        && command -v vim >/dev/null 2>&1 \
        && command -v rg >/dev/null 2>&1 \
        && command -v nmap >/dev/null 2>&1 \
        && command -v nft >/dev/null 2>&1 \
        && command -v less >/dev/null 2>&1 \
        && command -v pppd >/dev/null 2>&1 \
        && command -v pppoe >/dev/null 2>&1 \
        && command -v pppoe-server >/dev/null 2>&1; then \
        echo "FRR tooling packages already present"; \
    else \
        apk add --no-cache \
            tcpdump \
            iputils \
            traceroute \
            busybox-extras \
            procps \
            curl \
            vim \
            ripgrep \
            nmap \
            nftables \
            less \
            ppp \
            rp-pppoe; \
    fi

RUN if ! command -v pppoe-sniff >/dev/null 2>&1; then \
        { \
          echo '#!/bin/sh'; \
          echo 'set -eu'; \
          echo 'iface=""'; \
          echo 'while [ "$#" -gt 0 ]; do'; \
          echo '    case "$1" in'; \
          echo '        -I)'; \
          echo '            shift'; \
          echo '            iface="${1:-}"'; \
          echo '            ;;'; \
          echo '        -h|--help)'; \
          echo '            echo "usage: pppoe-sniff -I INTERFACE [tcpdump-options...]"'; \
          echo '            exit 0'; \
          echo '            ;;'; \
          echo '        *)'; \
          echo '            break'; \
          echo '            ;;'; \
          echo '    esac'; \
          echo '    shift'; \
          echo 'done'; \
          echo 'if [ -z "$iface" ]; then'; \
          echo '    echo "pppoe-sniff compatibility wrapper requires -I INTERFACE" >&2'; \
          echo '    exit 2'; \
          echo 'fi'; \
          echo "exec tcpdump -ni \"\$iface\" 'ether proto 0x8863 or ether proto 0x8864' \"\$@\""; \
        } >/usr/local/bin/pppoe-sniff; \
        chmod +x /usr/local/bin/pppoe-sniff; \
    fi

RUN command -v pppoe-sniff >/dev/null 2>&1

RUN sed -i \
        -e 's/^bgpd=no/bgpd=yes/' \
        /etc/frr/daemons \
    && grep -q '^bgpd=yes' /etc/frr/daemons \
    && { grep -q '^staticd=yes' /etc/frr/daemons \
        || grep -q 'staticd daemons are always started' /etc/frr/daemons; }

#USER frr
