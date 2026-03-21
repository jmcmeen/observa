#!/bin/sh
# Smoke test for all Observa API endpoints.
# Usage: ./scripts/test-api.sh [base_url]
#
# Exits 0 if all tests pass, 1 if any fail.

set -e

BASE_URL="${1:-http://localhost:3001}"
PASS=0
FAIL=0

test_endpoint() {
    desc="$1"
    url="$2"
    expect="$3"  # string that must appear in the response

    response=$(curl -sf "$url" 2>/dev/null) || response=""

    if [ -z "$response" ]; then
        printf "  FAIL  %s\n" "$desc"
        printf "        → no response from %s\n" "$url"
        FAIL=$((FAIL + 1))
        return
    fi

    if [ -n "$expect" ]; then
        case "$response" in
            *"$expect"*)
                printf "  PASS  %s\n" "$desc"
                PASS=$((PASS + 1))
                ;;
            *)
                printf "  FAIL  %s\n" "$desc"
                printf "        → expected '%s' in response\n" "$expect"
                FAIL=$((FAIL + 1))
                ;;
        esac
    else
        # Just check we got a non-empty response
        printf "  PASS  %s\n" "$desc"
        PASS=$((PASS + 1))
    fi
}

echo "=== Observa API Smoke Tests ==="
echo "    Target: ${BASE_URL}"
echo ""

echo "--- Tables & Views ---"
test_endpoint "GET observations (limit 5)"      "${BASE_URL}/observations?limit=5"            "observation_uuid"
test_endpoint "GET taxa (limit 5)"               "${BASE_URL}/taxa?limit=5"                    "taxon_id"
test_endpoint "GET observers (limit 5)"          "${BASE_URL}/observers?limit=5"               "observer_id"
test_endpoint "GET photos (limit 5)"             "${BASE_URL}/photos?limit=5"                  "photo_id"
test_endpoint "GET health endpoint"              "${BASE_URL}/v_health"                        "last_import_status"
test_endpoint "GET quality grade counts"         "${BASE_URL}/mv_quality_grade_counts"         "quality_grade"
test_endpoint "GET top taxa"                     "${BASE_URL}/mv_top_taxa?limit=5"             "observation_count"
test_endpoint "GET top observers"                "${BASE_URL}/mv_top_observers?limit=5"        "observation_count"
test_endpoint "GET monthly observations"         "${BASE_URL}/mv_observations_monthly?limit=5" "month"
test_endpoint "GET photo licenses"               "${BASE_URL}/mv_photo_licenses"               "license"
test_endpoint "GET observations by rank"         "${BASE_URL}/mv_observations_by_rank"         "rank"
test_endpoint "GET observations grid"            "${BASE_URL}/mv_observations_grid?limit=5"    "grid_geom"

echo ""
echo "--- RPC Functions ---"
test_endpoint "Spatial: observations_near"       "${BASE_URL}/rpc/observations_near?lat=35.5&lon=-83.5&radius_km=50"  "distance_m"
test_endpoint "Search: taxa_search"              "${BASE_URL}/rpc/taxa_search?query=turdus"    "similarity"
test_endpoint "Tree: taxon_lineage"              "${BASE_URL}/rpc/taxon_lineage?target_taxon_id=1001" "rank_level"
test_endpoint "Tree: taxon_children"             "${BASE_URL}/rpc/taxon_children?parent_id=3"  "observation_count"

echo ""
echo "--- Filtering ---"
test_endpoint "Filter by quality_grade"          "${BASE_URL}/observations?quality_grade=eq.research&limit=3"  "research"
test_endpoint "Filter taxa by name (ILIKE)"      "${BASE_URL}/taxa?name=ilike.*turdus*"        "taxon_id"

echo ""
echo "--- Content Negotiation ---"
csv_response=$(curl -sf -H "Accept: text/csv" "${BASE_URL}/taxa?limit=3" 2>/dev/null || echo "")
case "$csv_response" in
    *taxon_id*)
        printf "  PASS  CSV export (Accept: text/csv)\n"
        PASS=$((PASS + 1))
        ;;
    *)
        printf "  FAIL  CSV export (Accept: text/csv)\n"
        FAIL=$((FAIL + 1))
        ;;
esac

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
