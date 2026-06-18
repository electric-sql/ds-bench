# engines study — apples-to-apples engine comparison with server and client
# pinned to DISJOINT core sets (the isolation that same-box contention otherwise
# hides). read-offload mode is irrelevant for hot/cached reads, so raw runs in
# its default 'tail' mode here; modes are explored in the memory_cold study.
#
# Emits: scenario in {read_size, read_conn, append}.
#   read_size : size sweep at conn=$SIZE_CONN
#   read_conn : concurrency sweep at size=$SWEEP_SIZE
#   append    : unbatched POST sweep over $CONNS_SWEEP

ENGINE_SPECS="${ENGINE_SPECS:-hyper:- raw:tail uring:-}"

study_engines() {
  ab_log "STUDY engines (server=$SERVER_CPUS client=$CLIENT_CPUS)"
  cat > /tmp/post.lua <<EOF
wrk.method = "POST"
wrk.body = string.rep("x", ${APPEND_MSG})
wrk.headers["Content-Type"] = "application/octet-stream"
EOF
  local spec eng mode size conn rep rps p50 p99 mx cpu
  for spec in $ENGINE_SPECS; do
    eng="${spec%%:*}"; mode="${spec#*:}"
    # size sweep at SIZE_CONN
    for size in $READ_SIZES; do
      for rep in $(seq 1 "$REPEATS"); do
        start_server "$eng" "$mode" || continue
        if seed "$size"; then
          read -r rps p50 p99 mx cpu <<<"$(measure "$SIZE_CONN" "$URL")"
          ab_emit study=engines scenario=read_size engine="$eng" mode="$mode" size="$size" conn="$SIZE_CONN" rep="$rep" rps="$rps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu" server_cpus="$SERVER_CPUS"
          ab_log "  read_size $eng/$mode size=$size c$SIZE_CONN r$rep -> $rps/s cpu${cpu}%"
        fi
        stop_server
      done
    done
    # concurrency sweep at SWEEP_SIZE
    for conn in $CONNS_SWEEP; do
      for rep in $(seq 1 "$REPEATS"); do
        start_server "$eng" "$mode" || continue
        if seed "$SWEEP_SIZE"; then
          read -r rps p50 p99 mx cpu <<<"$(measure "$conn" "$URL")"
          ab_emit study=engines scenario=read_conn engine="$eng" mode="$mode" size="$SWEEP_SIZE" conn="$conn" rep="$rep" rps="$rps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu" server_cpus="$SERVER_CPUS"
          ab_log "  read_conn $eng/$mode c$conn r$rep -> $rps/s cpu${cpu}%"
        fi
        stop_server
      done
    done
    # append sweep
    for conn in $CONNS_SWEEP; do
      for rep in $(seq 1 "$REPEATS"); do
        start_server "$eng" "$mode" || continue
        curl -s -X PUT "$URL" -H 'Content-Type: application/octet-stream' >/dev/null
        read -r rps p50 p99 mx cpu <<<"$(measure "$conn" "$URL" -s /tmp/post.lua)"
        ab_emit study=engines scenario=append engine="$eng" mode="$mode" size="$APPEND_MSG" conn="$conn" rep="$rep" rps="$rps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu" server_cpus="$SERVER_CPUS"
        ab_log "  append $eng c$conn r$rep -> $rps/s cpu${cpu}%"
        stop_server
      done
    done
  done
}
