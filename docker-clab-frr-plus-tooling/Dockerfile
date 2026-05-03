ARG CLAB_FRR_BASE_IMAGE=frrouting/frr:latest
FROM ${CLAB_FRR_BASE_IMAGE}

USER root

RUN if command -v tcpdump >/dev/null 2>&1 \
        && command -v ping >/dev/null 2>&1 \
        && command -v traceroute >/dev/null 2>&1 \
        && command -v curl >/dev/null 2>&1 \
        && command -v vim >/dev/null 2>&1 \
        && command -v nft >/dev/null 2>&1 \
        && command -v less >/dev/null 2>&1; then \
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
            nftables \
            less; \
    fi

RUN sed -i \
        -e 's/^bgpd=no/bgpd=yes/' \
        -e 's/^staticd=no/staticd=yes/' \
        /etc/frr/daemons

#USER frr
