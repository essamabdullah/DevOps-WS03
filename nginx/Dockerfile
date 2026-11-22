FROM nginx:1.27-alpine

RUN addgroup -g 10001 -S app \
 && adduser -u 10001 -S -D -H -G app -s /sbin/nologin app \
 && rm -f /etc/nginx/conf.d/default.conf
 
COPY --chown=root:root --chmod=644 nginx.conf /etc/nginx/nginx.conf

USER 10001:10001
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/nginx-health || exit 1

CMD ["nginx", "-g", "daemon off;"]