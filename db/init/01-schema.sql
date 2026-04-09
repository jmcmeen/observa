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

-- Health endpoint for external uptime monitors (exposed via PostgREST).
--
-- last_import_status / last_import_at / hours_since_import answer
-- "is the cron job running?" — they reflect the most recent terminal run of any
-- kind (completed, skipped, or failed). A 'skipped' status with a recent
-- timestamp means the importer ran on schedule and found the upstream S3 data
-- unchanged, which is healthy.
--
-- observations_count / photos_count / taxa_count / observers_count answer
-- "how much data is loaded?" — they always reflect the most recent successful
-- 'completed' import, since 'skipped' rows have no counts.
CREATE OR REPLACE VIEW v_health AS
WITH last_run AS (
    SELECT id, status, finished_at, duration_seconds, error_message
    FROM import_log
    WHERE status IN ('completed', 'skipped', 'failed')
    ORDER BY id DESC
    LIMIT 1
),
last_completed AS (
    SELECT observations_count, photos_count, taxa_count, observers_count
    FROM import_log
    WHERE status = 'completed'
    ORDER BY id DESC
    LIMIT 1
)
SELECT
    lr.status AS last_import_status,
    lr.finished_at AS last_import_at,
    round(EXTRACT(EPOCH FROM now() - lr.finished_at) / 3600, 1) AS hours_since_import,
    lc.observations_count,
    lc.photos_count,
    lc.taxa_count,
    lc.observers_count,
    lr.duration_seconds AS last_import_duration_seconds,
    lr.error_message AS last_error
FROM last_run lr
LEFT JOIN last_completed lc ON true;

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

