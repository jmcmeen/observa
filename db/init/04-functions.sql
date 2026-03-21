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

-- Taxonomy tree: get the full lineage (ancestors) of a taxon.
-- Exposed via PostgREST at /rpc/taxon_lineage

CREATE OR REPLACE FUNCTION taxon_lineage(
    target_taxon_id integer
)
RETURNS TABLE (
    taxon_id integer,
    name varchar,
    rank varchar,
    rank_level double precision,
    depth integer
)
LANGUAGE sql STABLE
AS $$
    WITH RECURSIVE lineage AS (
        SELECT t.taxon_id, t.name, t.rank, t.rank_level, t.ancestry, 0 AS depth
        FROM taxa t
        WHERE t.taxon_id = target_taxon_id

        UNION ALL

        SELECT p.taxon_id, p.name, p.rank, p.rank_level, p.ancestry, l.depth + 1
        FROM lineage l
        JOIN taxa p ON p.taxon_id = (
            -- ancestry is a slash-separated list like "48460/1/2/3"
            -- the last element is the direct parent
            CASE WHEN l.ancestry IS NOT NULL AND l.ancestry != ''
                 THEN split_part(
                     l.ancestry,
                     '/',
                     array_length(string_to_array(l.ancestry, '/'), 1)
                 )::integer
            END
        )
        WHERE l.ancestry IS NOT NULL AND l.ancestry != ''
    )
    SELECT lineage.taxon_id, lineage.name, lineage.rank, lineage.rank_level, lineage.depth
    FROM lineage
    ORDER BY lineage.rank_level DESC;
$$;

GRANT EXECUTE ON FUNCTION taxon_lineage TO api_readonly;

-- Taxonomy tree: get direct children of a taxon.
-- Exposed via PostgREST at /rpc/taxon_children

CREATE OR REPLACE FUNCTION taxon_children(
    parent_id integer,
    lim integer DEFAULT 100
)
RETURNS TABLE (
    taxon_id integer,
    name varchar,
    rank varchar,
    rank_level double precision,
    observation_count bigint
)
LANGUAGE sql STABLE
AS $$
    SELECT
        t.taxon_id,
        t.name,
        t.rank,
        t.rank_level,
        count(o.observation_uuid) AS observation_count
    FROM taxa t
    LEFT JOIN observations o ON o.taxon_id = t.taxon_id
    WHERE t.ancestry LIKE '%/' || parent_id::text
       OR t.ancestry = parent_id::text
    GROUP BY t.taxon_id, t.name, t.rank, t.rank_level
    ORDER BY observation_count DESC
    LIMIT lim;
$$;

GRANT EXECUTE ON FUNCTION taxon_children TO api_readonly;
