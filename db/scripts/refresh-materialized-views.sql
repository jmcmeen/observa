-- Refresh all materialized views without taking an exclusive lock.
-- Requires a UNIQUE INDEX on each view (see create-materialized-views.sql).

REFRESH MATERIALIZED VIEW CONCURRENTLY mv_observations_monthly;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_quality_grade_counts;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_top_taxa;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_top_observers;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_photo_licenses;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_observations_by_rank;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_observations_grid;
