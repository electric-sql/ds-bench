# splice study — zero-copy binary appends (raw engine), --splice-appends OFF vs
# ON. Appends are fsync-bound so throughput is ~unchanged; the win is CPU (the
# socket->userspace->file copy is eliminated). Verifies a known append reads back
# byte-identical in each mode.
#
# Emits: study=splice scenario=append_bin with size + splice(off/on) + mbps.

study_splice() {
  ab_log "STUDY splice (sizes: $SPLICE_SIZES)"
  local size conn=64 sp rep rps p50 p99 mx cpu mbps ck
  for size in $SPLICE_SIZES; do
    cat > /tmp/post_bin.lua <<EOF
wrk.method = "POST"
wrk.body = string.rep("z", ${size})
wrk.headers["Content-Type"] = "application/octet-stream"
EOF
    for sp in off on; do
      for rep in $(seq 1 "$REPEATS"); do
        if [ "$sp" = on ]; then start_server raw inline --splice-appends || continue
        else start_server raw inline || continue; fi
        curl -s -X PUT "$URL" -H 'Content-Type: application/octet-stream' >/dev/null
        head -c "$size" /dev/urandom > /tmp/splice_chk.bin
        curl -s -X POST "$URL" -H 'Content-Type: application/octet-stream' --data-binary @/tmp/splice_chk.bin >/dev/null
        if curl -s "$URL" -o /tmp/splice_back.bin && cmp -s /tmp/splice_chk.bin /tmp/splice_back.bin; then ck=ok; else ck=MISMATCH; fi
        read -r rps p50 p99 mx cpu <<<"$(measure "$conn" "$URL" -s /tmp/post_bin.lua)"
        mbps=$(awk -v r="$rps" -v s="$size" 'BEGIN{printf "%.1f", r*s/1048576}')
        ab_emit study=splice scenario=append_bin engine=raw splice="$sp" size="$size" conn="$conn" rep="$rep" rps="$rps" mbps="$mbps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu" readback="$ck"
        ab_log "  splice $sp size=$size r$rep -> $rps/s ${mbps}MB/s cpu${cpu}% rb=$ck"
        stop_server
      done
    done
  done
}
