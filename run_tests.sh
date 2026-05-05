#!/bin/bash
# Test upload resilience under network disruption
# Usage: ./run_tests.sh
# Requires sudo (for pfctl)

set -e

WORKDIR="/Users/karolkokoszka/dev/gcs-mem-test"
BINARY="$WORKDIR/googleapi"
FILE="$WORKDIR/big.txt"  # 300MB file
BUCKET="karol-test-1234"

run_test() {
    local MODE=$1       # "chunked" or "nochunk"
    local DISRUPTION=$2 # "drop" or "throttle"  
    local DURATION=$3   # seconds of disruption
    local DELAY=$4      # seconds to wait before disrupting

    local CHUNK_FLAG=""
    if [ "$MODE" = "nochunk" ]; then
        CHUNK_FLAG="-chunk-size 0"
    fi

    echo "============================================================"
    echo "Test: mode=$MODE, disruption=$DISRUPTION, duration=${DURATION}s, delay=${DELAY}s"
    echo "============================================================"

    # Ensure pf is clean
    sudo pfctl -d 2>/dev/null || true

    # Start upload in background
    $BINARY -f "$FILE" -n 1 -b "$BUCKET" $CHUNK_FLAG 2>&1 &
    UPLOAD_PID=$!

    # Wait for upload to start transferring
    sleep $DELAY

    echo "[$(date +%H:%M:%S)] Applying disruption: $DISRUPTION for ${DURATION}s..."

    if [ "$DISRUPTION" = "drop" ]; then
        # TCP outage - drop all packets to GCS
        echo "block drop out proto tcp from any to storage.googleapis.com port 443" | sudo pfctl -ef - 2>/dev/null
    elif [ "$DISRUPTION" = "throttle" ]; then
        # Zero bandwidth via dummynet
        sudo dnctl pipe 1 config bw 1 # 1 bit/s (effectively 0)
        echo "dummynet out proto tcp from any to storage.googleapis.com port 443 pipe 1" | sudo pfctl -ef - 2>/dev/null
    fi

    sleep $DURATION

    echo "[$(date +%H:%M:%S)] Restoring network..."
    sudo pfctl -d 2>/dev/null || true
    sudo dnctl -q flush 2>/dev/null || true

    # Wait for upload to finish (timeout 5 min)
    local TIMEOUT=300
    local WAITED=0
    while kill -0 $UPLOAD_PID 2>/dev/null; do
        sleep 1
        WAITED=$((WAITED + 1))
        if [ $WAITED -ge $TIMEOUT ]; then
            echo "[$(date +%H:%M:%S)] TIMEOUT after ${TIMEOUT}s"
            kill $UPLOAD_PID 2>/dev/null
            wait $UPLOAD_PID 2>/dev/null
            echo "RESULT: TIMEOUT"
            echo ""
            return
        fi
    done

    wait $UPLOAD_PID 2>/dev/null
    local EXIT_CODE=$?
    if [ $EXIT_CODE -eq 0 ]; then
        echo "[$(date +%H:%M:%S)] RESULT: SUCCESS (recovered)"
    else
        echo "[$(date +%H:%M:%S)] RESULT: FAILED (exit code $EXIT_CODE)"
    fi
    echo ""
}

# Clean up on exit
cleanup() {
    sudo pfctl -d 2>/dev/null || true
    sudo dnctl -q flush 2>/dev/null || true
}
trap cleanup EXIT

echo "Starting network disruption tests..."
echo "File: 300MB, Bucket: $BUCKET"
echo ""

# Test 1: TCP outage 20s - chunked
run_test "chunked" "drop" 20 3

# Test 2: TCP outage 20s - no chunk
run_test "nochunk" "drop" 20 3

# Test 3: TCP outage 60s - chunked
run_test "chunked" "drop" 60 3

# Test 4: TCP outage 60s - no chunk
run_test "nochunk" "drop" 60 3

# Test 5: Zero BW 60s - chunked
run_test "chunked" "throttle" 60 3

# Test 6: Zero BW 60s - no chunk
run_test "nochunk" "throttle" 60 3

echo "All tests complete."
