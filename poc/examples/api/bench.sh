#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# Benchmark: Ciro.jl vs Mongoose.jl
# Uses oha (https://github.com/hatoo/oha) for HTTP load testing
# ══════════════════════════════════════════════════════════════════════════════

set -e

DURATION="10s"
CIRO_PORT=8080
MONGOOSE_PORT=8099

# Routes to benchmark
ROUTES=(
    "/plaintext"
    "/json"
    "/users/42"
)

CONCURRENCIES=(64 128 512)

echo "═══════════════════════════════════════════════════════════════"
echo "  HTTP Benchmark: Ciro.jl vs Mongoose.jl"
echo "  Duration: $DURATION per test"
echo "  Concurrencies: ${CONCURRENCIES[*]}"
echo "═══════════════════════════════════════════════════════════════"
echo ""

run_bench() {
    local name=$1
    local port=$2
    local route=$3
    local conc=$4
    local disable_ka=$5

    local ka_flag=""
    local ka_label="keep-alive"
    if [ "$disable_ka" = "true" ]; then
        ka_flag="--disable-keepalive"
        ka_label="no-keepalive"
    fi

    echo "  [$name] $route | c=$conc | $ka_label"
    oha -z "$DURATION" -c "$conc" --no-tui $ka_flag "http://127.0.0.1:$port$route" 2>/dev/null | grep -E "Requests/sec|Slowest|Fastest|Average|50%|99%" | head -6
    echo ""
}

# ── Benchmark Ciro ──────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  CIRO.JL (io_uring backend)                                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"

for route in "${ROUTES[@]}"; do
    for conc in "${CONCURRENCIES[@]}"; do
        run_bench "Ciro" "$CIRO_PORT" "$route" "$conc" "false"
        run_bench "Ciro" "$CIRO_PORT" "$route" "$conc" "true"
    done
done

# ── Benchmark Mongoose ──────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  MONGOOSE.JL                                                ║"
echo "╚══════════════════════════════════════════════════════════════╝"

for route in "${ROUTES[@]}"; do
    for conc in "${CONCURRENCIES[@]}"; do
        run_bench "Mongoose" "$MONGOOSE_PORT" "$route" "$conc" "false"
        run_bench "Mongoose" "$MONGOOSE_PORT" "$route" "$conc" "true"
    done
done

echo "═══════════════════════════════════════════════════════════════"
echo "  Benchmark complete!"
echo "═══════════════════════════════════════════════════════════════"
