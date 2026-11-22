FROM rabbitmq:4.1-management

# Non-secret broker configuration, baked in; the broker user can read but not change it
COPY --chown=root:root --chmod=644 rabbitmq.conf /etc/rabbitmq/rabbitmq.conf

# Run as the built-in rabbitmq user (UID 999); the entrypoint then skips its root-only steps
USER 999:999

# 5672 = AMQP for the app, 15672 = management UI (internal only, never published)
EXPOSE 5672 15672

HEALTHCHECK --interval=30s --timeout=10s --retries=5 --start-period=60s \
  CMD rabbitmq-diagnostics -q ping || exit 1