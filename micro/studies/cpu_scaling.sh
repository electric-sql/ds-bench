# cpu_scaling study — how each engine scales with server core count. The server
# auto-derives its worker/thread count from the cgroup cpuset (Rust's
# available_parallelism honours sched affinity), so varying AllowedCPUs varies
# effective threads. Client stays pinned to CLIENT_CPUS throughout.
#
# Emits: study=cpu_scaling scenario in {read, append} with ncpu + server_cpus.

study_cpu_scaling() {
  ab_log "STUDY cpu_scaling (cpusets: $SCALE_CPUSETS)"
  cat > /tmp/post.lua <<EOF
wrk.method = "POST"
wrk.body = string.rep("x", ${APPEND_MSG})
wrk.headers["Content-Type"] = "application/octet-stream"
EOF
  local cset eng mode spec rep rps p50 p99 mx cpu ncpu
  local specs="${ENGINE_SPECS:-hyper:- raw:tail uring:-}"
  for cset in $SCALE_CPUSETS; do
    ncpu=$(cpu_count "$cset")
    SERVER_CPUS="$cset"     # consumed by start_server/measure via env
    for spec in $specs; do
      eng="${spec%%:*}"; mode="${spec#*:}"
      # read at SWEEP_SIZE
      for rep in $(seq 1 "$REPEATS"); do
        start_server "$eng" "$mode" || continue
        if seed "$SWEEP_SIZE"; then
          read -r rps p50 p99 mx cpu <<<"$(measure "$SIZE_CONN" "$URL")"
          ab_emit study=cpu_scaling scenario=read engine="$eng" mode="$mode" size="$SWEEP_SIZE" conn="$SIZE_CONN" ncpu="$ncpu" server_cpus="$cset" rep="$rep" rps="$rps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu"
          ab_log "  read $eng ncpu=$ncpu r$rep -> $rps/s cpu${cpu}%"
        fi
        stop_server
      done
      # append
      for rep in $(seq 1 "$REPEATS"); do
        start_server "$eng" "$mode" || continue
        curl -s -X PUT "$URL" -H 'Content-Type: application/octet-stream' >/dev/null
        read -r rps p50 p99 mx cpu <<<"$(measure "$SIZE_CONN" "$URL" -s /tmp/post.lua)"
        ab_emit study=cpu_scaling scenario=append engine="$eng" mode="$mode" size="$APPEND_MSG" conn="$SIZE_CONN" ncpu="$ncpu" server_cpus="$cset" rep="$rep" rps="$rps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu"
        ab_log "  append $eng ncpu=$ncpu r$rep -> $rps/s cpu${cpu}%"
        stop_server
      done
    done
  done
  SERVER_CPUS="${SERVER_CPUS_DEFAULT}"  # restore
}

# count cpus in a cpuset spec like "0-3" or "0-1,4" -> integer
cpu_count() {
  awk -v s="$1" 'BEGIN{n=0; m=split(s,parts,","); for(i=1;i<=m;i++){if(split(parts[i],r,"-")==2)n+=r[2]-r[1]+1; else n+=1} print n}'
}
