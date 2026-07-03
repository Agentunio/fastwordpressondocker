ARG PHP_VERSION=8.3
FROM wordpress:php${PHP_VERSION}-apache

ARG WP_CLI_VERSION=2.12.0
ARG WP_CLI_SHA256=ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c

RUN apt-get update \
    && apt-get install -y --no-install-recommends mariadb-client \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" -o wp-cli.phar \
    && echo "${WP_CLI_SHA256}  wp-cli.phar" | sha256sum -c - \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp

COPY uploads.ini /usr/local/etc/php/conf.d/uploads.ini
