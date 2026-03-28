FROM python:3.12-alpine

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# hadolint ignore=DL3018
RUN apk add --no-cache \
    postgresql16-client \
    curl \
    gzip

# hadolint ignore=DL3013
RUN pip install --no-cache-dir boto3 tqdm

COPY download.py /download.py
COPY import.sh /import.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /import.sh /entrypoint.sh

WORKDIR /data

ENTRYPOINT ["/entrypoint.sh"]
