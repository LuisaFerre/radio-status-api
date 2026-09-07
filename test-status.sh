#!/usr/bin/env bash
set -uo pipefail

SRC="${1:-stations-data.js}"
OUT="${2:-radio-status.json}"
TIMEOUT="${TIMEOUT:-20}"
MAX_WORKERS="${MAX_WORKERS:-20}"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
REFERER=$'Referer: https://www.radioes.com/\r\nAccept: */*\r\n'

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

hay_audio() {
  grep -q "Stream #0:.*: Audio:" "$LOG" 2>/dev/null
}

ffmpeg_run() {
  local stream="$1"; shift
  timeout "$TIMEOUT" ffmpeg -nostdin -user_agent "$UA" "$@" \
    -i "$stream" -t 5 -f null - 2>"$LOG" >/dev/null </dev/null
}

probar() {
  LOG="$TEMP_DIR/$1.log"
  local stream="$2"
  local tls=()
  [[ "$stream" == https://* ]] && tls=(-verify 0)

  ffmpeg_run "$stream" "${tls[@]}"
  if ! hay_audio && grep -qE "40[13]" "$LOG" 2>/dev/null; then
    ffmpeg_run "$stream" -headers "$REFERER" "${tls[@]}"
  fi
  
  hay_audio || { echo down; return; }
  [[ "$stream" == http://* ]] && { echo http; return; }
  echo ok
}

total=0 workers=0

while IFS= read -r linea <&3; do
  case "$linea" in
  *'stream:'*) stream=${linea#*stream:\ \"}; stream=${stream%%\"*} ;;
  *'id:'*)     id=${linea#*id:\ \"};         id=${id%%\"*} ;;
  *'name:'*)   name=${linea#*name:\ \"};     name=${name%%\"*} ;;
  *'}'*)
    if [[ -n "${id:-}" && -n "${stream:-}" && "$stream" != "random" && "$id" =~ ^[A-Z0-9]{10}$ ]]; then
      ((total++))
      (
        e=$(probar "$id" "$stream")
        echo "$e|$id|$name|$total"
      ) >>"$TEMP_DIR/results" &
      ((workers++))
      [[ $workers -ge $MAX_WORKERS ]] && { wait -n; ((workers--)); }
    fi
    id="" stream="" name=""
    ;;
  esac
done 3<"$SRC"
wait

n_ok=0 n_http=0 n_down=0
sort -t'|' -k4 -n "$TEMP_DIR/results" >"$TEMP_DIR/sorted"

echo "Procesando resultados..."

echo "{" >"$OUT.tmp"
primero=true
while IFS='|' read -r e rid rname _; do
  case $e in
  ok)   tag=OK;   ((n_ok++)) ;;
  http) tag=HTTP; ((n_http++)) ;;
  *)    e=down; tag=DOWN; ((n_down++)) ;;
  esac

  printf '%-8s %-12s %s\n' "$tag" "$rid" "$rname"
  $primero && primero=false || printf ',\n' >>"$OUT.tmp"
  printf '  "%s": "%s"' "$rid" "$e" >>"$OUT.tmp"
done <"$TEMP_DIR/sorted"
{ echo ""; echo "}"; } >>"$OUT.tmp"
mv "$OUT.tmp" "$OUT"

echo ""
echo "══════════════ RESUMEN ══════════════"
echo "   Total:   $total"
echo "   OK:      $n_ok"
echo "   HTTP:    $n_http"
echo "   Down:    $n_down"
echo "   Generado:   $OUT"
