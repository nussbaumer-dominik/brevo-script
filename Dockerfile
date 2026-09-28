FROM alpine:3.22

RUN apk add --no-cache \
    bash \
    curl \
    ca-certificates

WORKDIR /app

COPY brevo-keepalive.sh /app/brevo-keepalive.sh

RUN chmod +x /app/brevo-keepalive.sh

# Keep the container running so Coolify can execute scheduled tasks inside it
CMD ["tail", "-f", "/dev/null"]