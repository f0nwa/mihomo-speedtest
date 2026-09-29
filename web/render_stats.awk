# render_stats.awk - собирает stats.json для /api/stats веб-интерфейса
# (см. маршрут "api/stats" в stats_httpd.py и renderStats() в
# stats_app.js): история прогонов, последний прогон и замер, скорость
# нод-победителей по прогонам и доступность нод пула. Отдаются только
# сырые данные (скорости в байтах/с), всё отображение - на стороне
# браузера. Вызывается из speedtest2.sh (render_stats()), на роутере
# напрямую не запускается.
#
# До 2026-09-28 скрипт по умолчанию собирал ещё и самодостаточную
# HTML-страницу stats.html (inline SVG), а JSON включался флагом
# -v format=json. Страница удалена вместе с остальным старым
# HTML-интерфейсом; флаг format больше ни на что не влияет и
# принимается только ради совместимости с вызовами старых версий.
#
# Использование:
#   awk -v last=PATH -v nodes=PATH -v stability=PATH -v generated="строка даты" \
#       -v cap=N -f render_stats.awk RUNS_TSV
# cap: сколько нод графика по нодам показывать сразу, 1..50 (см. NODE_CAP
#   ниже); необязателен, вне диапазона/не число - используется 8.
#
# RUNS_TSV (позиционный аргумент, может быть пустым файлом):
#   epoch<TAB>iso<TAB>channel_bytes<TAB>threshold_bytes<TAB>total<TAB>alive<TAB>tested<TAB>good<TAB>winners
# last: путь к speedtest_last.txt (строки "speed_MB<TAB>unit<TAB>name"),
#   необязателен - если не задан или не существует, last_measurement пуст.
# nodes: путь к speedtest_history.tsv (строки "epoch<TAB>speed_bytes<TAB>имя"
#   по каждой ноде-победителю каждого прогона), необязателен. В node_history
#   попадают ВСЕ ноды истории, отсортированные по частоте побед (при
#   равенстве - по свежести последнего появления); cap - сколько первых из
#   них браузер показывает сразу, остальные включаются в легенде графика.
#   Цвета линий: первые 8 - фиксированный порядок категориальных оттенков
#   (массив PAL ниже), подобранный так, чтобы пары оставались различимы
#   при дальтонизме; дальше - шаг «золотого угла» по кругу оттенков
#   (hsl), чтобы палитра не заканчивалась.
# stability: путь к node_stability.tsv - доступность ВСЕХ нод пула (не
#   только победителей): статус на последнем прогоне, uptime и история за
#   окно (по групповому delay-check, весь пул каждый прогон), последняя и
#   средняя скорость (по speed-тесту, проходят не все ноды каждый прогон -
#   поэтому у части «живых» нод скорости может не быть). Строки
#   отсортированы по убыванию uptime за окно.

# join_series_values(p_idx, p_speed, pn, run_n) - плотный JSON-массив
# длиной run_n для одной линии графика по нодам: p_idx[1..pn]/p_speed[1..pn]
# (уже отсортированы по возрастанию run-индекса) сливаются с индексами
# 1..run_n; там, где нода прогон пропустила, подставляется null (график
# в stats_app.js рисует на этом месте разрыв линии).
function join_series_values(p_idx, p_speed, pn, run_n,   i, j, out) {
  out = ""
  j = 1
  for (i = 1; i <= run_n; i++) {
    out = out (i > 1 ? "," : "")
    if (j <= pn && p_idx[j] == i) {
      out = out (p_speed[j] + 0)
      j++
    } else {
      out = out "null"
    }
  }
  return out
}

# json_esc(s) - экранирование строки для JSON: обратный слеш, двойная
# кавычка и управляющие \n/\r/\t. HTML-сущности НЕ добавляются -
# потребитель JSON (JSON.parse) ожидает сырую строку, а экранирует при
# выводе сам браузерный код (textContent).
function json_esc(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s)
  gsub(/\r/, "\\r", s)
  gsub(/\n/, "\\n", s)
  return s
}

function json_str(s) {
  return "\"" json_esc(s) "\""
}

# json_num_or_null(v, has) - число как есть, если has истинно (ненулевое),
# иначе JSON null - для полей вроде средней скорости, которых может не
# быть (нода ни разу не проходила speed-тест).
function json_num_or_null(v, has) {
  return has ? (v + 0) : "null"
}

