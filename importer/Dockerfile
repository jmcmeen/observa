FROM python:3.12-alpine

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# hadolint ignore=DL3018
RUN apk add --no-cache \
    postgresql16-client \
    aws-cli \
    curl \
    gzip

COPY import.sh /import.sh
RUN chmod +x /import.sh

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /data

ENTRYPOINT ["/entrypoint.sh"]
