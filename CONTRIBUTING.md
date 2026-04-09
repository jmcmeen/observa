# Contributing to Observa

Thanks for considering a contribution. Observa is a small, opinionated platform — bug fixes, dashboard contributions, documentation improvements, and well-scoped features are all welcome. This guide covers what you need to know to get a change merged.

## Code of conduct

Be respectful and constructive in issues, PRs, and discussions. Assume good intent.

## Reporting bugs

Open a [GitHub issue](https://github.com/jmcmeen/observa/issues) and include:

- **What you expected to happen** and **what actually happened**.
- **How to reproduce it** — exact commands, dashboard names, panel IDs, or API requests.
- **Environment** — output of `docker compose version` and `docker compose ps`, your host OS, and approximate hardware (RAM matters for the importer).
- **Relevant logs** — `docker compose logs <service> --tail 100` for the service that misbehaved. Scrub passwords from `.env` before pasting.
- **Database state** if applicable — output of `SELECT * FROM import_log ORDER BY id DESC LIMIT 5;` and `SELECT * FROM v_health;` is often enough to diagnose import or alert issues.

If you're hitting an alert, please mention the alert UID (visible in the Grafana UI under Alerting → Alert rules) so the maintainer can find the rule definition quickly.

## Suggesting features

Open an issue first describing the use case before writing code. Observa intentionally stays focused on hosting and exploring the iNaturalist Open Dataset; features that require sourcing additional data or adding new services usually need design discussion before implementation.

Good first issues are tagged `good first issue` on GitHub. Dashboard contributions and documentation improvements are almost always accepted without prior discussion.

## Development setup

### Prerequisites

- Docker and Docker Compose v2+
- ~50 GB free disk space (full dataset) or ~2 GB (test harness only)
- 16 GB RAM recommended for the full dataset; 4 GB is enough for the test harness

### First-time setup

```bash
git clone https://github.com/jmcmeen/observa.git
cd observa
cp .env.example .env
# Edit .env and set strong passwords for POSTGRES_PASSWORD,
# API_USER_PASSWORD, and GF_SECURITY_ADMIN_PASSWORD
docker compose up -d
```

The importer will refuse to start if any password is still `changeme`.

### Working with synthetic data (recommended for development)

You almost never need to download the full ~10 GB iNaturalist dataset to develop against Observa. The test harness seeds 100K synthetic observations, refreshes materialized views, and runs API smoke tests in under a minute:

```bash
./scripts/test-local.sh
```

This generates a realistic dataset with 10 orders, 9 families, 80 species (including herpetofauna under Amphibia/Reptilia ancestry), 200 observers, geographically clustered observations across 5 US regions, 60K photos, and seasonal date spread — enough to exercise every dashboard, RPC function, alert, and CSV export.

### Working with the real dataset

If you specifically need to test against the real dataset (e.g., reproducing a performance regression):

```bash
docker compose run --rm --entrypoint /import.sh importer
```

The first import takes 30–60 minutes and downloads ~10 GB. Subsequent runs are cached via S3 ETags and skip when upstream is unchanged.

## Running tests and linters

CI runs four checks on every PR ([.github/workflows/ci.yml](.github/workflows/ci.yml)). Run them locally before pushing:

| Check | Command |
|---|---|
| ShellCheck (shell scripts) | `docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable -S warning $(find . -name '*.sh')` |
| Hadolint (Dockerfiles) | `docker run --rm -i hadolint/hadolint < importer/Dockerfile` |
| Docker Compose validation | `docker compose config --quiet` |
| YAML lint | `yamllint -d relaxed docker-compose.yml grafana/provisioning/` |

Plus the integration smoke test:

```bash
./scripts/test-local.sh
```

If you change SQL in a Grafana alert or dashboard, also test the query directly against the database before opening a PR:

```bash
docker compose exec postgres psql -U observa -d inaturalist -c "<your query>"
```

## Project layout

| Path | Purpose |
|---|---|
| [db/init/](db/init/) | SQL files run once on first database startup. Schema, materialized view stubs, RPC functions. **Changes here only affect new installs** — existing installs need a manual migration. |
| [db/scripts/](db/scripts/) | Reusable SQL scripts the importer runs on every import (e.g., `create-materialized-views.sql`, `create-indexes.sql`). |
| [importer/](importer/) | The ETL container. `import.sh` is the entrypoint orchestrating download, validate, load, swap, refresh. `download.py` handles S3 + ETag caching. |
| [grafana/provisioning/dashboards/](grafana/provisioning/dashboards/) | Dashboard JSON files. Auto-loaded by Grafana on startup. |
| [grafana/provisioning/alerting/alerts.yml](grafana/provisioning/alerting/alerts.yml) | Alert rule definitions. |
| [grafana/provisioning/datasources/postgres.yml](grafana/provisioning/datasources/postgres.yml) | Postgres datasource (UID `inaturalist`). |
| [scripts/](scripts/) | Test harness, seed data, API smoke tests, uninstall. |
| [docs/](docs/) | User-facing documentation. |
| [nginx/](nginx/) | Reverse proxy + rate limiting in front of PostgREST. |

If you're writing SQL against the database, [docs/schema-definition.md](docs/schema-definition.md) is the structured reference (table/column types, RPC signatures, useful taxon IDs, gotchas) and [docs/data-model.md](docs/data-model.md) is the prose tour with worked examples.

## Common contribution tasks

### Adding a new Grafana dashboard

1. Build the dashboard in the Grafana UI (http://localhost:3000) against a local install seeded with `./scripts/test-local.sh`.
2. Export it via the Grafana UI: **Share → Export → Save to file**. **Uncheck "Export for sharing externally"** so the datasource UID stays as `inaturalist` instead of becoming a `${DS_*}` variable.
3. Save the file to [grafana/provisioning/dashboards/](grafana/provisioning/dashboards/).
4. Strip the `__inputs` block if present (provisioned dashboards don't use it), and confirm every panel uses `{ "type": "postgres", "uid": "inaturalist" }` as the datasource.
5. For any query that filters by taxonomic group, use the wrapped-delimiter ancestry pattern documented in [docs/schema-definition.md](docs/schema-definition.md#canonical-idioms) — do not use the naive `LIKE '%/X/%'` form, which misses direct child taxa.
6. Validate the JSON: `python3 -c "import json; json.load(open('grafana/provisioning/dashboards/yourname.json'))"`.
7. Restart Grafana to load it: `docker restart observa-grafana-1`.
8. Add a one-line entry to the dashboard list in [README.md](README.md) and a CHANGELOG entry under the next version's `### Features`.

### Adding a new docs page

1. Add the file under [docs/](docs/) using the `dashed-lowercase.md` naming convention.
2. Link it from the **Documentation** table in [README.md](README.md).
3. If it documents query patterns or schema details, also link it from [docs/data-model.md](docs/data-model.md) and [docs/schema-definition.md](docs/schema-definition.md) so readers find it from any entry point.

### Modifying the database schema

Schema changes are tricky because [db/init/](db/init/) only runs on **first** database startup. Existing installs won't pick up changes automatically.

For changes that work via `CREATE OR REPLACE` (views, functions):

1. Edit the canonical definition in [db/init/](db/init/) so new installs get it.
2. Apply the same `CREATE OR REPLACE` statement to a running test database to verify it works.
3. Document the manual migration in the CHANGELOG entry so existing operators know to run it.

For changes that require `ALTER TABLE` or migration logic, open an issue first to discuss approach — Observa does not currently have a migration framework.

### Modifying an alert or adding a new one

1. Edit [grafana/provisioning/alerting/alerts.yml](grafana/provisioning/alerting/alerts.yml).
2. Test the underlying SQL query directly against the database:

   ```bash
   docker compose exec postgres psql -U observa -d inaturalist -c "<query>"
   ```

   The query must return exactly one row containing one numeric value, or you need to set `noDataState` explicitly to avoid NoData → alerting confusion.
3. Restart Grafana: `docker restart observa-grafana-1`.
4. Verify with the API: `curl -s -u "admin:$GF_PASS" 'http://localhost:3000/api/prometheus/grafana/api/v1/alerts'`.

### Modifying the importer

`import.sh` is baked into the importer image (no bind-mount), so changes require a rebuild:

```bash
docker compose up -d --build importer
```

Test the change by triggering a manual run:

```bash
docker exec observa-importer-1 /import.sh
```

## Code style

- **Shell scripts:** POSIX `sh` (the importer runs on Alpine `ash`, not `bash`). Use `set -e`, quote variable expansions, use `[ ]` not `[[ ]]`, and run ShellCheck before pushing.
- **SQL:** Lowercase keywords (`select`, `from`, `where`) — match the style of [db/init/01-schema.sql](db/init/01-schema.sql). Use `psql -v ON_ERROR_STOP=1` in scripts.
- **Python (importer):** Match the style of [importer/download.py](importer/download.py). Use type hints where reasonable.
- **YAML:** 2-space indent, no tabs. `yamllint -d relaxed` is the bar.
- **Markdown:** Use dashed-lowercase filenames. Reference files using markdown links so they're clickable in editors.

## Commit messages and PRs

- Keep commits focused — one logical change per commit when possible.
- Commit messages should be descriptive but don't need to follow Conventional Commits or any other strict format.
- PRs are squash-merged into `main`. Write a clear PR description summarizing the change and the motivation.
- If your change is user-visible, add a CHANGELOG entry under the next version's appropriate section (`### Features`, `### Bug Fixes`, `### Documentation`, etc.). Match the style of existing entries — short bold title, em-dash, prose explanation.
- Reference any related issues with `Fixes #N` or `Closes #N` in the PR description.

## What gets reviewed

The maintainer will look for:

1. **Does it work?** Did you actually run `./scripts/test-local.sh`?
2. **Is it scoped?** A bug fix should fix the bug, not refactor surrounding code. A new feature should not also rewrite an existing one.
3. **Does it match existing patterns?** Look at how similar things are done elsewhere in the codebase before inventing new conventions.
4. **Documentation updated?** README, CHANGELOG, and the relevant `docs/` page if applicable.
5. **CI green?** All four checks in [.github/workflows/ci.yml](.github/workflows/ci.yml) must pass.

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE), the same license as the rest of Observa.
