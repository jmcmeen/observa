FROM alpine:3.20

# hadolint ignore=DL3018
RUN apk add --no-cache postgresql16-client

COPY backup.sh /backup.sh
RUN chmod +x /backup.sh

ENTRYPOINT ["/backup.sh"]
