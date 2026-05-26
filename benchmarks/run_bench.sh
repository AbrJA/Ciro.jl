#!/bin/bash
# Ciro.jl vs khttp (Rust) Benchmark Comparison
# Requires: oha (HTTP load testing tool)
#
# Usage:
#   Terminal 1: julia --threads=auto --project=. benchmarks/ciro_bench.jl
#   Terminal 2: ./benchmarks/khttp/target/release/server
#   Terminal 3: ./benchmarks/run_bench.sh

set -e

DURATION="10s"
CONNECTIONS=256
WARMUP="3s"

CIRO_PORT=8080
KHTTP_PORT=3000

echo "=============================================="
echo " Ciro.jl vs khttp (Rust) Benchmark"
echo "=============================================="
echo "Duration: $DURATION | Connections: $CONNECTIONS"
echo ""

# Verify servers are up
if ! curl -sf "http://127.0.0.1:${CIRO_PORT}/" > /dev/null; then
    echo "ERROR: Ciro.jl server not running on :${CIRO_PORT}"
    echo "  Start with: julia --threads=auto --project=. benchmarks/ciro_bench.jl"
    exit 1
fi

if ! curl -sf "http://127.0.0.1:${KHTTP_PORT}/" > /dev/null; then
    echo "ERROR: khttp server not running on :${KHTTP_PORT}"
    echo "  Build:  cd benchmarks/khttp && cargo build --release"
    echo "  Start:  ./benchmarks/khttp/target/release/server"
    exit 1
fi

run_bench() {
    local name="$1"
    local port="$2"
    local method="$3"
    local endpoint="$4"

    echo "--- [$name] $method $endpoint ---"
    if [ "$method" = "POST" ]; then
        oha -z "$DURATION" -c "$CONNECTIONS" \
            --no-tui -m POST -d "" \
            "http://127.0.0.1:${port}${endpoint}" 2>&1 | \
            grep -E "Requests/sec|Fastest|Slowest|Average|50%|99%|Success"
    else
        oha -z "$DURATION" -c "$CONNECTIONS" \
            --no-tui \
            "http://127.0.0.1:${port}${endpoint}" 2>&1 | \
            grep -E "Requests/sec|Fastest|Slowest|Average|50%|99%|Success"
    fi
    echo ""
}

echo "=== GET / (plaintext) ==="
run_bench "Ciro.jl" "$CIRO_PORT" "GET" "/"
run_bench "khttp  " "$KHTTP_PORT" "GET" "/"

echo "=== GET /user/:id (param route) ==="
run_bench "Ciro.jl" "$CIRO_PORT" "GET" "/user/42"
run_bench "khttp  " "$KHTTP_PORT" "GET" "/user/42"

echo "=== POST /user ==="
run_bench "Ciro.jl" "$CIRO_PORT" "POST" "/user"
run_bench "khttp  " "$KHTTP_PORT" "POST" "/user"


echo "=============================================="
echo " Benchmark Complete"
echo "=============================================="
