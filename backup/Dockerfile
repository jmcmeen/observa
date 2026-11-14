FROM alpine:3.20

# hadolint ignore=DL3018
RUN apk add --no-cache postgresql16-client

COPY backup.sh /backup.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /backup.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
