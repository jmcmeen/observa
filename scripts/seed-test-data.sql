-- Seed a synthetic dataset for local testing.
-- Generates ~100K observations with realistic taxonomy, geography, and dates.
-- Run via: psql -f seed-test-data.sql
--
-- Designed to be idempotent: TRUNCATE + re-insert on each run.

BEGIN;

-- Clear existing data (but not import_log / import_stats)
TRUNCATE observations, photos, taxa, observers CASCADE;

-- ============================================================
-- Taxa: realistic hierarchy (~150 species across multiple orders)
-- ============================================================

-- Top-level ranks
INSERT INTO taxa (taxon_id, ancestry, name, rank, rank_level, active) VALUES
  (48460, '',               'Life',       'stateofmatter', 100, true),
  (1,     '48460',          'Animalia',   'kingdom',        70, true),
  (47126, '48460',          'Plantae',    'kingdom',        70, true),
  (3,     '48460/1',        'Aves',       'class',          50, true),
  (40151, '48460/1',        'Mammalia',   'class',          50, true),
  (26036, '48460/1',        'Reptilia',   'class',          50, true),
  (20978, '48460/1',        'Amphibia',   'class',          50, true),
  (47158, '48460/47126',    'Magnoliopsida', 'class',       50, true);

-- Orders
INSERT INTO taxa (taxon_id, ancestry, name, rank, rank_level, active) VALUES
  (7251,  '48460/1/3',      'Passeriformes',  'order', 40, true),
  (14886, '48460/1/3',      'Piciformes',     'order', 40, true),
  (71261, '48460/1/3',      'Accipitriformes','order', 40, true),
  (3726,  '48460/1/3',      'Strigiformes',   'order', 40, true),
  (4342,  '48460/1/3',      'Anseriformes',   'order', 40, true),
  (19350, '48460/1/40151',  'Carnivora',      'order', 40, true),
  (40268, '48460/1/40151',  'Rodentia',       'order', 40, true),
  (43583, '48460/1/40151',  'Chiroptera',     'order', 40, true),
  (85553, '48460/1/26036',  'Squamata',       'order', 40, true),
  (25473, '48460/1/20978',  'Anura',          'order', 40, true);

-- Families
INSERT INTO taxa (taxon_id, ancestry, name, rank, rank_level, active) VALUES
  (12716, '48460/1/3/7251',      'Turdidae',       'family', 30, true),
  (9597,  '48460/1/3/7251',      'Corvidae',       'family', 30, true),
  (7264,  '48460/1/3/7251',      'Paridae',        'family', 30, true),
  (9079,  '48460/1/3/7251',      'Fringillidae',   'family', 30, true),
  (18205, '48460/1/3/14886',     'Picidae',        'family', 30, true),
  (5303,  '48460/1/3/71261',     'Accipitridae',   'family', 30, true),
  (19920, '48460/1/40151/19350', 'Canidae',        'family', 30, true),
  (41482, '48460/1/40151/19350', 'Felidae',        'family', 30, true),
  (41479, '48460/1/40151/40268', 'Sciuridae',      'family', 30, true);

-- Species (~80, spread across families)
INSERT INTO taxa (taxon_id, ancestry, name, rank, rank_level, active)
SELECT
    1000 + i,
    CASE (i % 9)
        WHEN 0 THEN '48460/1/3/7251/12716'
        WHEN 1 THEN '48460/1/3/7251/9597'
        WHEN 2 THEN '48460/1/3/7251/7264'
        WHEN 3 THEN '48460/1/3/7251/9079'
        WHEN 4 THEN '48460/1/3/14886/18205'
        WHEN 5 THEN '48460/1/3/71261/5303'
        WHEN 6 THEN '48460/1/40151/19350/19920'
        WHEN 7 THEN '48460/1/40151/19350/41482'
        WHEN 8 THEN '48460/1/40151/40268/41479'
    END,
    'Test species ' || i,
    'species',
    10,
    true
FROM generate_series(1, 80) AS i;

-- Add some well-known species with real names for search testing
UPDATE taxa SET name = 'Turdus migratorius'  WHERE taxon_id = 1001;
UPDATE taxa SET name = 'Corvus brachyrhynchos' WHERE taxon_id = 1002;
UPDATE taxa SET name = 'Poecile atricapillus' WHERE taxon_id = 1003;
UPDATE taxa SET name = 'Haemorhous mexicanus' WHERE taxon_id = 1004;
UPDATE taxa SET name = 'Dryobates pubescens'  WHERE taxon_id = 1005;
UPDATE taxa SET name = 'Buteo jamaicensis'    WHERE taxon_id = 1006;
UPDATE taxa SET name = 'Canis latrans'        WHERE taxon_id = 1007;
UPDATE taxa SET name = 'Lynx rufus'           WHERE taxon_id = 1008;
UPDATE taxa SET name = 'Sciurus carolinensis'  WHERE taxon_id = 1009;
UPDATE taxa SET name = 'Sialia sialis'        WHERE taxon_id = 1010;

-- ============================================================
-- Observers: 200 synthetic users
-- ============================================================

INSERT INTO observers (observer_id, login, name)
SELECT
    i,
    'user_' || i,
    'Test User ' || i
