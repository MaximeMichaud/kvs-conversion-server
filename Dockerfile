FROM alpine:latest

LABEL Description="Docker image for KVS conversion server, based on Alpine. Supports passive mode and virtual users for vsftpd. Includes PHP with IonCube." \
      License="GNU General Public License v3" \
      Usage="docker run --rm -it --name kvs-conversion-server -p [HOST_CONNECTION_PORTS]:20-22 -p [HOST_FTP_PORTS]:21100-21110 my-kvs-conversion-server-image" \
      Version="0.1"

# Installation of dependencies
RUN apk update \
    && apk upgrade \
    && apk --update --no-cache add \
        bash \
        openssl \
        vsftpd \
        ffmpeg \
        imagemagick \
        php \
        php-curl \
        php-gd \
        php-ftp \
        fcron

# Download and install IonCube Loader
RUN wget https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz \
    && tar xvfz ioncube_loaders_lin_x86-64.tar.gz \
    && PHP_EXT_DIR=$(php -i | grep extension_dir | awk '{print $3}') \
    && cp "ioncube/ioncube_loader_lin_$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;').so" $PHP_EXT_DIR \
    && rm -rf ioncube ioncube_loaders_lin_x86-64.tar.gz

# Add IonCube configuration to the php.ini file
RUN echo "zend_extension=ioncube_loader_lin_$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;').so" >> /etc/php81/php.ini

# Creation of necessary directories
RUN mkdir -p /home/vsftpd/ \
    && mkdir -p /var/log/vsftpd \
    && chown -R ftp:ftp /home/vsftpd/

# Copy configuration files
COPY vsftpd-base.conf /etc/vsftpd/vsftpd-base.conf
COPY vsftpd-ftp.conf /etc/vsftpd/vsftpd-ftp.conf
COPY run-vsftpd.sh /usr/sbin/
RUN chmod +x /usr/sbin/run-vsftpd.sh

# Folder creation and cron job configuration script
COPY create_folders.sh /usr/local/bin/create_folders.sh
RUN chmod +x /usr/local/bin/create_folders.sh

# Expose ports
EXPOSE 20-22 990 21100-21110

# Start command
CMD ["sh", "-c", "/usr/local/bin/create_folders.sh && crond && /usr/sbin/run-vsftpd.sh"]
