# engines study — read-size × connections sweep on the single raw server with
# server and client pinned to DISJOINT core sets (the isolation that same-box
# contention otherwise hides). read-offload mode is swept where applicable.
#
# Emits: scenario in {read_size, read_conn, append}.
#   read_size : size sweep at conn=$SIZE_CONN, over $MODES
#   read_conn : concurrency sweep at size=$SWEEP_SIZE, over $MODES
#   append    : unbatched POST sweep over $CONNS_SWEEP (mode=tail)

study_engines() {
  ab_log "STUDY engines (server=$SERVER_CPUS client=$CLIENT_CPUS)"
  cat > /tmp/post.lua <<EOF
wrk.method = "POST"
wrk.body = string.rep("x", ${APPEND_MSG})
wrk.headers["Content-Type"] = "application/octet-stream"
EOF
  local mode size conn rep rps p50 p99 mx cpu
  # size sweep at SIZE_CONN
  for mode in $MODES; do
    for size in $READ_SIZES; do
      for rep in $(seq 1 "$REPEATS"); do
        start_server "$mode" || continue
        if seed "$size"; then
          read -r rps p50 p99 mx cpu <<<"$(measure "$SIZE_CONN" "$URL")"
          ab_emit study=engines scenario=read_size mode="$mode" size="$size" conn="$SIZE_CONN" rep="$rep" rps="$rps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu" server_cpus="$SERVER_CPUS"
          ab_log "  read_size mode=$mode size=$size c$SIZE_CONN r$rep -> $rps/s cpu${cpu}%"
        fi
        stop_server
      done
    done
  done
  # concurrency sweep at SWEEP_SIZE
  for mode in $MODES; do
    for conn in $CONNS_SWEEP; do
      for rep in $(seq 1 "$REPEATS"); do
        start_server "$mode" || continue
        if seed "$SWEEP_SIZE"; then
          read -r rps p50 p99 mx cpu <<<"$(measure "$conn" "$URL")"
          ab_emit study=engines scenario=read_conn mode="$mode" size="$SWEEP_SIZE" conn="$conn" rep="$rep" rps="$rps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu" server_cpus="$SERVER_CPUS"
          ab_log "  read_conn mode=$mode c$conn r$rep -> $rps/s cpu${cpu}%"
        fi
        stop_server
      done
    done
  done
  # append sweep (mode=tail; append path is read-offload-independent)
  for conn in $CONNS_SWEEP; do
    for rep in $(seq 1 "$REPEATS"); do
      start_server tail || continue
      curl -s -X PUT "$URL" -H 'Content-Type: application/octet-stream' >/dev/null
      read -r rps p50 p99 mx cpu <<<"$(measure "$conn" "$URL" -s /tmp/post.lua)"
      ab_emit study=engines scenario=append mode=tail size="$APPEND_MSG" conn="$conn" rep="$rep" rps="$rps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu" server_cpus="$SERVER_CPUS"
      ab_log "  append c$conn r$rep -> $rps/s cpu${cpu}%"
      stop_server
    done
  done
}