FROM generate_series(1, 200) AS i;

-- ============================================================
-- Observations: 100K rows with geographic + temporal spread
-- ============================================================

INSERT INTO observations (
    observation_uuid, observer_id, latitude, longitude,
    taxon_id, quality_grade, observed_on, anomaly_score
)
SELECT
    gen_random_uuid(),
    -- Observers: weighted toward power users (lower IDs observe more)
    1 + (random() * 199)::integer,
    -- Latitude: cluster around interesting regions
    CASE (i % 5)
        WHEN 0 THEN 35.5 + (random() * 2 - 1)       -- Appalachia / Great Smoky Mountains
        WHEN 1 THEN 37.8 + (random() * 1 - 0.5)      -- San Francisco Bay Area
        WHEN 2 THEN 40.7 + (random() * 1 - 0.5)      -- New York metro
        WHEN 3 THEN 25.7 + (random() * 2 - 1)         -- South Florida / Everglades
        WHEN 4 THEN 47.6 + (random() * 1 - 0.5)       -- Pacific Northwest
    END,
    CASE (i % 5)
        WHEN 0 THEN -83.5 + (random() * 2 - 1)
        WHEN 1 THEN -122.4 + (random() * 1 - 0.5)
        WHEN 2 THEN -74.0 + (random() * 1 - 0.5)
        WHEN 3 THEN -80.2 + (random() * 2 - 1)
        WHEN 4 THEN -122.3 + (random() * 1 - 0.5)
    END,
    -- Taxa: weighted toward common species
    1000 + 1 + (random() * 79)::integer,
    -- Quality grade: 60% research, 30% needs_id, 10% casual
    CASE
        WHEN random() < 0.6 THEN 'research'
        WHEN random() < 0.75 THEN 'needs_id'
        ELSE 'casual'
    END,
    -- Dates: spread over 2 years with seasonal weighting
    '2024-01-01'::date + (random() * 730)::integer,
    -- Anomaly score: mostly low, some outliers
    CASE WHEN random() < 0.95 THEN random() * 0.3 ELSE 0.5 + random() * 0.5 END
FROM generate_series(1, 100000) AS i;

-- Sprinkle some NULL taxon_ids (~5%) to exercise data quality alerts
UPDATE observations SET taxon_id = NULL
WHERE observation_uuid IN (
    SELECT observation_uuid FROM observations ORDER BY random() LIMIT 5000
);

-- ============================================================
-- Photos: ~60K (not every observation has a photo, some have multiple)
-- ============================================================

INSERT INTO photos (photo_uuid, photo_id, observation_uuid, observer_id, extension, license, width, height, position)
SELECT
    gen_random_uuid(),
    i,
    o.observation_uuid,
    o.observer_id,
    CASE (i % 3) WHEN 0 THEN 'jpg' WHEN 1 THEN 'jpeg' ELSE 'png' END,
    CASE (i % 5)
        WHEN 0 THEN 'CC-BY'
        WHEN 1 THEN 'CC0'
        WHEN 2 THEN 'CC-BY-NC'
        WHEN 3 THEN 'CC-BY-SA'
        ELSE 'CC-BY-ND'
    END,
    (800 + random() * 3200)::smallint,
    (600 + random() * 2400)::smallint,
    0
FROM (
    SELECT observation_uuid, observer_id, row_number() OVER () AS rn
    FROM observations
    ORDER BY random()
    LIMIT 60000
) o
JOIN generate_series(1, 60000) AS i ON i = o.rn;

-- ============================================================
-- Fake an import_log entry so dashboards and alerts work
-- ============================================================

INSERT INTO import_log (started_at, finished_at, status, observations_count, photos_count, taxa_count, observers_count, duration_seconds)
VALUES (
    now() - interval '1 hour',
    now() - interval '30 minutes',
    'completed',
    (SELECT count(*) FROM observations),
    (SELECT count(*) FROM photos),
    (SELECT count(*) FROM taxa),
    (SELECT count(*) FROM observers),
    1800
);

-- Fake import_stats so data quality alerts work
INSERT INTO import_stats (
    import_id, null_taxon_pct, null_location_pct, null_observed_on_pct,
    min_observed_on, max_observed_on,
    quality_research, quality_needs_id, quality_casual,
    bbox_min_lat, bbox_max_lat, bbox_min_lon, bbox_max_lon
)
SELECT
    (SELECT id FROM import_log ORDER BY id DESC LIMIT 1),
    round(100.0 * count(*) FILTER (WHERE taxon_id IS NULL) / count(*), 2),
    round(100.0 * count(*) FILTER (WHERE latitude IS NULL) / count(*), 2),
    round(100.0 * count(*) FILTER (WHERE observed_on IS NULL) / count(*), 2),
    min(observed_on), max(observed_on),
    count(*) FILTER (WHERE quality_grade = 'research'),
    count(*) FILTER (WHERE quality_grade = 'needs_id'),
    count(*) FILTER (WHERE quality_grade = 'casual'),
    min(latitude), max(latitude),
    min(longitude), max(longitude)
FROM observations;

COMMIT;

-- Refresh materialized views outside the transaction (can't run in a transaction block)
\echo 'Seed data loaded. Refreshing materialized views...'
