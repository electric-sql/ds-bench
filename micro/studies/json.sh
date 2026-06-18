# json study — byte (binary) vs JSON mode, on OUR server. The append path is
# where the modes diverge: binary stores the body VERBATIM (wire == body), so it
# is splice(2)-eligible (zero-copy socket->file), while JSON parses + reframes the
# body (array flattening, value-comma runs) so it copies through userspace and
# CANNOT splice. Reads are byte ranges of the stored wire bytes in both modes, so
# we add one read cell for completeness but expect appends to show the gap.
#
# Modes:
#   binary        — octet-stream, JSON_MSG raw bytes (no splice)
#   binary_splice — same, with --splice-appends (the zero-copy lever; binary only)
#   json_value    — application/json, one ~JSON_MSG-byte JSON object per POST
#   json_array    — application/json, a JSON array of JSON_ARRAY_K values (flattening)
#
# Single-engine (raw-only) server: run with NO_HTTP_ENGINE_FLAG=1.
# Emits: study=json scenario in {append,read} with a `mode` dimension.

JSON_CONNS="${JSON_CONNS:-64 256}"
JSON_MSG="${JSON_MSG:-100}"          # target payload bytes (matched binary vs json_value)
JSON_ARRAY_K="${JSON_ARRAY_K:-10}"   # values per JSON array POST
JSON_READ_CONN="${JSON_READ_CONN:-256}"

study_json() {
  ab_log "STUDY json (byte vs JSON mode; msg=$JSON_MSG arrayK=$JSON_ARRAY_K)"
  local mode conn rep rps p50 p99 mx cpu mbps ct lua body bytes pad ck

  # --- build matched-size bodies once (single source of truth for size) ---
  head -c "$JSON_MSG" /dev/zero | tr '\0' x > /tmp/jb_binary
  pad=$(( JSON_MSG > 10 ? JSON_MSG - 10 : 1 ))
  { printf '{"d":"'; head -c "$pad" /dev/zero | tr '\0' x; printf '"}'; } > /tmp/jb_jsonval
  { printf '['; local i; for i in $(seq 1 "$JSON_ARRAY_K"); do
      [ "$i" -gt 1 ] && printf ','; printf '{"i":%d,"d":"xxxx"}' "$i"; done; printf ']'; } > /tmp/jb_jsonarr

  # wrk script that POSTs a fixed body file with a given content-type.
  make_lua() { # <body-file> <content-type> <out-lua>
    cat > "$3" <<EOF
wrk.method = "POST"
local f = io.open("$1", "rb"); wrk.body = f:read("*a"); f:close()
wrk.headers["Content-Type"] = "$2"
EOF
  }
  make_lua /tmp/jb_binary  application/octet-stream /tmp/json_bin.lua
  make_lua /tmp/jb_jsonval application/json         /tmp/json_val.lua
  make_lua /tmp/jb_jsonarr application/json         /tmp/json_arr.lua

  # --- appends: the path where modes diverge ---
  for mode in binary binary_splice json_value json_array; do
    case "$mode" in
      binary)        ct=application/octet-stream; lua=/tmp/json_bin.lua; body=/tmp/jb_binary;  set -- ;;
      binary_splice) ct=application/octet-stream; lua=/tmp/json_bin.lua; body=/tmp/jb_binary;  set -- --splice-appends ;;
      json_value)    ct=application/json;         lua=/tmp/json_val.lua; body=/tmp/jb_jsonval; set -- ;;
      json_array)    ct=application/json;         lua=/tmp/json_arr.lua; body=/tmp/jb_jsonarr; set -- ;;
    esac
    bytes=$(wc -c < "$body")
    for conn in $JSON_CONNS; do
      for rep in $(seq 1 "$REPEATS"); do
        start_server raw tail "$@" || continue
        curl -s -X PUT "$URL" -H "Content-Type: $ct" >/dev/null
        # sanity: one append must succeed (2xx/204) and be readable back
        if curl -s -o /dev/null -w '%{http_code}' -X POST "$URL" -H "Content-Type: $ct" --data-binary @"$body" | grep -q '^2'; then ck=ok; else ck=BADAPPEND; fi
        read -r rps p50 p99 mx cpu <<<"$(measure "$conn" "$URL" -s "$lua")"
        mbps=$(awk -v r="$rps" -v s="$bytes" 'BEGIN{printf "%.1f", r*s/1048576}')
        ab_emit study=json scenario=append mode="$mode" bytes="$bytes" conn="$conn" rep="$rep" rps="$rps" mbps="$mbps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu" sanity="$ck"
        ab_log "  append $mode c$conn r$rep -> $rps/s ${mbps}MB/s cpu${cpu}% ($ck)"
        stop_server
      done
    done
  done

  # --- reads: byte ranges of stored wire bytes; expect mode-independent at equal size ---
  for mode in binary json_value; do
    case "$mode" in
      binary)     ct=application/octet-stream; body=/tmp/jb_binary  ;;
      json_value) ct=application/json;         body=/tmp/jb_jsonval ;;
    esac
    for rep in $(seq 1 "$REPEATS"); do
      start_server raw tail || continue
      curl -s -X PUT "$URL" -H "Content-Type: $ct" >/dev/null
      # append ~64 KiB worth so the catch-up GET has a real body to stream
      local n; for n in $(seq 1 200); do curl -s -o /dev/null -X POST "$URL" -H "Content-Type: $ct" --data-binary @"$body"; done
      read -r rps p50 p99 mx cpu <<<"$(measure "$JSON_READ_CONN" "$URL")"
      ab_emit study=json scenario=read mode="$mode" conn="$JSON_READ_CONN" rep="$rep" rps="$rps" p50_ms="$p50" p99_ms="$p99" max_ms="$mx" cpu_pct="$cpu"
      ab_log "  read $mode c$JSON_READ_CONN r$rep -> $rps/s cpu${cpu}%"
      stop_server
    done
  done
}
