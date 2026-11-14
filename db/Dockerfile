# PostGIS with this project's schema and server settings baked in, so the
# published image needs no files mounted from the repository.
# PostGIS publishes this image for amd64 only, so this one is too.
FROM postgis/postgis:16-3.7@sha256:f37d93931b5af8bb67f7da00d2afef0dd951c8c49591389bde06cb6d720a7f9e

# Runs once, on the first start of an empty data directory.
COPY init/ /docker-entrypoint-initdb.d/
COPY postgresql.conf /etc/postgresql/postgresql.conf
