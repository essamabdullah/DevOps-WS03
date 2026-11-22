FROM memcached:1.6-alpine

# Explicit non-root user, even though the base image already uses it:
# your image stays safe even if a future base tag changes its default
USER 11211:11211
EXPOSE 11211

# Default runtime flags: 128 MB cache, 1024 connections, 2 threads
CMD [ "memcached","-m","128","-c","1024","-t","2"]

# Shell form, because the check needs a pipe
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
 CMD echo stats | nc -w 2 127.0.0.1 11211 | grep -q uptime || exit 1