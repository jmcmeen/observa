# Custom Dashboards Guide

How to create your own Grafana dashboards using the Observa database. This guide walks through the panel types, query patterns, and provisioning setup so you can build dashboards for specific regions, taxa, or research questions.

## Getting started

Open Grafana at [http://localhost:3000](http://localhost:3000) and log in. Click **Dashboards > New > New dashboard** to create a blank dashboard, then **Add visualization** to start adding panels.

When prompted for a datasource, select **iNaturalist** (the pre-configured PostgreSQL connection). All queries in this guide use that datasource.

## Datasource reference

| Property | Value |
|---|---|
| Name | iNaturalist |
| UID | `inaturalist` |
| Type | PostgreSQL |
| Database | inaturalist (default) |

The UID `inaturalist` is what you'll see in panel JSON if you export dashboards. It's consistent across all pre-built dashboards.

## Panel types

The pre-built dashboards use six panel types. Here's when to use each and example SQL for common patterns.

### Stat — single number KPIs

Use for: total counts, percentages, key metrics at the top of a dashboard.

**Example: Total research-grade observations in an area**

```sql
SELECT count(*) AS "Observations"
FROM observations
WHERE quality_grade = 'research'
  AND latitude BETWEEN 10.0 AND 11.0
  AND longitude BETWEEN -84.5 AND -83.5
```

Set the format to **Table** in the query editor. Under panel options, set **Value options > Calculation** to "Last not null".

### Timeseries — trends over time

Use for: observation counts over months/years, seasonal patterns, growth trends.

**Example: Monthly observations for a taxon**

```sql
SELECT date_trunc('month', observed_on) AS time,
       count(*) AS observations
FROM observations
WHERE taxon_id = 3726
  AND observed_on IS NOT NULL
GROUP BY 1
ORDER BY 1
```

Set the format to **Time series**. The column named `time` is automatically used as the x-axis.

### Bar chart — ranked comparisons

Use for: species lists, top observers, comparing categories.

**Example: Top 20 species in an area**

```sql
SELECT t.name AS species, count(*) AS observations
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
WHERE o.quality_grade = 'research'
  AND t.rank = 'species'
  AND o.latitude BETWEEN 10.0 AND 11.0
  AND o.longitude BETWEEN -84.5 AND -83.5
GROUP BY t.name
ORDER BY observations DESC
LIMIT 20
```

Set format to **Table**. In panel options, set orientation to **Horizontal** for readable species names.

### Pie chart — proportional breakdowns

Use for: quality grade distribution, taxonomic rank breakdown, license types.

**Example: Quality grade distribution for a region**

```sql
SELECT quality_grade, count(*) AS total
FROM observations
WHERE latitude BETWEEN 10.0 AND 11.0
  AND longitude BETWEEN -84.5 AND -83.5
GROUP BY quality_grade
```

Set format to **Table**. Under panel options, set **Pie chart type** to "Donut" for a cleaner look.

### Geomap — observation locations

Use for: plotting observations on a map, spatial distribution.

**Example: Observation locations with species names**

```sql
SELECT o.latitude, o.longitude, t.name AS species
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
WHERE o.quality_grade = 'research'
  AND o.latitude BETWEEN 10.0 AND 11.0
  AND o.longitude BETWEEN -84.5 AND -83.5
  AND o.geom IS NOT NULL
LIMIT 5000
```

Set format to **Table**. In panel options under **Data layer**:

- Set **Location mode** to "Coords"
- Set **Latitude field** to `latitude`
- Set **Longitude field** to `longitude`

Set the initial **Map view** center and zoom to match your region of interest.

**Important:** Always use `LIMIT` on geomap queries. Rendering tens of thousands of points will make the browser slow.

### Table — detailed data

Use for: species lists with counts, observer leaderboards, recent imports.

**Example: Species checklist with observation and photo counts**

```sql
SELECT t.name AS species, count(DISTINCT o.observation_uuid) AS observations,
       count(DISTINCT p.photo_id) AS photos
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
LEFT JOIN photos p ON o.observation_uuid = p.observation_uuid
WHERE o.quality_grade = 'research'
  AND t.rank = 'species'
  AND o.latitude BETWEEN 10.0 AND 11.0
  AND o.longitude BETWEEN -84.5 AND -83.5
GROUP BY t.name
ORDER BY observations DESC
LIMIT 50
```

## Using materialized views

For dashboard-wide metrics that don't need geographic or taxonomic filtering, query the materialized views directly. They're pre-aggregated and fast:

```sql
-- Monthly trend (no filtering needed)
SELECT month AS time, observation_count
FROM mv_observations_monthly
ORDER BY month

-- Top species globally
SELECT name, rank, observation_count
FROM mv_top_taxa
WHERE rank = 'species'
ORDER BY observation_count DESC
LIMIT 20

-- Quality grade breakdown
SELECT * FROM mv_quality_grade_counts
```

See [data-model.md](data-model.md) for the full list of materialized views and their columns.

## Filtering by taxonomy

To filter a dashboard to a specific taxonomic group, use the `ancestry` column in the `taxa` table. Every taxon stores its ancestor chain as a slash-separated string of `taxon_id` values.

**Filter to all frogs (Anura, taxon_id 20979):**

```sql
SELECT o.observed_on, o.latitude, o.longitude, t.name
FROM observations o
JOIN taxa t ON o.taxon_id = t.taxon_id
WHERE (t.ancestry LIKE '%/20979/%' OR t.taxon_id = 20979)
  AND o.quality_grade = 'research'
```

**Find a taxon_id by name:**

```sql
SELECT taxon_id, name, rank FROM taxa WHERE name ILIKE '%anura%';
```

## Using the Regional Explorer dashboard

The **Regional Explorer** is a pre-built parameterized dashboard that works for any region and taxonomic group. Instead of building a dashboard from scratch, set the variables at the top:

| Variable | Description | Default | Example |
|---|---|---|---|
| Min Latitude | Southern bound | -90 | 10.40 |
| Max Latitude | Northern bound | 90 | 10.47 |
| Min Longitude | Western bound | -180 | -84.05 |
| Max Longitude | Eastern bound | 180 | -83.97 |
| Taxon ID | Filter to a taxonomic group (0 = all) | 0 | 20979 (frogs) |
| Quality Grade | Multi-select filter | All | research |

Use [bboxfinder.com](http://bboxfinder.com/) to get bounding box coordinates for your area. To find a taxon ID, query the database:

```sql
SELECT taxon_id, name, rank FROM taxa WHERE name ILIKE '%anura%';
```

The dashboard includes 11 panels: stat KPIs, timeseries, species bar chart, quality grade pie chart, taxonomic breakdown, observation map, observer leaderboard, and seasonal patterns — all filtered by your variables.

## Building a custom dashboard from scratch

If you need panels or queries beyond what the Regional Explorer provides, create a new dashboard manually.

### 1. Use dashboard variables

Variables let users filter without editing SQL. Add them under Dashboard settings > Variables:

1. Create a **Query** variable with:
   - **Name:** `quality_grade`
   - **Query:** `SELECT DISTINCT quality_grade FROM observations WHERE quality_grade IS NOT NULL ORDER BY 1;`
   - **Multi-value:** enabled
2. Use it in panel queries:
   ```sql
   WHERE quality_grade IN ($quality_grade)
   ```

This lets dashboard viewers filter by quality grade without editing queries.

## Saving and provisioning

### Option A: Save in Grafana (simplest)

Click **Save dashboard** in the Grafana UI. The dashboard is stored in the `grafana_data` Docker volume and persists across restarts.

### Option B: Provision from JSON (version-controlled)

To include your dashboard in the Git repo so it deploys automatically:

1. **Export the dashboard** — In Grafana, open your dashboard > Share > Export > Save to file
2. **Save the JSON** to `grafana/provisioning/dashboards/`:
   ```bash
   mv ~/Downloads/my-dashboard.json grafana/provisioning/dashboards/
   ```
3. **Restart Grafana** to pick up the new file:
   ```bash
   docker compose restart grafana
   ```

Provisioned dashboards are automatically loaded on startup. Edits made in the Grafana UI will be overwritten on restart unless you remove the JSON file.

## Query performance tips

- **Use materialized views** for global metrics — they're orders of magnitude faster than querying the base tables.
- **Always add `LIMIT`** to geomap and table panels. The observations table has ~200M rows.
- **Filter by `quality_grade`** early — it reduces the working set significantly.
- **Use composite indexes** — Queries filtering on `(taxon_id, quality_grade)` or `(observed_on, taxon_id)` hit dedicated indexes.
- **Avoid `SELECT *`** — Select only the columns you need, especially for large tables.
- **Bounding box first, join second** — Filter observations geographically before joining to taxa/photos.