# json_last(path) - "Последний замер" (speedtest_last.txt: speed_MB<TAB>unit<TAB>имя,
# см. шапку файла) как JSON-массив объектов. Поле speed уже в МБ/с текстом
# в самом файле (так его пишет speedtest2.sh, full.txt) - единственное
# поле во всём JSON-выводе не в байтах.
function json_last(path,   line, f, first, out) {
  out = "["
  first = 1
  if (path != "") {
    while ((getline line < path) > 0) {
      split(line, f, "\t")
      if (f[1] == "") continue
      if (!first) out = out ","
      first = 0
      out = out "{\"speed_mb\":" (f[1] + 0) ",\"unit\":" json_str(f[2]) ",\"name\":" json_str(f[3]) "}"
    }
    close(path)
  }
  out = out "]"
  return out
}

# node_color(k) - цвет k-й ноды графика (см. описание nodes в шапке).
function node_color(k) {
  if (k <= 8) return PAL[k]
  return "hsl(" (int((k - 1) * 137.508) % 360) ", " ((k % 2) ? "62%, 62%" : "55%, 72%") ")"
}

# json_node_history(path, run_n) - все ноды-победители по частоте
# побед (при равенстве - по свежести последнего появления), с плотным по
# прогонам массивом скорости в байтах (null там, где нода прогон
# пропустила). Отбор и порядок - см. описание nodes в шапке файла.
function json_node_history(path, run_n,
    hline, hf, hn, i, j, k, nm,
    freq, last_seen, uniq, un, best, nb, nj, tmp, rank, topk,
    idx_of, p_idx, p_speed, pn, out) {
  hn = 0
  if (path != "") {
    while ((getline hline < path) > 0) {
      split(hline, hf, "\t")
      if (hf[1] == "" || hf[3] == "") continue
      hn++
      h_epoch2[hn] = hf[1] + 0
      h_speed2[hn] = hf[2] + 0
      h_name2[hn] = hf[3]
    }
    close(path)
  }

  if (hn == 0) return "{\"total_unique\":0,\"cap\":" NODE_CAP ",\"top\":[]}"

  for (i = 1; i <= run_n; i++) idx_of[epoch[i]] = i

  un = 0
  for (i = 1; i <= hn; i++) {
    nm = h_name2[i]
    if (!(nm in freq)) { un++; uniq[un] = nm }
    freq[nm]++
    if (h_epoch2[i] > last_seen[nm]) last_seen[nm] = h_epoch2[i]
  }

  for (i = 1; i <= un; i++) {
    best = i
    for (j = i + 1; j <= un; j++) {
      nb = uniq[best]; nj = uniq[j]
      if (freq[nj] > freq[nb] || (freq[nj] == freq[nb] && last_seen[nj] > last_seen[nb])) best = j
    }
    if (best != i) { tmp = uniq[i]; uniq[i] = uniq[best]; uniq[best] = tmp }
  }

  topk = un

  out = "{\"total_unique\":" un ",\"cap\":" NODE_CAP ",\"top\":["
  for (k = 1; k <= topk; k++) {
    nm = uniq[k]
    pn = 0
    for (i = 1; i <= hn; i++) {
      if (h_name2[i] != nm) continue
      if (!(h_epoch2[i] in idx_of)) continue
      pn++
      p_idx[pn] = idx_of[h_epoch2[i]]
      p_speed[pn] = h_speed2[i]
    }
    out = out (k > 1 ? "," : "") "{\"name\":" json_str(nm) ",\"wins\":" freq[nm] \
      ",\"color\":" json_str(node_color(k)) ",\"values\":[" join_series_values(p_idx, p_speed, pn, run_n) "]}"
  }
  out = out "]}"
  return out
}

