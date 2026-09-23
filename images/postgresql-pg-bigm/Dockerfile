ARG CNPG_POSTGRES_IMAGE=ghcr.io/cloudnative-pg/postgresql:17.11-standard-trixie

FROM ${CNPG_POSTGRES_IMAGE} AS pg-bigm-builder

ARG PG_MAJOR=17
ARG PG_BIGM_VERSION=1.2-20250903

USER root

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        libicu-dev \
        postgresql-server-dev-${PG_MAJOR}; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p /tmp/pg_bigm-src /tmp/pg_bigm-package; \
    curl -fsSL \
        "https://github.com/pgbigm/pg_bigm/archive/refs/tags/v${PG_BIGM_VERSION}.tar.gz" \
        -o /tmp/pg_bigm.tar.gz; \
    tar -xzf /tmp/pg_bigm.tar.gz \
        --strip-components=1 \
        -C /tmp/pg_bigm-src; \
    make -C /tmp/pg_bigm-src \
        USE_PGXS=1 \
        PG_CONFIG="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"; \
    make -C /tmp/pg_bigm-src \
        USE_PGXS=1 \
        PG_CONFIG="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config" \
        DESTDIR=/tmp/pg_bigm-package \
        install

FROM ${CNPG_POSTGRES_IMAGE}

USER root
COPY --from=pg-bigm-builder /tmp/pg_bigm-package/ /

# CloudNativePG 공식 PostgreSQL 이미지의 postgres 사용자 UID를 유지한다.
USER 26
