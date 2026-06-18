# tiering study — exercises the hot/cold tiering path (the recently-refactored
# code). Uses the tier-feature binary ($BIN_TIER, set by run.sh). Two scenarios:
#   append_tiered      : 100 B appends with sealing/offload active (background
#                        cost vs the non-tiered append baseline in the engines study)
#   read_tiered_cold   : full-stream GET of a multi-segment stream whose prefix has
#                        been sealed + offloaded to the local blobstore (reads route
#                        through resolve_range -> blobstore range-GET, Body::Channel)
#
# tier=local always; tier=s3 (MinIO) only when TIER_S3=1 (run.sh wires creds).

study_tiering() {
  [ -n "${BIN_TIER:-}" ] && [ -x "$BIN_TIER" ] || { ab_log "STUDY tiering SKIPPED (no tier binary)"; return 0; }
  local SAVED_BIN="$BIN"; BIN="$BIN_TIER"
  ab_log "STUDY tiering (seg=${TIER_SEG_BYTES}B local$([ "$TIER_S3" = 1 ] && echo '+s3'))"

  local backends="local"; [ "$TIER_S3" = 1 ] && backends="local s3"
  cat > /tmp/post.lua <<EOF
wrk.method = "POST"
wrk.body = string.rep("x", ${APPEND_MSG})
wrk.headers["Content-Type"] = "application/octet-stream"
EOF
  local be rep rps p50 p99 mx cpu mbps
  for be in $backends; do
    local tierargs=(--tier "$be" --tier-segment-bytes "$TIER_SEG_BYTES")
    AB_PROPS=()
    if [ "$be" = local ]; then tierargs+=(--tier-local-dir "$DATA/cold")
    else
      tierargs+=(--tier-endpoint "$TIER_S3_ENDPOINT" --tier-bucket "$TIER_S3_BUCKET" --tier-region us-east-1 --tier-path-style --tier-allow-http)
      AB_PROPS=(-p "Environment=DS_S3_ACCESS_KEY_ID=${TIER_S3_KEY}" -p "Environment=DS_S3_SECRET_ACCESS_KEY=${TIER_S3_SECRET}")
    fi

    # 1) append with tiering active
    for rep in $(seq 1 "$REPEATS"); do
      start_server raw tail "${tierargs[@]}" || continue
      curl -s -X PUT "$URL" -H 'Content-Type: application/octet-stream' >/dev/null
      read -r rps p50 p99 mx cpu <<<"$(measure 256 "$URL" -s /tmp/post.lua)"
      ab_emit study=tiering scenario=append_tiered backend="$be" engine=raw seg_bytes="$TIER_SEG_BYTES" conn=256 rep="$rep" rps="$rps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu"
      ab_log "  append_tiered $be r$rep -> $rps/s cpu${cpu}%"
      stop_server
    done

    # 2) cold-tier full-stream read (prefix sealed+offloaded)
    for rep in $(seq 1 "$REPEATS"); do
      start_server raw tail "${tierargs[@]}" || continue
      # seed 8 segments worth so a multi-segment prefix seals + offloads
      local total=$(( TIER_SEG_BYTES * 8 ))
      curl -s -X PUT "$URL" -H 'Content-Type: application/octet-stream' >/dev/null
      head -c "$total" /dev/zero | tr '\0' w > /tmp/tierbody.bin
      curl -s -X POST "$URL" -H 'Content-Type: application/octet-stream' --data-binary @/tmp/tierbody.bin >/dev/null
      # nudge a few seal passes + let async offload finish
      local k; for k in 1 2 3; do curl -s -X POST "$URL" -H 'Content-Type: application/octet-stream' --data-binary @/tmp/tierbody.bin >/dev/null; done
      sleep 4
      local objs=0; [ "$be" = local ] && objs=$(ls "$DATA/cold" 2>/dev/null | wc -l)
      local got; got=$(curl -s "$URL" | wc -c)
      read -r rps p50 p99 mx cpu <<<"$(measure 64 "$URL")"
      mbps=$(awk -v r="$rps" -v s="$got" 'BEGIN{printf "%.1f", r*s/1048576}')
      ab_emit study=tiering scenario=read_tiered_cold backend="$be" engine=raw seg_bytes="$TIER_SEG_BYTES" stream_bytes="$got" objects="$objs" conn=64 rep="$rep" rps="$rps" mbps="$mbps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu"
      ab_log "  read_tiered_cold $be r$rep -> $rps/s ${mbps}MB/s objs=$objs cpu${cpu}%"
      stop_server
    done
    AB_PROPS=()
  done
  BIN="$SAVED_BIN"
}
