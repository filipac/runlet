# PHP 8.4 CLI with the Excimer and SPX profiler extensions, for Runlet's Profile Run tests
# and screenshots (issue #41). Disposable: part of the runlet-fixtures Compose project.
FROM php:8.4-cli
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends zlib1g-dev; \
    pecl install excimer; \
    docker-php-ext-enable excimer; \
    curl -fsSL https://github.com/NoiseByNorthwest/php-spx/archive/refs/tags/v0.4.22.tar.gz -o /tmp/spx.tar.gz; \
    mkdir /tmp/spx; tar -xzf /tmp/spx.tar.gz -C /tmp/spx --strip-components=1; \
    cd /tmp/spx; phpize; ./configure; make -j"$(nproc)"; make install; \
    docker-php-ext-enable spx; \
    cd /; rm -rf /tmp/spx /tmp/spx.tar.gz /tmp/pear; \
    apt-get purge -y --auto-remove zlib1g-dev; rm -rf /var/lib/apt/lists/*
