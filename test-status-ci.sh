#!/usr/bin/env bash
set -uo pipefail

SRC="stations-data.js"
OUT="radio-status.json"
MAX_WORKERS=20
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
REFERER=$'Referer: https://www.radioes.com/\r\nAccept: */*\r\n'

OPTIONS_1=(-nostdin -user_agent "$UA" -headers "$REFERER" -tls_verify 0)
OPTIONS_2=(-nostdin -user_agent "$UA" -headers "$REFERER")

LOG_DIR="logs"
mkdir -p "$LOG_DIR"

hay_audio() {
  grep -q "Stream #0:.*: Audio:" "$LOG" 2>/dev/null
}

probar() {
  local id="$1"
  local stream="$2"
  LOG="$LOG_DIR/$id.log"

  ffmpeg "${OPTIONS_1[@]}" -i "$stream" >/dev/null 2>"$LOG" </dev/null

  if grep -q "Option tls_verify not found" "$LOG" 2>/dev/null; then
    ffmpeg "${OPTIONS_2[@]}" -i "$stream" >/dev/null 2>"$LOG" </dev/null
  fi

  hay_audio || {
    echo down
    return
  }
  [[ "$stream" == http://* ]] && {
    echo http
    return
  }
  echo ok
}

total=0
workers=0
RESULTS="$LOG_DIR/results.txt"

while IFS= read -r line <&3; do
  case "$line" in
  *'stream:'*)
    stream=${line#*stream:\ \"}
    stream=${stream%%\"*}
    ;;
  *'id:'*)
    id=${line#*id:\ \"}
    id=${id%%\"*}
    ;;
  *'name:'*)
    name=${line#*name:\ \"}
    name=${name%%\"*}
    ;;
  *'}'*)
    ((total++))
    (
      e=$(probar "$id" "$stream")
      echo "$e|$id|$name|$total"
    ) >>"$RESULTS" &
    ((workers++))
    [[ $workers -ge $MAX_WORKERS ]] && {
      wait -n
      ((workers--))
    }
    id="" stream="" name=""
    ;;
  esac
done 3<"$SRC"
wait

sort -t'|' -k4 -n "$RESULTS" >"$LOG_DIR/sorted.txt"

n_ok=0
n_http=0
n_down=0
echo "{" >"$OUT.tmp"
primero=true

while IFS='|' read -r e rid rname _; do
  case $e in
  ok)
    tag=OK
    ((n_ok++))
    ;;
  http)
    tag=HTTP
    ((n_http++))
    ;;
  *)
    e=down
    tag=DOWN
    ((n_down++))
    ;;
  esac
  printf '%-11s %-5s %s\n' "$rid" "$tag" "$rname"
  if $primero; then primero=false; else printf ',\n' >>"$OUT.tmp"; fi
  printf '  "%s": "%s"' "$rid" "$e" >>"$OUT.tmp"
done <"$LOG_DIR/sorted.txt"

{
  echo ""
  echo "}"
} >>"$OUT.tmp"
mv "$OUT.tmp" "$OUT"

echo ""
echo "══════════════ RESUMEN ══════════════"
echo "   Total:   $total"
echo "   OK:      $n_ok"
echo "   HTTP:    $n_http"
echo "   Down:    $n_down"
echo "   Generado:   $OUT"
echo "   Logs en:    $LOG_DIR/"
