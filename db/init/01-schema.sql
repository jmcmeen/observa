CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Import log for tracking ETL runs
CREATE TABLE import_log (
    id serial PRIMARY KEY,
    started_at timestamptz NOT NULL,
    finished_at timestamptz,
    status varchar(20) NOT NULL DEFAULT 'running',
    observations_count bigint,
    photos_count bigint,
    taxa_count bigint,
    observers_count bigint,
    error_message text,
    duration_seconds integer
);

CREATE TABLE observations (
    observation_uuid uuid NOT NULL PRIMARY KEY,
    observer_id integer,
    latitude numeric(15,10),
    longitude numeric(15,10),
    positional_accuracy integer,
    taxon_id integer,
    quality_grade varchar(255),
    observed_on date,
    anomaly_score double precision,
    geom geometry(Point, 4326) GENERATED ALWAYS AS (
        CASE WHEN latitude IS NOT NULL AND longitude IS NOT NULL
             THEN ST_SetSRID(ST_MakePoint(longitude::double precision, latitude::double precision), 4326)
        END
    ) STORED
);

CREATE TABLE photos (
    photo_uuid uuid NOT NULL,
    photo_id integer NOT NULL PRIMARY KEY,
    observation_uuid uuid NOT NULL,
    observer_id integer,
    extension varchar(5),
    license varchar(255),
    width smallint,
    height smallint,
    position smallint
);

CREATE TABLE taxa (
    taxon_id integer NOT NULL PRIMARY KEY,
    ancestry varchar(255),
    rank_level double precision,
    rank varchar(255),
    name varchar(255),
    active boolean
);

CREATE TABLE observers (
    observer_id integer NOT NULL PRIMARY KEY,
    login varchar(255),
    name varchar(255)
);

CREATE INDEX idx_import_log_status_id ON import_log (status, id DESC);

-- Read-only role for API access
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'api_readonly') THEN
        CREATE ROLE api_readonly NOLOGIN;
    END IF;
END
$$;
GRANT USAGE ON SCHEMA public TO api_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO api_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO api_readonly;

