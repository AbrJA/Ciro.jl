#!/bin/bash
# Ciro.jl vs khttp (Rust) — Keep-Alive vs Connection-Close Benchmark
# Requires: oha (HTTP load testing tool)  https://github.com/hatoo/oha
#
# Usage:
#   Terminal 1: julia --threads=auto --project=. benchmarks/ciro_bench.jl
#   Terminal 2: ./benchmarks/khttp/target/release/server
#   Terminal 3: ./benchmarks/run_bench.sh
#
# Keep-alive  (default HTTP/1.1): connections are reused across requests
# Connection-close               : each request opens and closes a TCP connection
# The difference shows the cost of TCP handshake + kernel accept overhead.

set -e

DURATION="10s"
CONNECTIONS=256

CIRO_PORT=8080
KHTTP_PORT=3000

echo "========================================================"
echo " Ciro.jl vs khttp (Rust) — Keep-Alive vs Close"
echo "========================================================"
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

# run_bench <label> <port> <method> <endpoint> [extra_oha_args...]
run_bench() {
    local name="$1"
    local port="$2"
    local method="$3"
    local endpoint="$4"
    shift 4  # remaining args forwarded to oha

    printf "  %-36s" "[$name] $method $endpoint"
    local rps
    if [ "$method" = "POST" ]; then
        rps=$(oha -z "$DURATION" -c "$CONNECTIONS" \
            --no-tui -m POST -d "" "$@" \
            "http://127.0.0.1:${port}${endpoint}" 2>&1 | \
            awk '/Requests\/sec/{printf "%-10s", $2}')
    else
        rps=$(oha -z "$DURATION" -c "$CONNECTIONS" \
            --no-tui "$@" \
            "http://127.0.0.1:${port}${endpoint}" 2>&1 | \
            awk '/Requests\/sec/{printf "%-10s", $2}')
    fi
    echo "$rps req/s"
}

# Verbose variant — prints full oha stats block
run_bench_verbose() {
    local name="$1"
    local port="$2"
    local method="$3"
    local endpoint="$4"
    shift 4

    echo "--- [$name] $method $endpoint ---"
    if [ "$method" = "POST" ]; then
        oha -z "$DURATION" -c "$CONNECTIONS" \
            --no-tui -m POST -d "" "$@" \
            "http://127.0.0.1:${port}${endpoint}" 2>&1 | \
            grep -E "Requests/sec|Fastest|Slowest|Average|50%|99%|Success"
    else
        oha -z "$DURATION" -c "$CONNECTIONS" \
            --no-tui "$@" \
            "http://127.0.0.1:${port}${endpoint}" 2>&1 | \
            grep -E "Requests/sec|Fastest|Slowest|Average|50%|99%|Success"
    fi
    echo ""
}

KA_HDR=()                               # keep-alive: HTTP/1.1 default
CL_HDR=(-H "Connection: close")        # force new TCP connection per request

# ── Summary table ─────────────────────────────────────────────────────────────

echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  Endpoint              Server       Mode          req/s     │"
echo "└─────────────────────────────────────────────────────────────┘"

for endpoint in "/" "/user/42"; do
    for method in "GET"; do
        echo ""
        echo "  $method $endpoint"
        run_bench "Ciro.jl  keep-alive" "$CIRO_PORT"  "$method" "$endpoint" "${KA_HDR[@]}"
        run_bench "Ciro.jl  close     " "$CIRO_PORT"  "$method" "$endpoint" "${CL_HDR[@]}"
        run_bench "khttp    keep-alive" "$KHTTP_PORT" "$method" "$endpoint" "${KA_HDR[@]}"
        run_bench "khttp    close     " "$KHTTP_PORT" "$method" "$endpoint" "${CL_HDR[@]}"
    done
done

echo ""
echo "  POST /user"
run_bench "Ciro.jl  keep-alive" "$CIRO_PORT"  "POST" "/user" "${KA_HDR[@]}"
run_bench "Ciro.jl  close     " "$CIRO_PORT"  "POST" "/user" "${CL_HDR[@]}"
run_bench "khttp    keep-alive" "$KHTTP_PORT" "POST" "/user" "${KA_HDR[@]}"
run_bench "khttp    close     " "$KHTTP_PORT" "POST" "/user" "${CL_HDR[@]}"

# ── Verbose detail for GET / ──────────────────────────────────────────────────

echo ""
echo "========================================================"
echo " Verbose stats — GET /"
echo "========================================================"
echo ""
run_bench_verbose "Ciro.jl  keep-alive" "$CIRO_PORT"  "GET" "/" "${KA_HDR[@]}"
run_bench_verbose "Ciro.jl  close     " "$CIRO_PORT"  "GET" "/" "${CL_HDR[@]}"
run_bench_verbose "khttp    keep-alive" "$KHTTP_PORT" "GET" "/" "${KA_HDR[@]}"
run_bench_verbose "khttp    close     " "$KHTTP_PORT" "GET" "/" "${CL_HDR[@]}"

echo "========================================================"
echo " Benchmark Complete"
echo "========================================================"

