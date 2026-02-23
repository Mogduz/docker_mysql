FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    db_name= \
    db_user= \
    db_user_password=

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        mysql-server-8.0 \
        ca-certificates \
    && rm -rf /var/lib/mysql/* \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/mysql-entrypoint.sh /usr/local/bin/mysql-entrypoint.sh
COPY scripts/mysql-import-dump.sh /usr/local/bin/mysql-import-dump.sh

RUN chmod +x /usr/local/bin/mysql-entrypoint.sh /usr/local/bin/mysql-import-dump.sh \
    && mkdir -p /var/run/mysqld /var/lib/mysql \
    && chown -R mysql:mysql /var/run/mysqld /var/lib/mysql

VOLUME ["/var/lib/mysql"]

EXPOSE 3306

ENTRYPOINT ["/usr/local/bin/mysql-entrypoint.sh"]
