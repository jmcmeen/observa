-- Drop existing indexes before recreating (idempotent)
DROP INDEX IF EXISTS idx_observations_taxon_id;
DROP INDEX IF EXISTS idx_observations_observer_id;
DROP INDEX IF EXISTS idx_observations_quality_grade;
DROP INDEX IF EXISTS idx_observations_observed_on;
DROP INDEX IF EXISTS idx_observations_geom;
DROP INDEX IF EXISTS idx_photos_observation_uuid;
DROP INDEX IF EXISTS idx_photos_observer_id;
DROP INDEX IF EXISTS idx_taxa_ancestry;
DROP INDEX IF EXISTS idx_taxa_parent_id;

-- Observation indexes
CREATE INDEX idx_observations_taxon_id ON observations (taxon_id);
CREATE INDEX idx_observations_observer_id ON observations (observer_id);
CREATE INDEX idx_observations_quality_grade ON observations (quality_grade);
CREATE INDEX idx_observations_observed_on ON observations (observed_on);
CREATE INDEX idx_observations_geom ON observations USING GIST (geom);

-- Composite indexes for common query patterns
CREATE INDEX idx_observations_taxon_quality ON observations (taxon_id, quality_grade);
CREATE INDEX idx_observations_date_taxon ON observations (observed_on, taxon_id);

-- Photo indexes
CREATE INDEX idx_photos_observation_uuid ON photos (observation_uuid);
CREATE INDEX idx_photos_observer_id ON photos (observer_id);

-- Taxa name search (trigram)
CREATE INDEX idx_taxa_name_trgm ON taxa USING gin (name gin_trgm_ops);

-- Taxa parent lookup (taxon_children)
CREATE INDEX idx_taxa_parent_id ON taxa (parent_id);

-- Observer login lookup
CREATE INDEX idx_observers_login ON observers (login);

-- Analyze all tables
VACUUM ANALYZE observations;
VACUUM ANALYZE photos;
VACUUM ANALYZE taxa;
VACUUM ANALYZE observers;
