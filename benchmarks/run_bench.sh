#!/bin/bash
# Ciro.jl vs Actix-web Benchmark Comparison
# Requires: oha (HTTP load testing tool)

set -e

DURATION="10s"
CONNECTIONS=256
THREADS=$(nproc)
WARMUP="3s"

echo "=============================================="
echo " Ciro.jl vs Actix-web Performance Comparison"
echo "=============================================="
echo "Duration: $DURATION | Connections: $CONNECTIONS | Threads: $THREADS"
echo ""

run_bench() {
    local name="$1"
    local port="$2"
    local endpoint="$3"
    local label="$4"

    echo "--- $name: $label ($endpoint) ---"
    oha -z "$DURATION" -c "$CONNECTIONS" \
        --no-tui \
        "http://127.0.0.1:${port}${endpoint}" 2>&1 | \
        grep -E "Requests/sec|Fastest|Slowest|Average|50%|99%|Success rate"
    echo ""
}

echo "=== Plaintext (GET /) ==="
echo ""
run_bench "Ciro.jl" 8080 "/" "plaintext"
run_bench "Actix-web" 8081 "/" "plaintext"

echo "=== Static Route (GET /hello) ==="
echo ""
run_bench "Ciro.jl" 8080 "/hello" "static route"
run_bench "Actix-web" 8081 "/hello" "static route"

echo "=== JSON Response (GET /json) ==="
echo ""
run_bench "Ciro.jl" 8080 "/json" "JSON"
run_bench "Actix-web" 8081 "/json" "JSON"

echo "=== Parameterized Route (GET /user/42) ==="
echo ""
run_bench "Ciro.jl" 8080 "/user/42" "param route"
run_bench "Actix-web" 8081 "/user/42" "param route"

echo "=============================================="
echo " Benchmark Complete"
echo "=============================================="
