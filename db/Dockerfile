# PostGIS with this project's schema and server settings baked in, so the
# published image needs no files mounted from the repository.
# PostGIS publishes this image for amd64 only, so this one is too.
FROM postgis/postgis:16-3.4@sha256:44126d872ac91993766c341e369c539e8196614321765d36a6f1bab0419a5fa5

# Runs once, on the first start of an empty data directory.
COPY init/ /docker-entrypoint-initdb.d/
COPY postgresql.conf /etc/postgresql/postgresql.conf
