FROM python:3.12-alpine@sha256:c5ba3deef00c7758561a0f03c26f44f10589263d40e732b8748e0d1f38f6dd89

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# hadolint ignore=DL3018,DL3013
RUN apk add --no-cache \
    postgresql16-client \
    curl \
    gzip \
 && pip install --no-cache-dir boto3 tqdm

# Built from the repository root, so the SQL and export scripts are baked in too.
COPY importer/download.py /download.py
COPY importer/import.sh /import.sh
COPY importer/entrypoint.sh /entrypoint.sh
COPY db/scripts /scripts
RUN chmod +x /import.sh /entrypoint.sh

WORKDIR /data

ENTRYPOINT ["/entrypoint.sh"]
