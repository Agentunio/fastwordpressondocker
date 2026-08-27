ARG PHP_VERSION=8.3
FROM wordpress:php${PHP_VERSION}-apache

ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA256=ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c
ARG PHP_REDIS_VERSION=6.3.0
ARG PHP_REDIS_SHA256=0d5141f634bd1db6c1ddcda053d25ecf2c4fc1c395430d534fd3f8d51dd7f0b5
ARG PHP_MEMCACHE_VERSION=8.2
ARG PHP_MEMCACHE_SHA256=b3f0640eacdeb9046c6c86a1546d7fb8a4e9f219e5d9a36a287e59b2dd8208e5
ARG PHP_MEMCACHE_PHP85_PATCH=a743dc843bb487513386d31eb9481bd6a6825087
ARG PHP_MEMCACHE_PHP85_PATCH_SHA256=88cbbafbf6339ca67103795ea45cdf3b5728d4c593c7f69bf2efec5d9f9ad3e9
ARG WP_REDIS_CACHE_VERSION=2.8.0
ARG WP_REDIS_CACHE_SHA256=f077ac8b9c154cee936d3872b0734d42f7fd7f350e68fe8b2b20a69e854980cd
ARG WP_MEMCACHED_VERSION=4.0.0
ARG WP_MEMCACHED_SHA256=b19e7c8458d307ef4468026c796b380c44456d897ed2104ce891785680786851

RUN apt-get update \
    && apt-get install -y --no-install-recommends mariadb-client unzip util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" -o wp-cli.phar \
    && echo "${WP_CLI_SHA256}  wp-cli.phar" | sha256sum -c - \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

RUN apt-get update \
    && apt-get install -y --no-install-recommends $PHPIZE_DEPS patch zlib1g-dev \
    && curl -fsSL "https://pecl.php.net/get/redis-${PHP_REDIS_VERSION}.tgz" -o "redis-${PHP_REDIS_VERSION}.tgz" \
    && echo "${PHP_REDIS_SHA256}  redis-${PHP_REDIS_VERSION}.tgz" | sha256sum -c - \
    && tar -xzf "redis-${PHP_REDIS_VERSION}.tgz" \
    && cd "redis-${PHP_REDIS_VERSION}" \
    && phpize \
    && ./configure \
    && make \
    && make install \
    && cd .. \
    && curl -fsSL "https://pecl.php.net/get/memcache-${PHP_MEMCACHE_VERSION}.tgz" -o "memcache-${PHP_MEMCACHE_VERSION}.tgz" \
    && echo "${PHP_MEMCACHE_SHA256}  memcache-${PHP_MEMCACHE_VERSION}.tgz" | sha256sum -c - \
    && tar -xzf "memcache-${PHP_MEMCACHE_VERSION}.tgz" \
    && curl -fsSL \
        "https://github.com/websupport-sk/pecl-memcache/commit/${PHP_MEMCACHE_PHP85_PATCH}.patch" \
        -o memcache-php85.patch \
    && echo "${PHP_MEMCACHE_PHP85_PATCH_SHA256}  memcache-php85.patch" | sha256sum -c - \
    && cd "memcache-${PHP_MEMCACHE_VERSION}" \
    && patch -p1 < ../memcache-php85.patch \
    && phpize \
    && ./configure --enable-memcache-session=yes \
    && make \
    && make install \
    && cd .. \
    && docker-php-ext-enable redis memcache \
    && apt-get purge -y --auto-remove $PHPIZE_DEPS patch zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* /tmp/pear "redis-${PHP_REDIS_VERSION}" "redis-${PHP_REDIS_VERSION}.tgz" "memcache-${PHP_MEMCACHE_VERSION}" "memcache-${PHP_MEMCACHE_VERSION}.tgz" memcache-php85.patch \
    && mkdir -p /usr/local/share/wordpress-object-cache \
    && curl -fsSL \
        "https://downloads.wordpress.org/plugin/redis-cache.${WP_REDIS_CACHE_VERSION}.zip" \
        -o /usr/local/share/wordpress-object-cache/redis-cache.zip \
    && echo "${WP_REDIS_CACHE_SHA256}  /usr/local/share/wordpress-object-cache/redis-cache.zip" | sha256sum -c - \
    && curl -fsSL \
        "https://raw.githubusercontent.com/Automattic/wp-memcached/${WP_MEMCACHED_VERSION}/object-cache.php" \
        -o /usr/local/share/wordpress-object-cache/memcached.php \
    && echo "${WP_MEMCACHED_SHA256}  /usr/local/share/wordpress-object-cache/memcached.php" | sha256sum -c - \
    && chmod 644 /usr/local/share/wordpress-object-cache/redis-cache.zip /usr/local/share/wordpress-object-cache/memcached.php

COPY uploads.ini /usr/local/etc/php/conf.d/uploads.ini
