#!/bin/bash
set -e

: "${API_USER_PASSWORD:?Set API_USER_PASSWORD in .env}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    DO \$\$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_user') THEN
            CREATE ROLE api_user LOGIN PASSWORD '${API_USER_PASSWORD}';
        END IF;
    END
    \$\$;
    GRANT api_readonly TO api_user;
EOSQL
