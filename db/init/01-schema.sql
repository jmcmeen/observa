CREATE EXTENSION IF NOT EXISTS postgis;

-- Import log for tracking ETL runs
CREATE TABLE import_log (
    id serial PRIMARY KEY,
    started_at timestamptz NOT NULL,
    finished_at timestamptz,
    status varchar(20) NOT NULL DEFAULT 'running',
    observations_count bigint,
    photos_count bigint,
    taxa_count bigint,
    observers_count bigint
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
    anomaly_score double precision
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

-- PostGIS geometry column for spatial queries
SELECT AddGeometryColumn('observations', 'geom', 4326, 'POINT', 2);
