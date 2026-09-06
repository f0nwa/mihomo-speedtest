# render_stats.awk — собирает самодостаточную HTML-страницу со статистикой
# замеров speedtest2.sh: график канала/порога и график числа нод по прогонам
# (из speedtest_runs.tsv) плюс таблица последнего замера (из
# speedtest_last.txt). Без внешних CSS/JS-зависимостей — чистый inline SVG.
# Вызывается из speedtest2.sh (render_stats()), на роутере напрямую не
# запускается.
#
# Использование:
#   awk -v last=PATH -v generated="строка даты" -f render_stats.awk RUNS_TSV
#
# RUNS_TSV (позиционный аргумент, может быть пустым файлом):
#   epoch<TAB>iso<TAB>channel_bytes<TAB>threshold_bytes<TAB>total<TAB>alive<TAB>tested<TAB>good<TAB>winners
# last: путь к speedtest_last.txt (строки "speed_MB<TAB>unit<TAB>name"),
#   необязателен — если не задан или не существует, таблица не выводится.

function esc(s) {
  gsub(/&/, "\\&amp;", s)
  gsub(/</, "\\&lt;", s)
  gsub(/>/, "\\&gt;", s)
  return s
}

function fmt_mb(bytes,   mb, frac) {
  mb = int(bytes / 1048576)
  frac = int((bytes % 1048576) * 10 / 1048576)
  return mb "." frac
}

function poly(vals, cnt, maxv,   i, x, y, out, w, h, left, top) {
  left = 40; top = 10; w = 710; h = 170
  out = ""
  if (maxv <= 0) maxv = 1
  for (i = 1; i <= cnt; i++) {
    if (cnt > 1) x = left + int((i - 1) * w / (cnt - 1))
    else x = left + int(w / 2)
    y = top + h - int(vals[i] * h / maxv)
    out = out x "," y " "
  }
  return out
}

BEGIN {
  FS = "\t"
  n = 0
}

{
  n++
  epoch[n] = $1
  iso[n] = $2
  channel[n] = $3 + 0
  threshold[n] = $4 + 0
  total[n] = $5 + 0
  alive[n] = $6 + 0
  tested[n] = $7 + 0
  good[n] = $8 + 0
  winners[n] = $9 + 0
}

END {
  max1 = 1
  max2 = 1
  for (i = 1; i <= n; i++) {
    if (channel[i] > max1) max1 = channel[i]
    if (threshold[i] > max1) max1 = threshold[i]
    if (good[i] > max2) max2 = good[i]
    if (winners[i] > max2) max2 = winners[i]
  }

  print "<!doctype html><meta charset=\"utf-8\">"
  print "<title>speedtest2 — статистика</title>"
  print "<style>"
  print "body{font:14px/1.4 system-ui,sans-serif;margin:16px;color:#1b1f24;background:#fff}"
  print "h1{font-size:18px;margin:0 0 4px}"
  print "h2{font-size:15px;margin:20px 0 6px}"
  print ".meta{color:#666;margin-bottom:16px}"
  print "svg{max-width:100%;height:auto;border:1px solid #e2e2e2;border-radius:6px;margin-bottom:8px;display:block}"
  print "table{border-collapse:collapse;font-variant-numeric:tabular-nums}"
  print "td,th{padding:2px 10px;text-align:right;border-bottom:1px solid #eee}"
  print "th:last-child,td:last-child{text-align:left}"
  print ".legend{font-size:12px;color:#555;margin:0 0 4px}"
  print ".sw{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:4px;vertical-align:-1px}"
  print "</style>"
  print "<h1>Статистика speedtest2</h1>"
  print "<p class=\"meta\">Сгенерировано: " esc(generated) " · прогонов в истории: " n "</p>"

  if (n == 0) {
    print "<p>Пока нет ни одного прогона в истории.</p>"
  } else {
    print "<h2>Канал и порог отбора</h2>"
    print "<p class=\"legend\"><span class=\"sw\" style=\"background:#2563eb\"></span>канал" \
          "&nbsp; <span class=\"sw\" style=\"background:#94a3b8\"></span>порог отбора</p>"
    print "<svg viewBox=\"0 0 760 200\" xmlns=\"http://www.w3.org/2000/svg\">"
    printf "<polyline fill=\"none\" stroke=\"#2563eb\" stroke-width=\"2\" points=\"%s\"/>\n", poly(channel, n, max1)
    printf "<polyline fill=\"none\" stroke=\"#94a3b8\" stroke-width=\"2\" points=\"%s\"/>\n", poly(threshold, n, max1)
    print "</svg>"

    print "<h2>Ноды</h2>"
    print "<p class=\"legend\"><span class=\"sw\" style=\"background:#16a34a\"></span>нод выше порога" \
          "&nbsp; <span class=\"sw\" style=\"background:#f59e0b\"></span>победителей (в fast.yaml)</p>"
    print "<svg viewBox=\"0 0 760 200\" xmlns=\"http://www.w3.org/2000/svg\">"
    printf "<polyline fill=\"none\" stroke=\"#16a34a\" stroke-width=\"2\" points=\"%s\"/>\n", poly(good, n, max2)
    printf "<polyline fill=\"none\" stroke=\"#f59e0b\" stroke-width=\"2\" points=\"%s\"/>\n", poly(winners, n, max2)
    print "</svg>"

    printf "<p>Последний прогон (%s): канал %s МБ/с, порог %s МБ/с, живых %d из %d, отобрано %d.</p>\n", \
      esc(iso[n]), fmt_mb(channel[n]), fmt_mb(threshold[n]), alive[n], total[n], winners[n]
  }

  print "<h2>Последний замер</h2>"
  have_last = 0
  if (last != "") {
    while ((getline line < last) > 0) {
      split(line, f, "\t")
      if (f[1] == "") continue
      if (!have_last) {
        print "<table><tr><th>МБ/с</th><th>нода</th></tr>"
        have_last = 1
      }
      printf "<tr><td>%s</td><td>%s</td></tr>\n", esc(f[1]), esc(f[3])
    }
    close(last)
  }
  if (have_last) print "</table>"
  else print "<p>Нет данных последнего замера.</p>"
}
