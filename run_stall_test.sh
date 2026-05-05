#!/bin/bash
# Test upload resilience under TCP stall (high latency, not drop/RST)
# Uses dummynet pipe with massive delay to simulate TCP stall
# When pipe is removed, queued packets are lost (similar to drop),
# but the key question is what happens DURING the stall period.

set +e

WORKDIR="/Users/karolkokoszka/dev/gcs-mem-test"
BINARY="$WORKDIR/googleapi"
FILE="$WORKDIR/big.txt"  # 300MB file
BUCKET="karol-test-1234"

cleanup() {
    sudo pfctl -F all 2>/dev/null || true
    sudo dnctl -q flush 2>/dev/null || true
    sudo pfctl -d 2>/dev/null || true
}
trap cleanup EXIT

run_stall_test() {
    local MODE=$1       # "chunked" or "nochunk"
    local DURATION=$2   # seconds of stall
    local DELAY=$3      # seconds to wait before stalling

    local CHUNK_FLAG=""
    if [ "$MODE" = "nochunk" ]; then
        CHUNK_FLAG="-chunk-size 0"
    fi

    echo "============================================================"
    echo "STALL Test: mode=$MODE, stall=${DURATION}s, delay=${DELAY}s"
    echo "============================================================"

    # Ensure everything is clean
    cleanup

    # Start upload in background
    $BINARY -f "$FILE" -n 1 -b "$BUCKET" $CHUNK_FLAG 2>&1 &
    UPLOAD_PID=$!

    sleep $DELAY

    echo "[$(date +%H:%M:%S)] Applying TCP stall via dummynet (delay=${DURATION}s, large queue)..."
    # Create a pipe with massive delay and large queue
    # This queues packets rather than dropping them — simulating a stall
    # queue size in slots (each slot ~1500 bytes MTU), 65535 is max
    sudo dnctl pipe 1 config delay $((DURATION * 1000)) queue 65535
    echo "dummynet out proto tcp from any to storage.googleapis.com port 443 pipe 1
dummynet in proto tcp from storage.googleapis.com port 443 to any pipe 1" | sudo pfctl -ef - 2>/dev/null

    echo "[$(date +%H:%M:%S)] TCP stall active — packets are being queued with ${DURATION}s delay"
    sleep $DURATION

    echo "[$(date +%H:%M:%S)] Removing stall (restoring network)..."
    cleanup

    # Wait for upload to finish (timeout 5 min)
    local TIMEOUT=300
    local WAITED=0
    while kill -0 $UPLOAD_PID 2>/dev/null; do
        sleep 1
        WAITED=$((WAITED + 1))
        if [ $WAITED -ge $TIMEOUT ]; then
            echo "[$(date +%H:%M:%S)] TIMEOUT after ${TIMEOUT}s"
            kill $UPLOAD_PID 2>/dev/null
            wait $UPLOAD_PID 2>/dev/null || true
            echo "RESULT: TIMEOUT"
            echo ""
            return
        fi
    done

    wait $UPLOAD_PID 2>/dev/null || true
    local EXIT_CODE=$?
    if [ $EXIT_CODE -eq 0 ]; then
        echo "[$(date +%H:%M:%S)] RESULT: SUCCESS (survived stall)"
    else
        echo "[$(date +%H:%M:%S)] RESULT: FAILED (exit code $EXIT_CODE)"
    fi
    echo ""
}

echo "Starting TCP stall tests..."
echo "File: 300MB, Bucket: $BUCKET"
echo "Simulating TCP stall using dummynet delay (packets queued, not dropped)"
echo ""

# Test 1: 20s stall - chunked (within HTTP/2 ReadIdleTimeout of 31s)
run_stall_test "chunked" 20 5

# Test 2: 20s stall - no chunk
run_stall_test "nochunk" 20 5

# Test 3: 60s stall - chunked (exceeds HTTP/2 ReadIdleTimeout of 31s)
run_stall_test "chunked" 60 5

# Test 4: 60s stall - no chunk
run_stall_test "nochunk" 60 5

echo "All stall tests complete."
