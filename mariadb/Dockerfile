# Start from the official image: you add your files and defaults on top
FROM mariadb:10.11

# Bake the schema into the image. Root owns it, the mysql user can only read it.
COPY --chown=root:root --chmod=644 init.sql /docker-entrypoint-initdb.d/01-init.sql

# Default to the built-in mysql user (UID 999) instead of root
USER 999:999

# Documentation only: the port the server listens on inside the network
EXPOSE 3306

# Image-level health check; a compose healthcheck: overrides it
HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=60s \
  CMD healthcheck.sh --connect --innodb_initialized || exit 1
