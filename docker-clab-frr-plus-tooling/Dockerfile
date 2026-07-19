ARG CLAB_FRR_BASE_IMAGE=debian:bookworm-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb
FROM ${CLAB_FRR_BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dhcpcd5 \
        dnsmasq \
        dns-root-data \
        frr \
        iproute2 \
        iputils-ping \
        jq \
        kea-dhcp4-server \
        kea-dhcp6-server \
        knot \
        less \
        nmap \
        nftables \
        ppp \
        pppoe \
        procps \
        python3 \
        ripgrep \
        tcpdump \
        traceroute \
        udhcpc \
        udhcpd \
        unbound \
        vim \
    && rm -rf /var/lib/apt/lists/*

COPY protected-reservation-materializer.py /usr/local/bin/clab-protected-reservation-materializer
RUN chmod 0755 /usr/local/bin/clab-protected-reservation-materializer

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

RUN sed -i \
        -e 's/^bgpd=no/bgpd=yes/' \
        /etc/frr/daemons \
    && grep -q '^bgpd=yes' /etc/frr/daemons \
    && for cmd in tcpdump ping traceroute curl vim rg nmap nft less pppd pppoe pppoe-server pppoe-sniff dhcpcd udhcpc udhcpd dnsmasq knotd knotc unbound unbound-checkconf vtysh python3 jq kea-dhcp4 kea-dhcp6 clab-protected-reservation-materializer; do \
        command -v "$cmd" >/dev/null || { echo "missing command: $cmd" >&2; exit 1; }; \
    done \
    && test -x /usr/lib/frr/zebra \
    && test -x /usr/lib/frr/bgpd \
    && test -x /usr/lib/frr/staticd
