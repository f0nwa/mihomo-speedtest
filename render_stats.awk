# render_stats.awk — собирает самодостаточную HTML-страницу со статистикой
# замеров speedtest2.sh: график числа нод по прогонам (с подписанными
# значениями по оси Y) и график скорости нод-победителей по прогонам (из
# speedtest_history.tsv) плюс таблица последнего замера (из
# speedtest_last.txt). Без внешних CSS/JS-зависимостей — чистый inline SVG.
# Вызывается из speedtest2.sh (render_stats()), на роутере напрямую не
# запускается.
#
# Использование:
#   awk -v last=PATH -v nodes=PATH -v generated="строка даты" -v cap=N \
#       -f render_stats.awk RUNS_TSV
# cap: сколько нод показывать на графике по нодам, 1..8 (см. NODE_CAP ниже);
#   необязателен, вне диапазона/не число - используется 8.
#
# RUNS_TSV (позиционный аргумент, может быть пустым файлом):
#   epoch<TAB>iso<TAB>channel_bytes<TAB>threshold_bytes<TAB>total<TAB>alive<TAB>tested<TAB>good<TAB>winners
# last: путь к speedtest_last.txt (строки "speed_MB<TAB>unit<TAB>name"),
#   необязателен — если не задан или не существует, таблица не выводится.
# nodes: путь к speedtest_history.tsv (строки "epoch<TAB>speed_bytes<TAB>имя"
#   по каждой ноде-победителю каждого прогона), необязателен — если не
#   задан, не существует или пуст, график по нодам не выводится. Показываются
#   не более NODE_CAP нод, отобранных по частоте побед (при равенстве — по
#   свежести последнего появления), остальные в график не попадают — иначе
#   при большом разнообразии побеждающих нод график станет нечитаемым.
#   Цвета линий — фиксированный порядок из 8 категориальных оттенков (массив
#   PAL ниже), подобранный так, чтобы соседние и произвольные пары из этого
#   набора оставались различимы при дальтонизме.

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

