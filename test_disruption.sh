#!/bin/bash
# Script to test upload resilience under network disruption
# Usage: ./test_disruption.sh <mode> <disruption_type> <duration_seconds>
# mode: "chunked" or "nochunk"
# disruption_type: "drop" (TCP outage) or "throttle" (0 bw)
# duration_seconds: how long to disrupt

MODE=$1
DURATION=$2
DISRUPTION=${3:-drop}

CHUNK_FLAG=""
if [ "$MODE" = "nochunk" ]; then
    CHUNK_FLAG="-chunk-size 0"
fi

echo "=== Test: mode=$MODE, disruption=$DISRUPTION, duration=${DURATION}s ==="

# Create pf rules to block GCS traffic
cat > /tmp/pf_block_gcs.conf << 'EOF'
# Block all traffic to storage.googleapis.com
block drop out proto tcp from any to storage.googleapis.com port 443
EOF

# Start upload in background (single large file to give time for disruption)
cd /Users/karolkokoszka/dev/gcs-mem-test
./googleapi -f ./1.txt -n 1 -b karol-test-1234 $CHUNK_FLAG 2>&1 &
UPLOAD_PID=$!

# Wait for upload to start transferring (2 seconds should be enough for auth + start)
sleep 2

echo "[$(date +%H:%M:%S)] Disrupting network for ${DURATION}s (type: $DISRUPTION)..."

if [ "$DISRUPTION" = "drop" ]; then
    # TCP outage - drop all packets to GCS
    sudo pfctl -e 2>/dev/null
    sudo pfctl -f /tmp/pf_block_gcs.conf 2>/dev/null
    sleep $DURATION
    echo "[$(date +%H:%M:%S)] Restoring network..."
    sudo pfctl -d 2>/dev/null
elif [ "$DISRUPTION" = "throttle" ]; then
    # Zero bandwidth - use dummynet
    sudo dnctl pipe 1 config bw 0
    sudo pfctl -e 2>/dev/null
    echo "dummynet out proto tcp from any to storage.googleapis.com port 443 pipe 1" > /tmp/pf_throttle_gcs.conf
    sudo pfctl -f /tmp/pf_throttle_gcs.conf 2>/dev/null
    sleep $DURATION
    echo "[$(date +%H:%M:%S)] Restoring network..."
    sudo pfctl -d 2>/dev/null
    sudo dnctl pipe 1 config bw 0 # cleanup
fi

# Wait for upload to finish (with timeout of 5 minutes)
TIMEOUT=300
WAITED=0
while kill -0 $UPLOAD_PID 2>/dev/null; do
    sleep 1
    WAITED=$((WAITED + 1))
    if [ $WAITED -ge $TIMEOUT ]; then
        echo "[$(date +%H:%M:%S)] TIMEOUT - upload did not finish in ${TIMEOUT}s"
        kill $UPLOAD_PID 2>/dev/null
        break
    fi
done

wait $UPLOAD_PID 2>/dev/null
EXIT_CODE=$?
echo "[$(date +%H:%M:%S)] Upload exit code: $EXIT_CODE"
echo "=== Done ==="
echo ""
