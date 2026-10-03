#!/bin/sh
# Считает следующий тег релиза x.y.z для каналов stable (main) и dev.
# Использование: next_tag.sh <stable|dev> [--promote] [--major]
# Список существующих тегов читает из stdin (по одному в строке), учитывает
# только N.N.N. Чётный minor - стабильный, нечётный - dev. Печатает тег.
set -eu

usage() {
  echo "Использование: $0 <stable|dev> [--promote] [--major]" >&2
  exit 2
}

[ $# -ge 1 ] || usage
CHANNEL=$1
shift
case "$CHANNEL" in
  stable|dev) ;;
  *) usage ;;
esac
PROMOTE=0
MAJOR=0
for a in "$@"; do
  case "$a" in
    --promote) PROMOTE=1 ;;
    --major) MAJOR=1 ;;
    *) usage ;;
  esac
done

awk -v channel="$CHANNEL" -v promote="$PROMOTE" -v major="$MAJOR" '
function newer(a, b,   x, y) {
  split(a, x, "."); split(b, y, ".")
  if (x[1] + 0 != y[1] + 0) return x[1] + 0 > y[1] + 0
  if (x[2] + 0 != y[2] + 0) return x[2] + 0 > y[2] + 0
  return x[3] + 0 > y[3] + 0
}
/^[0-9]+\.[0-9]+\.[0-9]+$/ {
  split($0, p, ".")
  if (p[2] % 2 == 0) { if (S == "" || newer($0, S)) S = $0 }
  else { if (D == "" || newer($0, D)) D = $0 }
}
END {
  if (S != "") split(S, s, ".")
  if (D != "") split(D, d, ".")
  if (major) {
    X = 0
    if (S != "" && s[1] + 0 > X) X = s[1] + 0
    if (D != "" && d[1] + 0 > X) X = d[1] + 0
    print (X + 1) "." (channel == "stable" ? "0" : "1") ".0"
    exit 0
  }
  if (channel == "stable") {
    if (promote) {
      if (D != "" && (S == "" || newer(D, S))) { print d[1] "." (d[2] + 1) ".0"; exit 0 }
      print "Нечего продвигать: нет dev-тега новее стабильного" > "/dev/stderr"
      exit 1
    }
    if (S == "") print "1.0.0"; else print s[1] "." s[2] "." (s[3] + 1)
  } else {
    if (D != "" && (S == "" || newer(D, S))) print d[1] "." d[2] "." (d[3] + 1)
    else if (S != "") print s[1] "." (s[2] + 1) ".0"
    else print "1.1.0"
  }
}'