# render_node_history(path, run_n) — читает speedtest_history.tsv (path,
# может быть пустым/несуществующим) и печатает секцию с графиком скорости
# по нодам-победителям: не более NODE_CAP линий, отобранных по частоте
# побед (при равенстве — по свежести), с легендой, точками-подсказками
# (title при наведении) и разрывами линии там, где нода пропустила
# прогон(ы). Использует глобальные epoch[1..run_n]/iso[1..run_n] (уже
# заполнены основным телом скрипта) и глобальную палитру PAL[1..8].
function render_node_history(path, run_n,
    hline, hf, hn, i, j, k, nm,
    freq, last_seen, uniq, un, best, nb, nj, tmp, rank, topk,
    idx_of, hmax, left, top, w, h,
    p_idx, p_speed, pn, ix, x, y, seg, segn, prev_idx, col) {
  hn = 0
  if (path != "") {
    while ((getline hline < path) > 0) {
      split(hline, hf, "\t")
      if (hf[1] == "" || hf[3] == "") continue
      hn++
      h_epoch[hn] = hf[1] + 0
      h_speed[hn] = hf[2] + 0
      h_name[hn] = hf[3]
    }
    close(path)
  }

  if (hn == 0) {
    if (path != "") {
      print "<h2>Скорость нод-победителей по прогонам</h2>"
      print "<p>Нет истории по нодам.</p>"
    }
    return
  }

  for (i = 1; i <= run_n; i++) idx_of[epoch[i]] = i

  un = 0
  for (i = 1; i <= hn; i++) {
    nm = h_name[i]
    if (!(nm in freq)) { un++; uniq[un] = nm }
    freq[nm]++
    if (h_epoch[i] > last_seen[nm]) last_seen[nm] = h_epoch[i]
  }

  # сортировка выбором (набор невелик — не нужен встроенный sort awk)
  for (i = 1; i <= un; i++) {
    best = i
    for (j = i + 1; j <= un; j++) {
      nb = uniq[best]; nj = uniq[j]
      if (freq[nj] > freq[nb] || (freq[nj] == freq[nb] && last_seen[nj] > last_seen[nb])) best = j
    }
    if (best != i) { tmp = uniq[i]; uniq[i] = uniq[best]; uniq[best] = tmp }
  }

  topk = (un < NODE_CAP) ? un : NODE_CAP
  for (k = 1; k <= topk; k++) rank[uniq[k]] = k

  hmax = 1
  for (i = 1; i <= hn; i++) {
    nm = h_name[i]
    if ((nm in rank) && h_speed[i] > hmax) hmax = h_speed[i]
  }

  print "<h2>Скорость нод-победителей по прогонам</h2>"
  printf "<p class=\"legend\">показаны %d из %d нод (по частоте побед в fast.yaml):", topk, un
  for (k = 1; k <= topk; k++) {
    printf " <span class=\"sw\" style=\"background:%s\"></span>%s", PAL[k], esc(uniq[k])
  }
  print "</p>"

  left = 40; top = 10; w = 710; h = 170
  print "<svg viewBox=\"0 0 760 200\" xmlns=\"http://www.w3.org/2000/svg\">"
  printf "<line class=\"axis-line\" x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\"/>\n", left, top, left, top + h
  printf "<line class=\"axis-line\" x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\"/>\n", left, top + h, left + w, top + h
  printf "<text class=\"axis-text\" x=\"%d\" y=\"%d\" font-size=\"10\" text-anchor=\"end\">%s МБ/с</text>\n", left - 6, top + 4, fmt_mb(hmax)
  printf "<text class=\"axis-text\" x=\"%d\" y=\"%d\" font-size=\"10\" text-anchor=\"end\">0</text>\n", left - 6, top + h + 4

  for (k = 1; k <= topk; k++) {
    nm = uniq[k]
    col = PAL[k]
    pn = 0
    for (i = 1; i <= hn; i++) {
      if (h_name[i] != nm) continue
      if (!(h_epoch[i] in idx_of)) continue
      pn++
      p_idx[pn] = idx_of[h_epoch[i]]
      p_speed[pn] = h_speed[i]
    }

    seg = ""; segn = 0
    prev_idx = -1
    for (i = 1; i <= pn; i++) {
      ix = p_idx[i]
      if (prev_idx >= 0 && ix != prev_idx + 1 && segn > 0) {
        if (segn >= 2) printf "<polyline fill=\"none\" stroke=\"%s\" stroke-width=\"2\" points=\"%s\"/>\n", col, seg
        seg = ""; segn = 0
      }
      x = (run_n > 1) ? left + int((ix - 1) * w / (run_n - 1)) : left + int(w / 2)
      y = top + h - int(p_speed[i] * h / hmax)
      seg = seg x "," y " "; segn++
      prev_idx = ix
    }
    if (segn >= 2) printf "<polyline fill=\"none\" stroke=\"%s\" stroke-width=\"2\" points=\"%s\"/>\n", col, seg

    for (i = 1; i <= pn; i++) {
      ix = p_idx[i]
      x = (run_n > 1) ? left + int((ix - 1) * w / (run_n - 1)) : left + int(w / 2)
      y = top + h - int(p_speed[i] * h / hmax)
      printf "<circle cx=\"%d\" cy=\"%d\" r=\"3\" fill=\"%s\" stroke=\"#fff\" stroke-width=\"1\"><title>%s · %s МБ/с · %s</title></circle>\n", \
        x, y, col, esc(iso[ix]), fmt_mb(p_speed[i]), esc(nm)
    }
  }
  print "</svg>"
}

