# Using Debian 13 (Trixie) stable as the base
FROM debian:stable-slim

LABEL org.opencontainers.image.title="KVS Conversion Server" \
      org.opencontainers.image.description="Docker image for KVS conversion server, based on Debian 13 (Trixie). Supports passive mode and virtual users for vsftpd. Includes PHP with IonCube." \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/MaximeMichaud/kvs-conversion-server" \
      org.opencontainers.image.documentation="https://github.com/MaximeMichaud/kvs-conversion-server/blob/main/README.md" \
      org.opencontainers.image.version="1.2"

# Install necessary tools and add PHP repository
RUN apt-get update && \
    apt-get install -y --no-install-recommends wget lsb-release apt-transport-https ca-certificates gnupg unattended-upgrades && \
    wget -qO - https://packages.sury.org/php/apt.gpg | gpg --dearmor > /usr/share/keyrings/php.sury.org.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/php.sury.org.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list && \
    rm -rf /var/lib/apt/lists/*

# Configure unattended-upgrades for automatic updates including custom repositories
RUN printf "Unattended-Upgrade::Origins-Pattern {\n\
    \"origin=Debian,codename=${distro_codename},label=Debian\";\n\
    \"origin=Debian,codename=${distro_codename},label=Debian-Security\";\n\
    \"site=packages.sury.org\";\n\
};\n" > /etc/apt/apt.conf.d/50unattended-upgrades && \
    printf "APT::Periodic::Update-Package-Lists \"1\";\nAPT::Periodic::Unattended-Upgrade \"1\";\n" > /etc/apt/apt.conf.d/20auto-upgrades

# Update and install PHP dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        openssl \
        vsftpd \
        ffmpeg \
        imagemagick \
        php7.4-cli \
        php7.4-curl \
        php7.4-gd \
        php7.4-ftp \
        php7.4-mbstring \
        php7.4-opcache \
        # php7.4-imagick \
        php8.1-cli \
        php8.1-curl \
        php8.1-gd \
        php8.1-ftp \
        php8.1-mbstring \
        php8.1-opcache \
        # php8.1-imagick \
        cron && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install and configure IonCube
RUN wget https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz \
    && tar xzf ioncube_loaders_lin_x86-64.tar.gz \
    && PHP_EXT_DIR_74=$(php7.4 -i | grep extension_dir | awk '{print $3}') \
    && cp "ioncube/ioncube_loader_lin_7.4.so" $PHP_EXT_DIR_74 \
    && echo "zend_extension=$PHP_EXT_DIR_74/ioncube_loader_lin_7.4.so" >> /etc/php/7.4/cli/php.ini \
    && PHP_EXT_DIR_81=$(php8.1 -i | grep extension_dir | awk '{print $3}') \
    && cp "ioncube/ioncube_loader_lin_8.1.so" $PHP_EXT_DIR_81 \
    && echo "zend_extension=$PHP_EXT_DIR_81/ioncube_loader_lin_8.1.so" >> /etc/php/8.1/cli/php.ini \
    && rm -rf ioncube ioncube_loaders_lin_x86-64.tar.gz

# Creation of necessary directories
RUN mkdir -p /home/vsftpd/ /var/log/vsftpd /var/run/vsftpd/empty \
    && chown -R ftp:ftp /home/vsftpd/

# Copy configuration files
COPY config/vsftpd-base.conf /etc/vsftpd-base.conf
COPY config/vsftpd-ftp.conf /etc/vsftpd-ftp.conf
COPY config/vsftpd-ftps.conf /etc/vsftpd-ftps.conf
COPY config/vsftpd-ftps_implicit.conf /etc/vsftpd-ftps_implicit.conf
COPY config/vsftpd-ftps_tls.conf /etc/vsftpd-ftps_tls.conf
COPY --chmod=755 scripts/run-vsftpd.sh /usr/sbin/run-vsftpd.sh

# Folder creation and cron job configuration script
COPY --chmod=755 scripts/create_folders.sh /usr/local/bin/create_folders.sh

# Copy entrypoint script
COPY --chmod=755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

# Expose ports
EXPOSE 20-22 990 21100-21110

# Health check to verify vsftpd is running
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD pgrep vsftpd || exit 1

# Start command
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
