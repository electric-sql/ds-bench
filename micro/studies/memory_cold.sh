# memory_cold study — cold-read isolation. The server runs under a cgroup
# MemoryMax so its page cache is bounded; reading a cold stream LARGER than
# that cap forces real disk I/O. We then measure hot 4 KB read latency while
# background readers churn the cold stream, sweeping the memory cap.
# read-offload modes MATTER here: inline stalls the async worker on a fault,
# tail/always offload it, uring reads async in-kernel.
#
# Container note: capped cells (mem != infinity) require a delegated cgroup at
# /sys/fs/cgroup/dsbench (or equivalent). If unavailable, capped cells are
# skipped with a SKIP notice rather than failing silently.
#
# Emits: study=memory_cold scenario=hot_under_cold with mem + cold_gib.

# _apply_mem_cap <mem>: write MemoryMax into the server's delegated cgroup.
# Returns 1 if cgroup delegation is not available (caller should skip).
_apply_mem_cap() {
  local cap="$1"
  # Try the delegated cgroup path; adjust CGROUP_MEM_PATH to taste.
  local cg="${CGROUP_MEM_PATH:-/sys/fs/cgroup/dsbench}"
  if [ ! -w "$cg/memory.max" ] && [ ! -w "$cg" ]; then
    return 1   # no writable delegation
  fi
  if [ "$cap" = "infinity" ]; then
    echo "max" > "$cg/memory.max" 2>/dev/null || true
  else
    echo "$cap" > "$cg/memory.max" 2>/dev/null || { return 1; }
  fi
}

study_memory_cold() {
  ab_log "STUDY memory_cold (mems: $COLD_MEMS, cold=${COLD_STREAM_GIB}GiB)"
  local specs="${ENGINE_SPECS_COLD:-hyper:- raw:inline raw:tail raw:always uring:-}"
  local BURL="http://127.0.0.1:${PORT}/big"
  local chunk=/tmp/chunk64.bin
  head -c 67108864 /dev/zero | tr '\0' y > "$chunk"      # 64 MiB filler
  local nchunks=$(( COLD_STREAM_GIB * 16 ))               # 64MiB * 16 = 1 GiB
  local mem spec eng mode rep p50 p99 mx cpu COLDPIDS
  for mem in $COLD_MEMS; do
    SERVER_MEM="$mem"
    # Guard: capped cells require cgroup delegation; skip if unavailable.
    if [ "$mem" != "infinity" ]; then
      if ! _apply_mem_cap "$mem"; then
        echo "SKIP memory_cold cap=$mem (no cgroup delegation)"
        ab_log "SKIP memory_cold cap=$mem — cgroup delegation not available; run only uncapped cells"
        continue
      fi
    fi
    for spec in $specs; do
      eng="${spec%%:*}"; mode="${spec#*:}"
      for rep in $(seq 1 "$REPEATS"); do
        start_server "$eng" "$mode" || continue
        # Apply memory cap after server starts (move server PID into cgroup if possible)
        if [ "$mem" != "infinity" ] && [ -n "${SERVER_PID:-}" ]; then
          local cg="${CGROUP_MEM_PATH:-/sys/fs/cgroup/dsbench}"
          echo "$SERVER_PID" > "$cg/cgroup.procs" 2>/dev/null || true
        fi
        seed 4096 || { stop_server; continue; }            # hot stream
        # build the cold stream (> mem cap)
        curl -s -X PUT "$BURL" -H 'Content-Type: application/octet-stream' >/dev/null
        local i; for i in $(seq 1 "$nchunks"); do
          curl -s -X POST "$BURL" -H 'Content-Type: application/octet-stream' --data-binary @"$chunk" >/dev/null
        done
        sudo sh -c 'echo 1 > /proc/sys/vm/drop_caches' 2>/dev/null   # cold start
        # background cold readers (leak-free: explicit PIDs + URL mop-up)
        COLDPIDS=()
        local r; for r in 1 2 3 4; do ( while :; do curl -s "$BURL" -o /dev/null; done ) & COLDPIDS+=($!); done
        sleep 1
        read -r _ p50 p99 mx cpu <<<"$(measure 16 "$URL")"
        for r in "${COLDPIDS[@]}"; do kill "$r" 2>/dev/null; done
        pkill -f "curl -s $BURL" 2>/dev/null
        ab_emit study=memory_cold scenario=hot_under_cold engine="$eng" mode="$mode" mem="$mem" cold_gib="$COLD_STREAM_GIB" conn=16 rep="$rep" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu" server_cpus="$SERVER_CPUS"
        ab_log "  cold $eng/$mode mem=$mem r$rep -> hot p50=$p50 p99=$p99 max=$mx ms"
        stop_server
      done
    done
  done
  SERVER_MEM=infinity
}