BEGIN {
  FS = "\t"
  n = 0
  # cap приходит снаружи (-v cap=...) из STATS_NODE_CAP в speedtest2.env;
  # некорректное/пустое/вне диапазона значение -> дефолт 8 (столько цветов в PAL).
  NODE_CAP = (cap + 0 >= 1 && cap + 0 <= 8) ? cap + 0 : 8
  PAL[1] = "#2a78d6"; PAL[2] = "#eb6834"; PAL[3] = "#1baf7a"; PAL[4] = "#eda100"
  PAL[5] = "#e87ba4"; PAL[6] = "#008300"; PAL[7] = "#4a3aa7"; PAL[8] = "#e34948"
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
  max2 = 1
  for (i = 1; i <= n; i++) {
    if (good[i] > max2) max2 = good[i]
    if (winners[i] > max2) max2 = winners[i]
  }

  print "<!doctype html><meta charset=\"utf-8\">"
  print "<title>speedtest2 - статистика</title>"
  print "<style>"
  print ":root{--bg:#f5f6f8;--card:#ffffff;--text:#1b1f24;--muted:#666666;--border:#e2e2e2}"
  print "@media (prefers-color-scheme: dark){:root{--bg:#14161a;--card:#1d2025;--text:#e7e9ec;--muted:#9aa0a6;--border:#2c3038}}"
  print ":root[data-theme=\"light\"]{--bg:#f5f6f8;--card:#ffffff;--text:#1b1f24;--muted:#666666;--border:#e2e2e2}"
  print ":root[data-theme=\"dark\"]{--bg:#14161a;--card:#1d2025;--text:#e7e9ec;--muted:#9aa0a6;--border:#2c3038}"
  print "*{box-sizing:border-box}"
  print "body{font:14px/1.5 -apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,sans-serif;margin:0;background:var(--bg);color:var(--text)}"
  print ".wrap{max-width:820px;margin:0 auto;padding:20px 16px 40px}"
  print "header{display:flex;align-items:flex-start;justify-content:space-between;gap:12px;margin-bottom:16px}"
  print "h1{font-size:19px;margin:0}"
  print ".meta{color:var(--muted);font-size:12.5px;margin:2px 0 0}"
  print ".theme-btn{border:1px solid var(--border);background:var(--card);color:var(--text);border-radius:8px;padding:6px 10px;font-size:13px;cursor:pointer;flex:0 0 auto}"
  print ".card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:14px 16px;margin-bottom:16px}"
  print "h2{font-size:14.5px;margin:0 0 8px}"
  print "svg{max-width:100%;height:auto;display:block;margin-bottom:8px}"
  print ".axis-line{stroke:var(--border)}"
  print ".axis-text{fill:var(--muted)}"
  print "table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}"
  print "td,th{padding:4px 10px;text-align:right;border-bottom:1px solid var(--border)}"
  print "th{color:var(--muted);font-weight:600}"
  print "th:last-child,td:last-child{text-align:left}"
  print ".legend{font-size:12px;color:var(--muted);margin:0 0 8px}"
  print ".sw{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:4px;vertical-align:-1px}"
  print "</style>"
  print "<div class=\"wrap\">"
  print "<header>"
  print "<div><h1>Статистика speedtest2</h1><p class=\"meta\">Сгенерировано: " esc(generated) " · прогонов в истории: " n "</p></div>"
  print "<div style=\"display:flex;gap:8px;flex:0 0 auto\">"
  print "<a class=\"theme-btn\" href=\"cgi-bin/config\">Настройки</a>"
  print "<button class=\"theme-btn\" id=\"themeBtn\" type=\"button\">Тема</button>"
  print "</div>"
  print "</header>"

  if (n == 0) {
    print "<div class=\"card\"><p>Пока нет ни одного прогона в истории.</p></div>"
  } else {
    print "<div class=\"card\">"
    print "<h2>Ноды</h2>"
    print "<p class=\"legend\"><span class=\"sw\" style=\"background:#16a34a\"></span>нод выше порога" \
          "&nbsp; <span class=\"sw\" style=\"background:#f59e0b\"></span>победителей (в fast.yaml)</p>"
    print "<svg viewBox=\"0 0 760 200\" xmlns=\"http://www.w3.org/2000/svg\">"
    printf "<line class=\"axis-line\" x1=\"40\" y1=\"10\" x2=\"40\" y2=\"180\"/>\n"
    printf "<line class=\"axis-line\" x1=\"40\" y1=\"180\" x2=\"750\" y2=\"180\"/>\n"
    printf "<text class=\"axis-text\" x=\"34\" y=\"14\" font-size=\"10\" text-anchor=\"end\">%d</text>\n", max2
    printf "<text class=\"axis-text\" x=\"34\" y=\"184\" font-size=\"10\" text-anchor=\"end\">0</text>\n"
    printf "<polyline fill=\"none\" stroke=\"#16a34a\" stroke-width=\"2\" points=\"%s\"/>\n", poly(good, n, max2)
    printf "<polyline fill=\"none\" stroke=\"#f59e0b\" stroke-width=\"2\" points=\"%s\"/>\n", poly(winners, n, max2)
    print "</svg>"
    printf "<p>Последний прогон (%s): канал %s МБ/с, порог %s МБ/с, живых %d из %d, отобрано %d.</p>\n", \
      esc(iso[n]), fmt_mb(channel[n]), fmt_mb(threshold[n]), alive[n], total[n], winners[n]
    print "</div>"

    if (nodes != "") {
      print "<div class=\"card\">"
      render_node_history(nodes, n)
      print "</div>"
    }
  }

  print "<div class=\"card\">"
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
  print "</div>"
  print "</div>"
  print "<script>"
  print "(function(){"
  print "var KEY='speedtest2-theme';"
  print "var root=document.documentElement;"
  print "var btn=document.getElementById('themeBtn');"
  print "function label(){var cur=root.getAttribute('data-theme');btn.textContent=cur==='dark'?'Светлая тема':cur==='light'?'Тёмная тема':'Тема: авто';}"
  print "function apply(t){if(t){root.setAttribute('data-theme',t);}else{root.removeAttribute('data-theme');}label();}"
  print "var saved=null;"
  print "try{saved=localStorage.getItem(KEY);}catch(e){}"
  print "apply(saved);"
  print "btn.addEventListener('click',function(){"
  print "var cur=root.getAttribute('data-theme');"
  print "var next=cur==='dark'?'light':cur==='light'?null:'dark';"
  print "apply(next);"
  print "try{if(next){localStorage.setItem(KEY,next);}else{localStorage.removeItem(KEY);}}catch(e){}"
  print "});"
  print "})();"
  print "</script>"
}