# json_node_stability(path) - "Статистика доступности нод" (node_stability.tsv),
# отсортированная по убыванию uptime за окно (см. описание stability в
# шапке файла); историю за окно клиент при желании нарисует сам по полю
# "window".
function json_node_stability(path,
    line, f, nf, cnt, i, j, k, best, tmp, order,
    name, win, wlen, ch, status, pctv, has_avg, avg_speed, delta,
    alive_n, total_n, out) {
  cnt = 0
  if (path != "") {
    while ((getline line < path) > 0) {
      nf = split(line, f, "\t")
      if (f[1] == "" || nf < 10) continue
      cnt++
      s_name[cnt] = f[1]
      s_first[cnt] = f[2]
      s_last_seen[cnt] = f[3]
      s_window[cnt] = f[10]
      s_last_speed[cnt] = f[11] + 0
      s_speed_sum[cnt] = f[12] + 0
      s_speed_samples[cnt] = f[13] + 0
    }
    close(path)
  }

  if (cnt == 0) return "[]"

  for (i = 1; i <= cnt; i++) {
    win = s_window[i]
    wlen = length(win)
    alive_n = 0; total_n = 0
    for (k = 1; k <= wlen; k++) {
      ch = substr(win, k, 1)
      if (ch == "A") { alive_n++; total_n++ }
      else if (ch == "D") total_n++
    }
    s_pct[i] = (total_n > 0) ? int(alive_n * 100 / total_n + 0.5) : -1
  }

  for (i = 1; i <= cnt; i++) order[i] = i
  for (i = 1; i <= cnt; i++) {
    best = i
    for (j = i + 1; j <= cnt; j++) {
      if (s_pct[order[j]] > s_pct[order[best]]) best = j
    }
    if (best != i) { tmp = order[i]; order[i] = order[best]; order[best] = tmp }
  }

  out = "["
  for (i = 1; i <= cnt; i++) {
    k = order[i]
    name = s_name[k]
    win = s_window[k]
    wlen = length(win)
    ch = (wlen > 0) ? substr(win, wlen, 1) : "."
    status = (ch == "A") ? "alive" : (ch == "D") ? "down" : (ch == "S") ? "skipped" : "absent"
    pctv = s_pct[k]

    has_avg = (s_speed_samples[k] > 0)
    if (has_avg) {
      avg_speed = s_speed_sum[k] / s_speed_samples[k]
      delta = s_last_speed[k] - avg_speed
    }

    out = out (i > 1 ? "," : "") "{\"name\":" json_str(name) \
      ",\"first_seen\":" json_str(s_first[k]) \
      ",\"last_seen\":" json_str(s_last_seen[k]) \
      ",\"status\":\"" status "\"" \
      ",\"uptime_pct\":" (pctv >= 0 ? pctv : "null") \
      ",\"window\":" json_str(win) \
      ",\"avg_speed_bytes\":" json_num_or_null(avg_speed, has_avg) \
      ",\"last_speed_bytes\":" (s_last_speed[k] + 0) \
      ",\"delta_bytes\":" json_num_or_null(delta, has_avg) "}"
  }
  out = out "]"
  return out
}

# render_json() - собирает и печатает один JSON-объект целиком (см. шапку
# файла). Использует уже заполненные основным телом скрипта глобальные
# epoch[1..n]/iso[1..n]/channel[1..n]/threshold[1..n]/total[1..n]/
# alive[1..n]/tested[1..n]/good[1..n]/winners[1..n].
function render_json(   i) {
  print "{"
  printf "\"generated\":%s,\n", json_str(generated)
  printf "\"runs\":{\"count\":%d,\"series\":[", n
  for (i = 1; i <= n; i++) {
    printf "%s{\"epoch\":%d,\"iso\":%s,\"channel_bytes\":%d,\"threshold_bytes\":%d,\"total\":%d,\"alive\":%d,\"tested\":%d,\"good\":%d,\"winners\":%d}", \
      (i > 1 ? "," : ""), epoch[i], json_str(iso[i]), channel[i], threshold[i], total[i], alive[i], tested[i], good[i], winners[i]
  }
  print "]},"
  if (n > 0) {
    printf "\"last_run\":{\"iso\":%s,\"channel_bytes\":%d,\"threshold_bytes\":%d,\"alive\":%d,\"total\":%d,\"winners\":%d},\n", \
      json_str(iso[n]), channel[n], threshold[n], alive[n], total[n], winners[n]
  } else {
    print "\"last_run\":null,"
  }
  printf "\"last_measurement\":%s,\n", json_last(last)
  printf "\"node_history\":%s,\n", json_node_history(nodes, n)
  printf "\"node_stability\":%s\n", json_node_stability(stability)
  print "}"
}


BEGIN {
  FS = "\t"
  n = 0
  # cap приходит снаружи (-v cap=...) из STATS_NODE_CAP в speedtest2.env;
  # некорректное/пустое/вне диапазона значение -> дефолт 8.
  NODE_CAP = (cap + 0 >= 1 && cap + 0 <= 50) ? cap + 0 : 8
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
  render_json()
}
