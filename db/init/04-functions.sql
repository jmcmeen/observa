-- Spatial query: find observations within a radius of a point.
-- Exposed via PostgREST at /rpc/observations_near

CREATE OR REPLACE FUNCTION observations_near(
    lat double precision,
    lon double precision,
    radius_km double precision DEFAULT 10,
    lim integer DEFAULT 100
)
RETURNS TABLE (
    observation_uuid uuid,
    taxon_id integer,
    quality_grade varchar,
    observed_on date,
    distance_m double precision
)
LANGUAGE sql STABLE
AS $$
    SELECT
        observation_uuid,
        taxon_id,
        quality_grade,
        observed_on,
        ST_Distance(
            geom::geography,
            ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography
        ) AS distance_m
    FROM observations
    WHERE ST_DWithin(
        geom::geography,
        ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography,
        radius_km * 1000
    )
    ORDER BY distance_m
    LIMIT lim;
$$;

GRANT EXECUTE ON FUNCTION observations_near TO api_readonly;

-- Fuzzy taxa search: find taxa by name with typo tolerance.
-- Exposed via PostgREST at /rpc/taxa_search
-- Uses pg_trgm similarity() for ranking and ILIKE for prefix/substring matches.

CREATE OR REPLACE FUNCTION taxa_search(
    query text,
    lim integer DEFAULT 20
)
RETURNS TABLE (
    taxon_id integer,
    name varchar,
    rank varchar,
    rank_level double precision,
    active boolean,
    similarity real
)
LANGUAGE sql STABLE
AS $$
    SELECT
        t.taxon_id,
        t.name,
        t.rank,
        t.rank_level,
        t.active,
        similarity(t.name, query) AS similarity
    FROM taxa t
    WHERE t.name ILIKE '%' || query || '%'
       OR similarity(t.name, query) > 0.1
    ORDER BY similarity(t.name, query) DESC, t.name
    LIMIT lim;
$$;

GRANT EXECUTE ON FUNCTION taxa_search TO api_readonly;
