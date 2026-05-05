# Scylla Manager: google-api-go-client Fork Assessment

**Author:** Karol Kokoszka  
**Date:** May 4, 2026  
**Status:** Investigation complete

## Executive Summary

The `scylladb/google-api-go-client` fork (branch `v0.34.0-patched`, tag `v0.34.1-patched`) can be eliminated by setting `ChunkSize=0` in the GCS backend configuration. This setting disables chunked/resumable uploads in favor of single-request multipart uploads, which:

1. Uses **53x fewer memory allocations** than default chunked mode (without the fork)
2. Uses **3.4x fewer allocations** than even the fork's optimized `WithBuffer` path
3. Removes maintenance burden of a 5+ year old fork (based on upstream v0.34.0)
4. Is aligned with **Google's** recommendation to avoid chunking when possible ([source](https://cloud.google.com/storage/docs/resumable-uploads#uploading-in-chunks))

**However**, there is a tradeoff: chunked uploads (ChunkSize=16MB) can survive short network outages (5-10s) when connections are cleanly refused (TCP RST), while ChunkSize=0 fails immediately on any connection disruption with no retry capability. See the [Network Resilience](#network-resilience-300mb-file-upload) section for details.

## Background

### Current Dependency Chain

```
scylla-manager (master)
  └── github.com/scylladb/rclone v1.54.1-0.20251215153917-de3d40fca4e9
        (branch: v1.54.0-patched-custom-gs-endpoint-4598)
        (30 custom commits on top of upstream v1.54.0, now 4539 behind upstream v1.73.5)
  └── google.golang.org/api v0.114.0 => github.com/scylladb/google-api-go-client v0.34.1-patched
        (branch: v0.34.0-patched)
        (3 commits over upstream v0.34.0: buffer patch + grpc bump + merge)
```

### What the Fork Does

The fork adds a single feature: `googleapi.WithBuffer([]byte)` — a `MediaOption` that allows callers to pass a pre-allocated byte slice for chunked uploads, enabling buffer reuse across multiple upload calls. Without this, every chunked upload allocates a fresh `[]byte` of `ChunkSize` (default 16MB).

The SM rclone fork's GCS backend uses this with a memory pool (`googlecloudstorage.go:1180-1188`):
```go
buf := o.fs.pool.Get()
defer o.fs.pool.Put(buf)

mediaOpts := []googleapi.MediaOption{
    googleapi.ContentType(""),
    googleapi.ChunkSize(int(o.fs.opt.ChunkSize)),
    googleapi.WithBuffer(buf),
}
insertObject := o.fs.svc.Objects.Insert(bucket, &object).Media(in, mediaOpts...).Name(object.Name)
```

The pool allocates buffers of `ChunkSize` bytes and reuses them across uploads, avoiding repeated 16MB allocations.

### Scylla Manager Agent Memory Constraints

The SM Agent runs on the Scylla VM inside a `scylla-helper.slice` cgroup with strict memory limits (`dist/scripts/scyllamgr_agent_setup`):

- **MemoryHigh** (throttle point): **4% of total RAM** (minimum 1200MB for small VMs)
- **MemoryMax** (OOM kill): **5% of total RAM** (minimum 1400MB for small VMs)

On a 64GB node: ~2.5GB high / ~3.2GB max. On a 16GB node: only 1.2GB / 1.4GB.

Since backup tasks may want to upload hundreds of files, minimizing per-upload memory overhead matters — even if individual buffers are freed after each upload.

### How Chunked Uploads Work in Rclone

Rclone's GCS backend uses `CallNoRetry` — the resumable upload URI is never persisted or reused across rclone-level retries. The retry mechanism is internal to the Google API library's `ResumableUpload.Upload()`, which has a hard-coded 32-second `retryDeadline`:

- **ChunkSize > 0**: Upload is split into chunks sent via the resumable upload protocol. Each chunk has a ~32s retry window. Within that window, if a chunk transfer fails with a clean error (e.g. TCP RST / connection refused), the library queries the server for the persisted offset and retries the chunk on a new connection. If the retry deadline expires, the entire upload fails.
- **ChunkSize = 0**: Upload is sent as a single multipart request. If the connection breaks, the upload fails immediately with **no retry capability** at the library level.

In both cases, if the library-level upload fails, rclone's higher-level retry logic (configured via `--retries`) restarts the upload from scratch (byte 0). Rclone does not implement true cross-retry resumable uploads.

This is confirmed by:
- rclone GitHub issue #4794 (GCS resumable upload support — open since 2020)
- rclone GitHub issue #87 (resumable uploads — open since 2015)
- Code inspection: `CallNoRetry` usage in the GCS backend

### External Recommendations

#### Google Cloud Documentation

Google's official [resumable uploads documentation](https://cloud.google.com/storage/docs/resumable-uploads#uploading-in-chunks) recommends avoiding chunking when possible:

> *"If possible, avoid breaking a transfer into smaller chunks and instead upload the entire content in a single chunk. Avoiding chunking removes added latency costs and operations charges from querying the persisted offset of each chunk as well as improves throughput."*

Google recommends chunking only when:
- Source data is generated dynamically and you want to limit client-side buffering on failure
- Clients have request size limitations (e.g. browsers)

Neither applies to Scylla Manager Agent, which uploads known-size files from disk.

#### Rclone Precedent: Google Drive Backend

Rclone's own **Google Drive** backend already uses `ChunkSize(0)` for small files (below the upload cutoff), proving this is an established, tested pattern within rclone itself:

```go
// backend/drive/drive.go:2252-2253
info, err = f.svc.Files.Create(createInfo).
    Media(in, googleapi.ContentType(srcMimeType), googleapi.ChunkSize(0)).
    ...
```

Source: [`backend/drive/drive.go:2253`](https://github.com/rclone/rclone/blob/master/backend/drive/drive.go#L2253) and [`backend/drive/drive.go:3816`](https://github.com/rclone/rclone/blob/master/backend/drive/drive.go#L3816)

#### Upstream Rclone GCS Backend

Notably, **upstream rclone does NOT expose a `chunk_size` option for the GCS backend** at all. The SM rclone fork added `chunk_size`, `memory_pool_flush_time`, and `memory_pool_use_mmap` as custom patches. Upstream uses the library default (16MB) with no way to change it — and no memory pool.

The S3 backend, which does expose `--s3-chunk-size`, documents the memory impact:

> *"Multipart uploads will use extra memory equal to: `--transfers` × `--s3-upload-concurrency` × `--s3-chunk-size`. Single part uploads do not use extra memory."*

Source: [rclone S3 docs](https://rclone.org/s3/#multipart-uploads-1)

## Test Methodology

### Environment
- macOS (darwin), Go 1.25.5
- GCS bucket: `karol-test-1234` (project: `scylladbaaslab`)
- google.golang.org/api v0.214.0 (upstream, for ChunkSize=0 and chunked-without-fork tests)
- scylladb/google-api-go-client v0.34.1-patched (local clone, for WithBuffer tests)

### Memory Tests
- 20 consecutive uploads of 30MB file (`1.txt`)
- `runtime.GC()` forced between each upload to measure true retained memory
- Per-iteration `MemStats` reported (heap_alloc, total_alloc, heap_inuse, heap_objects)
- Based on Vasil Averyanov's methodology: https://gist.github.com/VAveryanov8/d47c7ade318a5401d4743c90d0270ebc

### Network Disruption Tests
- Single upload of 300MB file (`big.txt`)
- Disruption applied 3-5 seconds after upload start
- Two disruption types tested:
  - **`block drop`** (silent packet loss): `pfctl` drops all packets to `storage.googleapis.com:443`. TCP connections hang — no RST, no ICMP unreachable. Simulates a network black hole (e.g. router failure, firewall misconfiguration).
  - **`block return`** (clean connection refused): `pfctl` sends TCP RST back for every packet. Existing connections are killed immediately with a clean error. Simulates a service outage where the endpoint is unreachable but the network is functional.
- Network restored after disruption duration expires; `pfctl` fully flushed to ensure clean recovery
- Upload process monitored for success/failure (5-minute timeout)

## Results

### Memory Usage (20 × 30MB consecutive uploads)

#### Summary

| Configuration | sys (MB) | total_alloc (MB) | heap_inuse (MB) |
|---------------|----------|------------------|-----------------|
| Upstream, ChunkSize=16MB (no fork) | 30.96 | 327.25 | 3.91 |
| Fork + WithBuffer, ChunkSize=16MB | 25.89 | 20.65 | 18.26 |
| **Upstream, ChunkSize=0** | **15.46** | **6.10** | **3.95** |

#### Per-iteration detail: Upstream, ChunkSize=16MB (no fork)

Each upload allocates a fresh 16MB buffer, uses it, then GC reclaims it. `heap_alloc` stays flat (~2.3MB after GC) but `total_alloc` grows by ~16.2MB per upload.

```
initial:           sys=12.52MB total_alloc=2.69MB  heap_alloc=2.69MB  heap_objects=10844
after upload 1/20: sys=29.96MB total_alloc=19.49MB heap_alloc=2.30MB  heap_objects=7115
after upload 10/20:sys=30.96MB total_alloc=165.30MB heap_alloc=2.32MB heap_objects=7190
after upload 20/20:sys=30.96MB total_alloc=327.25MB heap_alloc=2.34MB heap_objects=7211
final (after GC):  sys=30.96MB total_alloc=327.26MB heap_alloc=2.19MB heap_objects=7018
```

No memory leak — buffers are freed each iteration. But 327MB of cumulative allocation churn for 20 uploads of 30MB files.

#### Per-iteration detail: Fork + WithBuffer, ChunkSize=16MB

The 16MB buffer is allocated once and reused via the pool. `heap_alloc` stays at ~17MB (the retained buffer).

```
initial:           sys=24.33MB total_alloc=17.33MB heap_alloc=17.00MB heap_objects=4487
after upload 1/20: sys=25.14MB total_alloc=18.06MB heap_alloc=16.97MB heap_objects=3082
after upload 10/20:sys=25.89MB total_alloc=19.21MB heap_alloc=17.02MB heap_objects=3167
after upload 20/20:sys=25.89MB total_alloc=20.65MB heap_alloc=17.04MB heap_objects=3181
final (after GC):  sys=25.89MB total_alloc=20.65MB heap_alloc=0.88MB  heap_objects=3088
```

No leak, no churn. Buffer is held for the pool lifetime, released on final GC.

#### Per-iteration detail: Upstream, ChunkSize=0

No chunk buffer needed at all. Minimal allocations — only HTTP/TLS overhead.

```
initial:           sys=12.27MB total_alloc=2.69MB heap_alloc=2.69MB  heap_objects=10842
after upload 1/20: sys=14.71MB total_alloc=3.52MB heap_alloc=2.26MB  heap_objects=7074
after upload 10/20:sys=15.21MB total_alloc=4.68MB heap_alloc=2.33MB  heap_objects=7157
after upload 20/20:sys=15.46MB total_alloc=6.10MB heap_alloc=2.33MB  heap_objects=7204
final (after GC):  sys=15.46MB total_alloc=6.10MB heap_alloc=2.18MB  heap_objects=7013
```

6.10MB total for 20 uploads — **53x less** than chunked without fork, **3.4x less** than chunked with fork.

### Network Resilience (300MB file upload)

#### Test 1: Silent packet loss (`block drop`)

Simulates a network black hole — packets are silently dropped, TCP connections hang.

| Outage Duration | Chunked (16MB) | ChunkSize=0 |
|-----------------|----------------|-------------|
| 20s | **FAILED** (died ~49s after disruption) | **FAILED** (died ~23s after disruption) |
| 60s | **FAILED** (died ~49s after disruption) | **FAILED** (died ~23s after disruption) |

With `block drop`, TCP retransmit timers escalate exponentially. Even though the 20s outage is within the library's 32s retry deadline, the TCP stack itself cannot recover — it doesn't know the connection is dead (no RST received), so the socket hangs until the OS-level TCP timeout fires.

**Both modes fail identically** under silent packet loss. Chunked uploads provide no advantage.

Error messages:
- Chunked: `chunk upload failed after 3 attempts; dial tcp: i/o timeout`
- No-chunk: `read tcp: operation timed out`

#### Test 2: Clean connection refused (`block return`)

Simulates a service outage — TCP RST sent back immediately, connections fail fast with clean errors.

| Outage Duration | Chunked (16MB) | ChunkSize=0 |
|-----------------|----------------|-------------|
| 5s | **SUCCESS** (recovered, completed ~38s after restore) | **FAILED** (instant, no retry) |
| 10s | **SUCCESS** (recovered, completed ~48s after restore) | **FAILED** (instant, no retry) |
| 20s | **FAILED** (retry deadline exceeded after 11 attempts) | **FAILED** (instant, no retry) |

This is where chunked uploads show a real advantage:

- **Chunked (16MB)**: When the connection gets RST'd, the library opens a new connection, queries GCS for the persisted byte offset, and resumes uploading from where it left off. This works within the 32-second retry deadline, allowing recovery from outages up to ~15 seconds.
- **ChunkSize=0**: The entire file is one HTTP request. A connection reset kills the upload instantly. The library has no retry mechanism for non-chunked uploads — `connection reset by peer` is a terminal error.

**Key insight**: The chunked upload retry only works with **clean failures** (TCP RST, connection refused) where the library can immediately detect the error and open a new connection. It does NOT work with **silent failures** (packet drop, black hole) where the TCP socket hangs.

#### Test 3: Zero bandwidth (`block drop` variant)

Simulates extreme throttling — effectively zero throughput via `dummynet` pipe at 1 bit/s.

| Outage Duration | Chunked (16MB) | ChunkSize=0 |
|-----------------|----------------|-------------|
| 60s | **FAILED** (died ~48s after disruption) | **FAILED** (died ~18s after disruption) |

Same behavior as `block drop` — the TCP connection hangs, both modes fail.

#### Test 4: TCP stall via dummynet delay (packets queued, not dropped)

Simulates a network "freeze" — packets are held in a queue with massive delay, not dropped or RST'd. When the pipe is removed, the TCP stack must recover. This tests the scenario where "TCP just hangs for a while, then comes back."

Note: macOS dummynet caps pipe queue at 100 slots (~150KB). Once the queue fills, excess packets are dropped, making long stalls behave similarly to `block drop`. This reflects reality — sustained network stalls typically involve some packet loss.

| Stall Duration | Chunked (16MB) | ChunkSize=0 |
|---------------|----------------|-------------|
| 5s | **SUCCESS** | **SUCCESS** |
| 10s | **SUCCESS** | **SUCCESS** |
| 15s | **SUCCESS** | **SUCCESS** |
| 18s | **SUCCESS** | **SUCCESS** |
| 20s | **SUCCESS** (recovered after stall, completed ~44s later) | **FAILED** (`read: operation timed out` ~19s into stall) |
| 60s | **FAILED** (`chunk upload failed after 3 attempts; dial tcp: i/o timeout` ~48s in) | **FAILED** (`read: operation timed out` ~19s into stall) |

**Analysis**: Both modes survive TCP stalls up to ~18 seconds. The failure threshold for ChunkSize=0 is ~19 seconds — this is the macOS TCP retransmit timeout (after which the OS gives up on the connection). Chunked mode survives longer (up to ~48s) because after the connection dies, the library retries the failed chunk on a new connection.

#### Key timeout: TCP retransmit timeout = ~19 seconds (macOS)

The actual failure threshold for ChunkSize=0 is **not** the HTTP/2 `ReadIdleTimeout` (31s) but the **OS-level TCP retransmit timeout**, which fires at ~19 seconds on macOS when no ACKs are received. Both modes survive stalls up to this threshold. The difference between the modes is only ~29 seconds of extra resilience (19s→48s) — chunked mode survives longer because after the TCP connection dies, the library retries the failed chunk on a new connection within the 32s retry deadline.

The `google.golang.org/api` library configures the Go HTTP/2 transport with `ReadIdleTimeout: 31s` (`transport/http/dial.go:279`). This means if no HTTP/2 frames are received for 31 seconds, the transport sends a PING probe. However, the TCP retransmit timeout fires first (~19s), killing the connection before the PING mechanism has a chance to act.

### How Common Are TCP Failures Between GCE and GCS?

**Very rare.** The key data points:

1. **GCS SLA guarantees** 99.9% monthly uptime for regional Standard storage (99.95% for multi-region). This means at most ~43 minutes/month of errors for regional, ~22 min for multi-region.

2. **Typical GCS failure mode is HTTP 503/429** (overloaded, rate-limited), not TCP RST. The Go client library's retry list includes `connection refused`, `connection reset by peer`, and `net.ErrClosed` — confirming these do occur, but are treated as rare transient events.

3. **GCE-to-GCS same-region traffic stays on Google's internal network** — no public internet hops. TCP RST would only occur during GCS load balancer changes, rolling deployments, or internal capacity issues. These are brief (sub-second to a few seconds).

4. **GCS's retry documentation** lists retryable responses as "HTTP 408, 429, 5xx, socket timeouts and TCP disconnects" — noting that application-level retries (which rclone already implements via `--retries`) are the expected recovery mechanism.

**Bottom line**: TCP connection kills between GCE and GCS are rare and brief. When they happen, rclone's higher-level retry (re-upload from scratch, `--retries` default 3) covers both chunked and ChunkSize=0 modes.

### TCP Failure Modes Explained

| Failure Mode | What Happens | Connection Killed? | Both Modes Survive? |
|-------------|-------------|-------------------|-------------------|
| **TCP RST / conn refused** | Server sends RST packet | **Yes, immediately** | **No** — chunked retries within 32s, ChunkSize=0 fails instantly |
| **Packet drop (black hole)** | Packets silently lost | **Yes, after TCP timeout (~20-50s)** | **No** — both fail once TCP retransmit timer escalates |
| **Packet corruption / reorder** | TCP checksums detect it, retransmits | **No** — TCP handles transparently | **Yes** — both survive |
| **Slow connection (congestion)** | TCP flow control, reduced throughput | **No** — just slow | **Yes** — both survive, upload just takes longer |
| **GCE live migration pause** | VM frozen ~200ms-10s, TCP state preserved | **No** — VM state restored | **Yes** — TCP resumes from where it was |
| **True stall < 19s (no loss)** | No packets flow, then resume | **No** | **Yes** — within TCP retransmit timeout |
| **True stall 19-48s** | No packets flow for extended period | **Yes** — TCP retransmit timeout | Chunked: retries on new conn. ChunkSize=0: **fails** |
| **True stall > 48s** | No packets flow for extended period | **Yes** — exceeds retry deadline | **No** — both fail |

### Summary of Network Resilience

| Failure Type | Chunked (16MB) | ChunkSize=0 |
|-------------|----------------|-------------|
| **Clean failure (TCP RST), short (<15s)** | **Survives** — retries from persisted offset | **Fails instantly** — no retry |
| **Clean failure (TCP RST), long (>20s)** | Fails — retry deadline exceeded | Fails instantly — no retry |
| **Silent failure (packet drop/black hole)** | Fails — TCP hangs | Fails — TCP hangs |
| **TCP stall (dummynet), ≤18s** | **Survives** | **Survives** |
| **TCP stall (dummynet), 20s** | **Survives** — retries after recovery | Fails — TCP retransmit timeout (~19s) |
| **TCP stall (dummynet), 60s** | Fails — retry deadline exceeded | Fails — TCP retransmit timeout (~19s) |
| **Zero bandwidth** | Fails — TCP hangs | Fails — TCP hangs |
| **Packet corruption / reorder** | Survives — TCP handles it | Survives — TCP handles it |
| **Slow connection (congestion)** | Survives — just slow | Survives — just slow |
| **GCE live migration (<10s)** | Survives — TCP state preserved | Survives — TCP state preserved |

## Conclusion

### Tradeoff Analysis

| Factor | ChunkSize=16MB + Fork | ChunkSize=0 (no fork) |
|--------|----------------------|----------------------|
| **Memory (total_alloc, 20 uploads)** | 20.65 MB | 6.10 MB |
| **Memory (heap_alloc live)** | ~17 MB (retained buffer) | ~2.3 MB |
| **Allocation churn** | None (pool reuse) | None (no buffer needed) |
| **Short clean outage (<15s)** | Survives at library level | Fails at library level (rclone retries from scratch) |
| **TCP stall ≤18s** | Survives (both) | Survives (both) |
| **TCP stall 19-48s** | Survives (retries on new conn) | Fails (rclone retries from scratch) |
| **TCP stall / congestion / live migration** | Survives (both) | Survives (both) |
| **Long or silent outage** | Fails | Fails |
| **GCE→GCS TCP RST frequency** | Rare (sub-second, covered by rclone --retries) | Rare (covered by rclone --retries) |
| **Upload latency per file** | Higher (chunk round-trips) | Lower (single request) |
| **Dependency complexity** | Requires fork of google-api-go-client | No fork needed |
| **Maintenance burden** | Fork locked at v0.34.0 (2020) | Uses upstream, freely upgradable |
| **Google recommendation** | Not recommended for known-size files | Recommended |

### Assessment: ChunkSize=0 Is the Right Choice for SM Agent

**ChunkSize=0 is recommended for Scylla Manager Agent uploading SSTables to GCS.** The chunked upload's resilience benefit does not justify the cost in this specific use case.

#### SM Agent already retries at a higher level — chunked retry is redundant

The SM backup upload path (`worker_upload.go:207-221`) retries the entire directory upload up to 10 times on `errJobNotFound`. More importantly, `RcloneMoveDir` with `CheckSum=true` **skips already-uploaded files** on retry. So if an SSTable upload fails mid-way (regardless of chunked or not), SM restarts the rclone job and rclone skips the files that completed successfully, re-uploading only the failed ones from byte 0.

The chunked upload's ability to resume a partially-uploaded single file from a mid-point saves re-uploading at most one chunk (~16MB) of data. For a 160-500MB SSTable, that is a marginal saving — a few hundred milliseconds at SM's default 100 MiB/s rate limit.

Additionally, rclone's own low-level retry is set to 20 attempts (`options.go:76-78`), and the pacer has 3 high-level retries. These retries re-upload the full file from scratch, covering both modes equally.

#### The failure window where chunking helps is extremely narrow

Chunked uploads only provide a resilience advantage when ALL of these conditions are met simultaneously:

1. TCP gets no response for **19-48 seconds** (shorter stalls are survived by both modes; longer ones fail for both)
2. OR TCP gets RST'd (clean kill) for **< ~15 seconds**
3. The rclone low-level retry has not already been exhausted

The actual difference between the two modes is only **~29 seconds of extra resilience** (ChunkSize=0 dies at ~19s, chunked survives up to ~48s). On Google's internal network (GCE → GCS same region), a 19+ second network blackout is an extraordinary event. GCS SLA guarantees 99.9%+ monthly uptime, and the typical failure mode is HTTP 503/429 (rate limiting), not network-level disruptions.

Furthermore, the most common real-world network issues — congestion, slow links, GCE live migration — do NOT kill TCP connections and both modes survive them transparently.

#### Memory savings matter in SM Agent's constrained cgroup

SM Agent runs in a `scylla-helper.slice` cgroup with tight memory limits:

- **MemoryHigh** (throttle): 4% of RAM (1.2GB on 16GB node)
- **MemoryMax** (OOM kill): 5% of RAM (1.4GB on 16GB node)

With the default `Transfers = 2` (`options.go:59`), chunked uploads keep `2 × 16MB = 32MB` in pool buffers. ChunkSize=0 uses zero buffer overhead. While 32MB is not huge, it is meaningful in a 1.2GB budget shared with repair, healthcheck, and other agent tasks.

#### SSTables are the exact use case Google recommends against chunking

Google's resumable uploads documentation explicitly recommends avoiding chunking when:

- The file size is known in advance (SSTables are files on disk)
- The client is not a browser with request size limitations

And recommends chunking only when:

- Source data is generated dynamically (not the case for SSTables)
- You want to limit client-side buffering on failure (SM already handles this at the job level)

#### Chunking adds per-file latency overhead

Each chunk requires querying the server for the persisted offset before sending the next chunk. For a 160MB SSTable at 16MB chunk size: 10 chunks = 10 extra round-trips. For a 500MB SSTable: 31 chunks = 31 round-trips. With ChunkSize=0, it is a single HTTP request.

SM backup tasks upload hundreds of SSTables (one per table snapshot). At `Transfers = 2` and `rate_limit = 100 MiB/s`, the cumulative round-trip overhead from chunking adds measurable latency to the total backup duration.

#### What you lose with ChunkSize=0

The concrete loss depends on SSTable file sizes, which vary by compaction strategy:

**Scylla compaction strategies and pessimistic SSTable sizes:**

| Strategy | Pessimistic Max SSTable (per shard) | Typical Upload Time (at 100 MiB/s) |
|----------|-------------------------------------|-------------------------------------|
| **STCS** | Unbounded (total shard data — could be **tens/hundreds of GB**) | Minutes to tens of minutes |
| **LCS** | ~160 MB (or size of largest partition) | ~1.6 seconds |
| **TWCS** | All data in one time window / shards (could be **multiple GB**) | Seconds to minutes |
| **ICS** (Enterprise) | ~1 GB per file | ~10 seconds |

**Realistic STCS SSTable distribution (1 TB node, 8 shards = 125 GB/shard):**

STCS creates a tiered distribution: many small SSTables + few very large ones. With default `min_threshold=4` and ~256 MB flush size:

| Tier | SSTable Size | Count | Upload Time (at 100 MiB/s per node) |
|------|-------------|-------|-------------------------------------|
| 4 | ~64 GB | 1 | **10.9 min** |
| 3 | ~16 GB | 3 | **2.7 min** each |
| 2 | ~4 GB | 2 | **41 s** each |
| 1 | ~1 GB | 3 | **10 s** each |
| 0 | ~256 MB | 3 | **2.6 s** each |
| **Total** | | **~12 SSTables** | **~22 min total** |

The largest SSTable (~64 GB) dominates backup time. During its ~11-minute upload, any TCP stall >19s kills the upload with ChunkSize=0 and requires re-uploading all 64 GB from scratch (~11 min wasted).

**Upload times per strategy (per node, at 100 MiB/s):**

| Strategy | Largest SSTable (realistic) | Upload Time (largest file) | Re-upload cost on failure |
|----------|----------------------------|---------------------------|--------------------------|
| **STCS** (1TB/8 shards) | ~64 GB | **~10.9 min** | ~10.9 min wasted |
| **LCS** | ~160 MB | **~1.6 s** | ~1.6 s (negligible) |
| **TWCS** (10GB/day, 1-day window, 8 shards) | ~1.25 GB | **~12.5 s** | ~12.5 s |
| **TWCS** (100GB/day high-ingest) | ~12.5 GB | **~2.1 min** | ~2.1 min |
| **ICS** (Enterprise) | ~1 GB | **~10 s** | ~10 s |

SM uploads SSTables whole — no splitting at the SM or rclone level (`worker_upload.go:228` uses `RcloneMoveDir` on the entire snapshot directory). Any large-file handling is delegated to rclone's backend.

**Scylla Cloud defaults (vnodes):**

- Scylla Cloud runs **Scylla Enterprise** but does NOT explicitly set a compaction strategy on table creation (`~/dev/siren` — no compaction class in any CREATE TABLE statement)
- Scylla Enterprise's default `class` is **STCS** (`SizeTieredCompactionStrategy`) — same as Open Source
- **Confirmed**: there is no `default_compaction_strategy` setting in `scylla.yaml` (verified in `db/config.cc` source). The strategy is always per-table; if not specified at CREATE TABLE, the built-in default (STCS) applies.
- ICS is *recommended* ("always choose ICS over STCS") but is NOT the default — users must opt in
- **Therefore: Scylla Cloud customers on vnodes get STCS by default → unbounded SSTable sizes**
- Backup bandwidth: `max_bandwidth: 100M` (100 MiB/s **per node**), configured in `config/files/include/default.yaml:695`. This is a single global value applied identically to AWS (S3) and GCP (GCS) — no cloud-specific overrides exist. Siren constructs per-DC rate limit strings (`"dc1:100"`, `"dc2:100"`) but the value is the same for all DCs. SM then assigns this limit to **every node individually** via `makeHostInfo` (`backup.go:47`), and each node's rclone agent enforces it independently (`worker_upload.go:228` → `RcloneMoveDir` → `BandwidthRate: "100M"`). If a DC has 3 nodes, aggregate DC bandwidth is 3 × 100 = 300 MiB/s, not 100 shared.

**Tablets architecture (Scylla 6.0+) changes the picture:**

- With tablets, SSTables are scoped to a single tablet (not the entire vnode range)
- Default target tablet size: **~5 GB** (rule of thumb: total storage / (RF × 5 GB))
- Tablets split automatically as data grows → SSTables get smaller, not larger
- No SSTable rewrite needed on topology changes (tablet migration moves SSTables intact)
- **Pessimistic SSTable size with tablets: ~5 GB** (bounded by tablet size) regardless of compaction strategy
- Upload time for 5 GB at 100 MiB/s: ~50 seconds

| Architecture | Compaction | Pessimistic Max SSTable | Upload Time (100 MiB/s) |
|-------------|-----------|------------------------|------------------------|
| **Vnodes + STCS** (Scylla Cloud default) | STCS | Unbounded (tens/hundreds of GB) | Minutes to tens of minutes |
| **Vnodes + ICS** (Enterprise, opt-in) | ICS | ~1 GB per fragment | ~10 seconds |
| **Vnodes + LCS** | LCS | ~160 MB | ~1.6 seconds |
| **Tablets + STCS** | STCS | ~5 GB (tablet-bounded) | ~50 seconds |
| **Tablets + ICS** | ICS | ~1 GB per fragment | ~10 seconds |

**Impact on the ChunkSize=0 tradeoff:**

- **LCS (160 MB SSTables):** If an upload fails at the ~19s TCP timeout, re-uploading 160MB from scratch costs ~1.6s of bandwidth. **Negligible.** ChunkSize=0 is safe.

- **STCS/TWCS (multi-GB SSTables):** If a 50 GB SSTable upload fails after 8 minutes (at minute 8 of a ~8.5 min upload), ChunkSize=0 must re-upload all 50 GB from scratch (~8.5 min wasted). With chunked mode, only the last 16MB chunk (~160ms) is retried. **This is significant.**

- **The probability of hitting a transient error scales with upload duration.** A 160MB upload (1.6s) has negligible exposure. A 50GB upload (8.5 min) or 125GB upload (21 min) has meaningfully more exposure to transient network issues, GCS 5xx responses, or HTTP/2 RST_STREAM events.

#### Cgroup constraints and network contention make large uploads slower and riskier

The SM Agent runs in `scylla-helper.slice` with severely constrained resources:

| Resource | Agent | Scylla Server | Isolation |
|----------|-------|---------------|-----------|
| CPUWeight | 10 (very low) | Default ~100+ | Kernel (cgroup) |
| IOWeight | 10 (very low) | Default ~100+ | Kernel (cgroup) |
| Memory | 4-5% of RAM | ~90%+ | Kernel (cgroup) |
| **Network** | **No isolation** | **No isolation** | **Application-level only** (rclone bwlimit) |

**Network bandwidth is NOT isolated by cgroups.** The agent's configured `rate_limit: 100M` is an application-level cap (rclone token bucket), not a kernel guarantee. When Scylla is streaming between nodes (repair, bootstrap, decommission, tablet migration), it can consume most of the NIC bandwidth, reducing the agent's effective throughput to **10-20 MiB/s or less**.

This dramatically increases upload times for large SSTables:

| SSTable Size | Upload at 100 MiB/s | Upload at 20 MiB/s (Scylla streaming) | Upload at 10 MiB/s (heavy streaming) |
|---|---|---|---|
| **64 GB** (STCS largest) | 10.9 min | **54.6 min** | **109 min (~1.8 hrs)** |
| **16 GB** (STCS tier 3) | 2.7 min | **13.6 min** | **27.3 min** |
| 4 GB (STCS tier 2) | 41 s | 3.4 min | 6.8 min |
| 1 GB (ICS / TWCS) | 10 s | 51 s | 1.7 min |
| 160 MB (LCS) | 1.6 s | 8 s | 16 s |

**A 64 GB SSTable upload that takes ~1 hour under network contention has enormously more exposure to a >19s TCP disruption than a 10-second LCS upload.** And this is a realistic scenario — Scylla repair or topology changes can saturate the NIC for hours.

**Worst case with ChunkSize=0 and STCS under contention:**
- 64 GB SSTable uploading at effective 10 MiB/s → ~1.8 hours
- Connection dies at minute 100 (TCP stall >19s from network congestion spike)
- Entire 64 GB must be re-uploaded from scratch → another ~1.8 hours wasted
- Total: ~3.6 hours for one SSTable that should take ~11 minutes at full speed

**Same scenario with ChunkSize=16MB:**
- Connection dies at minute 100 → retries last 16 MB chunk on new connection
- Re-upload cost: 16 MB at 10 MiB/s = ~1.6 seconds
- Upload resumes from persisted offset, completes normally

Note: TCP congestion (slow throughput with ACKs flowing) does NOT itself kill TCP connections — both modes survive it. The danger is when congestion causes **buffer overflow at NIC/switch level → packet drops → TCP retransmit timeout (~19s without any ACK)**. This is more plausible during heavy Scylla streaming than during quiet periods.

**Worst case with ChunkSize=0 and STCS:**
- Node with 1TB data, 8 shards → largest SSTable realistically ~64 GB (theoretical max ~125 GB)
- Upload time: **~10.9 minutes** at 100 MiB/s
- If TCP stalls for >19s at minute 10: entire 64 GB must be re-uploaded
- Re-upload cost: ~10.9 minutes of additional bandwidth and time
- With chunked mode: only ~16MB (~160ms) re-upload needed

**Worst case with ChunkSize=0 and LCS:**
- Largest SSTable: ~160 MB
- Upload time: ~1.6 seconds at 100 MiB/s
- Re-upload cost if failed: ~1.6 seconds — negligible

### Recommendation

**The answer depends on architecture and compaction strategy:**

**Scylla Cloud on vnodes with STCS (current default):**
- **ChunkSize=16MB is the safer choice.** STCS produces unbounded SSTables — a node with 1TB and 8 shards can have a single 125 GB SSTable (21-minute upload). The re-upload cost of failure is too high to ignore. Chunked mode's extra resilience (19s→48s) provides real value for these long-running uploads.
- The fork (or equivalent buffer pool logic) remains useful to avoid allocation churn.

**Scylla Cloud on tablets (future/migration):**
- **ChunkSize=0 becomes viable.** Tablets bound SSTable size to ~5 GB (50s upload at 100 MiB/s). A failed re-upload costs ~50 seconds — acceptable given the rarity of 19+ second network blackouts on GCP internal network.
- Even with STCS on tablets, the risk is bounded.

**For LCS workloads (SSTables ≤ 160 MB):**
- **Use ChunkSize=0.** The re-upload cost is negligible (~1.6s). Memory savings, reduced latency, and dependency simplification clearly win.

**For ICS workloads (Enterprise, SSTables ≤ 1 GB):**
- **ChunkSize=0 is safe.** Re-upload cost of 1 GB is ~10 seconds. Acceptable.

**Hybrid approach (best of both):**
- SM could set ChunkSize per-upload based on file size: ChunkSize=0 for files < 1 GB, ChunkSize=16MB for files ≥ 1 GB. This would require a patch to the rclone GCS backend to make ChunkSize dynamic per-file rather than a static configuration.
- Alternatively, accept ChunkSize=0 for all uploads and rely on rclone's `--retries` + SM's job-level retry for the rare failure of large STCS SSTables. The question is whether the backup SLA tolerates the potential re-upload cost.

**Long-term:**
- Upgrade rclone fork from v1.54.0 to a modern version (v1.73+)
- Evaluate if the remaining 30 custom patches in the rclone fork are still needed
- Consider upstream contributions for any patches that are generally useful
- Once Scylla Cloud fully migrates to tablets, re-evaluate — ChunkSize=0 becomes safe for all workloads

## Appendix: Test Programs

Test source code located at:
- `~/dev/gcs-mem-test/main.go` — upstream API tests (memory + network disruption)
- `~/dev/gcs-mem-test-fork/main.go` — fork WithBuffer tests
- `~/dev/gcs-mem-test/run_tests.sh` — network disruption test harness (drop/return/throttle)
- `~/dev/gcs-mem-test/run_stall_test.sh` — TCP stall test harness (dummynet delay)

Fork source code:
- `~/dev/google-api-go-client/googleapi/googleapi.go:225-237` — `WithBuffer` implementation
- `~/dev/google-api-go-client/internal/gensupport/buffer.go:32` — `NewMediaBufferWithBuffer`
- `~/dev/google-api-go-client/internal/gensupport/media.go:208` — buffer usage in `PrepareUpload`
- `~/dev/rclone/backend/googlecloudstorage/googlecloudstorage.go:1180-1188` — pool + WithBuffer usage in SM rclone fork

Scylla Manager references:
- `~/dev/scylla-manager/pkg/service/backup/worker_upload.go:207-221` — SM backup upload retry loop (10 retries on errJobNotFound)
- `~/dev/scylla-manager/pkg/rclone/options.go:59` — Transfers = 2
- `~/dev/scylla-manager/pkg/rclone/options.go:76-78` — LowLevelRetries = 20
- `~/dev/scylla-manager/pkg/service/backup/service.go:43` — default rate limit = 100 MiB/s
- `~/dev/scylla-manager/dist/scripts/scyllamgr_agent_setup` — agent cgroup setup (4%/5% RAM)
- `~/dev/scylla-manager/vendor/github.com/rclone/rclone/lib/pacer/pacer.go:80` — pacer retries = 3

Google API library timeouts:
- `~/go/pkg/mod/google.golang.org/api@v0.214.0/transport/http/dial.go:279` — HTTP/2 ReadIdleTimeout = 31s
- `~/go/pkg/mod/google.golang.org/api@v0.214.0/transport/http/dial.go:290` — DialContext.Timeout = 30s
- `~/go/pkg/mod/google.golang.org/api@v0.214.0/internal/gensupport/resumable.go` — retryDeadline = 32s

## Appendix: Test Commands

### Setup

```bash
# Create 30MB test file
dd if=/dev/urandom of=1.txt bs=1m count=30

# Create 300MB test file
dd if=/dev/urandom of=big.txt bs=1m count=300

# Build the test binary (upstream google.golang.org/api v0.214.0)
cd ~/dev/gcs-mem-test
go build -o googleapi .

# Build the fork test binary (scylladb/google-api-go-client v0.34.1-patched)
cd ~/dev/gcs-mem-test-fork
go build -o googleapi-fork .
```

### Memory Tests (20 × 30MB uploads)

```bash
# Upstream, ChunkSize=16MB (default)
./googleapi -f 1.txt -n 20 -b karol-test-1234

# Upstream, ChunkSize=0 (no chunking)
./googleapi -f 1.txt -n 20 -b karol-test-1234 -chunk-size 0

# Fork + WithBuffer, ChunkSize=16MB
cd ~/dev/gcs-mem-test-fork
./googleapi-fork -f 1.txt -n 20 -b karol-test-1234
```

### Network Disruption Tests — TCP RST (`block return`)

```bash
# Start upload in background
./googleapi -f big.txt -n 1 -b karol-test-1234 [-chunk-size 0] &
PID=$!

# Wait for upload to begin transferring
sleep 3-5

# Apply disruption: TCP RST (connection refused)
echo "block return out proto tcp from any to storage.googleapis.com port 443" \
  | sudo pfctl -ef -

# Wait N seconds (tested: 5s, 10s, 20s)
sleep N

# Restore network
sudo pfctl -F all
sudo pfctl -d

# Wait for upload result
wait $PID
```

### Network Disruption Tests — Packet Drop (`block drop`)

```bash
# Same as above, but with silent packet loss:
echo "block drop out proto tcp from any to storage.googleapis.com port 443" \
  | sudo pfctl -ef -

# Tested durations: 20s, 60s
```

### Network Disruption Tests — Zero Bandwidth (dummynet)

```bash
# Create pipe with 1 bit/s bandwidth
sudo dnctl pipe 1 config bw 1

# Apply pipe to GCS traffic
echo "dummynet out proto tcp from any to storage.googleapis.com port 443 pipe 1" \
  | sudo pfctl -ef -

# Tested duration: 60s

# Restore
sudo pfctl -F all
sudo pfctl -d
sudo dnctl -q flush
```

### TCP Stall Tests (dummynet delay)

```bash
# Start upload in background
./googleapi -f big.txt -n 1 -b karol-test-1234 [-chunk-size 0] &
PID=$!

# Wait for upload to begin transferring
sleep 5

# Apply TCP stall: queue packets with massive delay (not drop, not RST)
# Note: macOS dummynet caps queue at 100 slots regardless of requested size
sudo dnctl pipe 1 config delay <DURATION_MS> queue 65535

# Apply pipe to both directions of GCS traffic
echo "dummynet out proto tcp from any to storage.googleapis.com port 443 pipe 1
dummynet in proto tcp from storage.googleapis.com port 443 to any pipe 1" \
  | sudo pfctl -ef -

# Wait for stall duration
sleep <DURATION_S>

# Restore network
sudo pfctl -F all
sudo pfctl -d
sudo dnctl -q flush

# Wait for upload result (timeout 5 min)
wait $PID

# Tested durations: 5s, 10s, 15s, 18s, 20s, 60s
# Results:
#   ≤18s: both modes SUCCESS
#   20s:  chunked SUCCESS, ChunkSize=0 FAILED (TCP retransmit timeout ~19s)
#   60s:  chunked FAILED (~48s), ChunkSize=0 FAILED (~19s)
```

### Cleanup (run between tests)

```bash
sudo pfctl -F all 2>/dev/null
sudo pfctl -d 2>/dev/null
sudo dnctl -q flush 2>/dev/null
```

### Test Binary Flags

```
Usage of ./googleapi:
  -b string     bucket name (default "vasil-averyanau-test")
  -f string     path to file to upload (default "./1.txt")
  -n int        number of times to upload (default 1)
  -sdk          use Go SDK client instead of API client
  -chunk-size int  chunk size for uploads; 0 disables chunking (default 16777216)
```
