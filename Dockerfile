# Using Debian 13 (Trixie) as the base
FROM debian:trixie-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG VERSION=dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="KVS Conversion Server" \
      org.opencontainers.image.description="Docker image for KVS conversion server, based on Debian 13 (Trixie) slim. Supports passive mode and virtual users for vsftpd. Includes PHP with IonCube." \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/MaximeMichaud/kvs-conversion-server" \
      org.opencontainers.image.documentation="https://github.com/MaximeMichaud/kvs-conversion-server/blob/main/README.md" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# Add dpkg excludes for unnecessary files to reduce image size
RUN printf "path-exclude=/usr/share/X11/*\n\
path-exclude=/usr/share/icons/*\n\
path-exclude=/usr/share/gnupg/help/*\n\
path-exclude=/usr/share/help/*\n" >> /etc/dpkg/dpkg.cfg.d/docker

# Install necessary tools and add PHP repository
RUN apt-get update && \
    apt-get install -y --no-install-recommends wget lsb-release apt-transport-https ca-certificates gnupg unattended-upgrades && \
    wget -qO - https://packages.sury.org/php/apt.gpg | gpg --dearmor > /usr/share/keyrings/php.sury.org.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/php.sury.org.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Configure unattended-upgrades for automatic updates including custom repositories
RUN distro_codename=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"') && \
    printf '%s\n' \
        'Unattended-Upgrade::Origins-Pattern {' \
        "    \"origin=Debian,codename=${distro_codename},label=Debian\";" \
        "    \"origin=Debian,codename=${distro_codename},label=Debian-Security\";" \
        '    "site=packages.sury.org";' \
        '};' > /etc/apt/apt.conf.d/50unattended-upgrades && \
    printf '%s\n' \
        'APT::Periodic::Update-Package-Lists "1";' \
        'APT::Periodic::Unattended-Upgrade "1";' > /etc/apt/apt.conf.d/20auto-upgrades

# Copy project defaults before package installation so Docker packages and runtime validation use one version list.
COPY kvs-conversion-server.sh /usr/local/lib/kvs/kvs-conversion-server.sh
COPY scripts/php-support.sh /usr/local/lib/kvs/php-support.sh

# Update and install PHP dependencies
RUN apt-get update && \
    supported_php_versions=$(awk -F= '$1 == "SUPPORTED_PHP_VERSIONS" { gsub(/"/, "", $2); print $2; exit }' /usr/local/lib/kvs/kvs-conversion-server.sh) && \
    test -n "$supported_php_versions" && \
    set -- \
        acl \
        bash \
        iproute2 \
        openssl \
        vsftpd \
        ffmpeg \
        imagemagick \
        cron; \
    for supported_php_version in $supported_php_versions; do \
        php_version=${supported_php_version#php}; \
        set -- "$@" \
            "php${php_version}-cli" \
            "php${php_version}-curl" \
            "php${php_version}-gd" \
            "php${php_version}-ftp" \
            "php${php_version}-mbstring" \
            "php${php_version}-opcache"; \
    done; \
    apt-get install -y --no-install-recommends \
        "$@" && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/cache/debconf/* && \
    find /usr/share/doc -mindepth 1 -type f ! -name copyright -delete && \
    find /usr/share/doc -mindepth 1 -type d -empty -delete && \
    rm -rf /usr/share/mime/* \
           /usr/share/fonts/truetype/liberation* && \
    (find /usr -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true) && \
    (find /usr -type f -name '*.pyc' -delete 2>/dev/null || true) && \
    (find /usr -type f -name '*.pyo' -delete 2>/dev/null || true)

# Install and configure IonCube
RUN supported_php_versions=$(awk -F= '$1 == "SUPPORTED_PHP_VERSIONS" { gsub(/"/, "", $2); print $2; exit }' /usr/local/lib/kvs/kvs-conversion-server.sh) \
    && test -n "$supported_php_versions" \
    && wget https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz \
    && tar xzf ioncube_loaders_lin_x86-64.tar.gz \
    && for supported_php_version in $supported_php_versions; do \
        php_version=${supported_php_version#php}; \
        php_ext_dir=$(php"$php_version" -i | awk '/^extension_dir =>/ { print $3; exit }'); \
        cp "ioncube/ioncube_loader_lin_${php_version}.so" "$php_ext_dir"; \
        echo "zend_extension=$php_ext_dir/ioncube_loader_lin_${php_version}.so" >> "/etc/php/${php_version}/cli/php.ini"; \
    done \
    && rm -rf ioncube ioncube_loaders_lin_x86-64.tar.gz

# Creation of necessary directories
RUN mkdir -p /home/vsftpd/ /var/log/vsftpd /var/run/vsftpd/empty \
             /usr/local/lib/kvs \
    && chown -R ftp:ftp /home/vsftpd/

# Copy configuration files
COPY config/vsftpd-base.conf /etc/vsftpd-base.conf
COPY config/vsftpd-ftp.conf /etc/vsftpd-ftp.conf
COPY config/vsftpd-ftps.conf /etc/vsftpd-ftps.conf
COPY config/vsftpd-ftps_implicit.conf /etc/vsftpd-ftps_implicit.conf
COPY config/vsftpd-ftps_tls.conf /etc/vsftpd-ftps_tls.conf
COPY --chmod=755 scripts/run-vsftpd.sh /usr/sbin/run-vsftpd.sh

# Folder creation and cron job configuration script
COPY scripts/user-support.sh /usr/local/lib/kvs/user-support.sh
COPY --chmod=755 scripts/run-cron-task.sh /usr/local/bin/run-cron-task.sh
COPY --chmod=755 scripts/create_folders.sh /usr/local/bin/create_folders.sh

# Copy runtime scripts
COPY --chmod=755 scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY --chmod=755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

# Expose ports
EXPOSE 20 21 990 21100-21110

# Health check to verify required services are running
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# Start command
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
