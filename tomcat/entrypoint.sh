#!/bin/sh
set -eu
umask 077
CONF=/run/appconfig/application.properties

DB_PASSWORD=$(cat "$DB_PASSWORD_FILE")
RABBITMQ_PASSWORD=$(cat "$RABBITMQ_PASSWORD_FILE")

sed \
  -e "s|^jdbc.url=.*|jdbc.url=jdbc:mysql://${DB_HOST}:3306/${DB_NAME}?useUnicode=true\&characterEncoding=UTF-8\&zeroDateTimeBehavior=CONVERT_TO_NULL\&useSSL=false\&allowPublicKeyRetrieval=true|" \
  -e "s|^jdbc.username=.*|jdbc.username=${DB_USER}|" \
  -e "s|^jdbc.password=.*|jdbc.password=${DB_PASSWORD}|" \
  -e "s|^memcached.active.host=.*|memcached.active.host=${MEMCACHED_HOST}|" \
  -e "s|^rabbitmq.address=.*|rabbitmq.address=${RABBITMQ_HOST}|" \
  -e "s|^rabbitmq.username=.*|rabbitmq.username=${RABBITMQ_USER}|" \
  -e "s|^rabbitmq.password=.*|rabbitmq.password=${RABBITMQ_PASSWORD}|" \
  /opt/app/application.properties.template > "$CONF"

echo "entrypoint: application.properties generated (values not printed)"
exec catalina.sh run