#!/usr/bin/env bash
# Rebuilds the PayHaven database from scratch and runs the constraint tests.
# Usage: ./run_all.sh            (uses PG* env vars, defaults below)
set -euo pipefail
cd "$(dirname "$0")"
export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}" PGUSER="${PGUSER:-postgres}" PGDATABASE="${PGDATABASE:-payhaven}"

for f in sql/01_schema.sql sql/02_functions_triggers.sql sql/03_views.sql sql/04_seed.sql; do
  echo ">> $f"
  psql -v ON_ERROR_STOP=1 -q -f "$f"
done

echo ">> tests/constraint_tests.sql"
psql -q -f tests/constraint_tests.sql
