# Using Debian as the base
FROM debian:stable-slim

LABEL Description="Docker image for KVS conversion server, based on Debian. Supports passive mode and virtual users for vsftpd. Includes PHP with IonCube." \
      License="GNU General Public License v3" \
      Usage="docker run --rm -it --name kvs-conversion-server -p [HOST_CONNECTION_PORTS]:20-22 -p [HOST_FTP_PORTS]:21100-21110 my-kvs-conversion-server-image" \
      Version="0.1"

# Install necessary tools and add PHP repository
RUN apt-get update && \
    apt-get install -y --no-install-recommends wget lsb-release apt-transport-https ca-certificates gnupg && \
    wget -qO - https://packages.sury.org/php/apt.gpg | apt-key add - && \
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list

# Update and install PHP dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        openssl \
        vsftpd \
        ffmpeg \
        imagemagick \
        php7.4 \
        php7.4-curl \
        php7.4-gd \
        php7.4-ftp \
        php8.1 \
        php8.1-curl \
        php8.1-gd \
        php8.1-ftp \
        cron && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN wget https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz \
    && tar xvfz ioncube_loaders_lin_x86-64.tar.gz \
    && PHP_EXT_DIR_74=$(php7.4 -i | grep extension_dir | awk '{print $3}') \
    && cp "ioncube/ioncube_loader_lin_7.4.so" $PHP_EXT_DIR_74 \
    && echo "zend_extension=$PHP_EXT_DIR_74/ioncube_loader_lin_7.4.so" >> /etc/php/7.4/cli/php.ini \
    && PHP_EXT_DIR_81=$(php8.1 -i | grep extension_dir | awk '{print $3}') \
    && cp "ioncube/ioncube_loader_lin_8.1.so" $PHP_EXT_DIR_81 \
    && echo "zend_extension=$PHP_EXT_DIR_81/ioncube_loader_lin_8.1.so" >> /etc/php/8.1/cli/php.ini \
    && rm -rf ioncube ioncube_loaders_lin_x86-64.tar.gz

# Creation of necessary directories
RUN mkdir -p /home/vsftpd/ \
    && mkdir -p /var/log/vsftpd \
    && chown -R ftp:ftp /home/vsftpd/

# secure_chroot_dir
RUN mkdir -p /var/run/vsftpd/empty

# Copy configuration files
COPY vsftpd-base.conf /etc/vsftpd-base.conf
COPY vsftpd-ftp.conf /etc/vsftpd-ftp.conf
COPY run-vsftpd.sh /usr/sbin/
RUN chmod +x /usr/sbin/run-vsftpd.sh

# Folder creation and cron job configuration script
COPY create_folders.sh /usr/local/bin/create_folders.sh
RUN chmod +x /usr/local/bin/create_folders.sh

# Expose ports
EXPOSE 20-22 990 21100-21110

# Start command
CMD ["sh", "-c", "/usr/local/bin/create_folders.sh && cron && /usr/sbin/run-vsftpd.sh"]
