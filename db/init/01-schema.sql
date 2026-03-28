CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

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
    active boolean,
    parent_id integer GENERATED ALWAYS AS (
        CASE WHEN ancestry IS NOT NULL AND ancestry != ''
             THEN split_part(ancestry, '/', array_length(string_to_array(ancestry, '/'), 1))::integer
        END
    ) STORED
);

CREATE TABLE observers (
    observer_id integer NOT NULL PRIMARY KEY,
    login varchar(255),
    name varchar(255)
);

CREATE INDEX idx_import_log_status_id ON import_log (status, id DESC);
CREATE INDEX idx_import_log_started_at ON import_log (started_at DESC);

-- Post-import data profiling stats
CREATE TABLE import_stats (
    id serial PRIMARY KEY,
    import_id integer NOT NULL REFERENCES import_log(id),
    null_taxon_pct numeric(5,2),
    null_location_pct numeric(5,2),
    null_observed_on_pct numeric(5,2),
    min_observed_on date,
    max_observed_on date,
    quality_research bigint,
    quality_needs_id bigint,
    quality_casual bigint,
    bbox_min_lat numeric(15,10),
    bbox_max_lat numeric(15,10),
    bbox_min_lon numeric(15,10),
    bbox_max_lon numeric(15,10),
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Allow the main user to query database size in Grafana
GRANT pg_read_all_stats TO CURRENT_USER;

-- Health endpoint for external uptime monitors (exposed via PostgREST)
CREATE OR REPLACE VIEW v_health AS
SELECT
    il.status AS last_import_status,
    il.finished_at AS last_import_at,
    round(EXTRACT(EPOCH FROM now() - il.finished_at) / 3600, 1) AS hours_since_import,
    il.observations_count,
    il.photos_count,
    il.taxa_count,
    il.observers_count,
    il.duration_seconds AS last_import_duration_seconds,
    il.error_message AS last_error
FROM import_log il
WHERE il.status IN ('completed', 'failed')
ORDER BY il.id DESC
LIMIT 1;

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

