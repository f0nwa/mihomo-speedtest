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
  gsub(/"/, "\\&quot;", s)
  return s
}

function fmt_mb(bytes,   mb, frac) {
  mb = int(bytes / 1048576)
  frac = int((bytes % 1048576) * 10 / 1048576)
  return mb "." frac
}

# fmt_mb_signed(bytes) - как fmt_mb(), но с явным знаком (+/-) спереди;
# нужно для дельты скорости в таблице "Доступность нод пула" (delta
# бывает и отрицательной - нода сейчас медленнее своего среднего).
function fmt_mb_signed(bytes,   ab) {
  ab = (bytes < 0) ? -bytes : bytes
  return (bytes < 0 ? "-" : "+") fmt_mb(ab)
}

# jsesc(s) — экранирование строки для встраивания в JS-строковый литерал
# (двойные кавычки уже используются снаружи вызовов). Управляющие символы
# перевода строки/возврата каретки убираются - в наших данных (iso-метки
# времени) их не бывает, но на всякий случай не должны ломать <script>.
function jsesc(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\r/, "", s)
  gsub(/\n/, " ", s)
  return s
}

# join_num(arr, cnt) — числа arr[1..cnt] через запятую, для JS-массива.
function join_num(arr, cnt,   i, out) {
  out = ""
  for (i = 1; i <= cnt; i++) out = out (i > 1 ? "," : "") (arr[i] + 0)
  return out
}

# join_str_js(arr, cnt) — строки arr[1..cnt] через запятую, каждая в
# кавычках, для JS-массива. Экранируется дважды: сперва esc() (HTML) - эти
# строки потом вставляются в тултип через innerHTML, затем jsesc() (сам
# JS-строковый литерал) - без первого esc() спецсимволы имени ноды могли
# бы быть интерпретированы как HTML-разметка после innerHTML.
function join_str_js(arr, cnt,   i, out) {
  out = ""
  for (i = 1; i <= cnt; i++) out = out (i > 1 ? "," : "") "\"" jsesc(esc(arr[i])) "\""
  return out
}

# join_series_values(p_idx, p_speed, pn, run_n) — плотный JS-массив
# длиной run_n для одной линии графика по нодам: p_idx[1..pn]/p_speed[1..pn]
# (уже отсортированы по возрастанию run-индекса — так же, как их использует
# отрисовка разрывов линии) сливаются с индексами 1..run_n; там, где нода
# прогон пропустила, подставляется JS "null" (проверяется в initChart()).
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

# fmt_date_short(iso) — "YYYY-MM-DD HH:MM:SS" -> "DD.MM"
function fmt_date_short(s) {
  return substr(s, 9, 2) "." substr(s, 6, 2)
}

# fmt_time_short(iso) — "YYYY-MM-DD HH:MM:SS" -> "HH:MM"
function fmt_time_short(s) {
  return substr(s, 12, 5)
}

# render_x_axis_dates(left, top, w, h, run_n) — динамический таймлайн под
# графиком: 2..6 подписей (по числу прогонов), позиции - как у точек на
# графике (равномерно по индексу прогона, см. poly()/x в
# render_node_history() - настоящий график тоже не привязан к реальным
# интервалам времени, только к порядку прогонов). Если все выбранные
# метки попадают на один календарный день - показывается время (HH:MM,
# так полезнее при частых прогонах за день), иначе - дата (DD.MM).
# Крайние подписи прижаты к краям графика (text-anchor start/end), чтобы
# не вылезать за viewBox.
function render_x_axis_dates(left, top, w, h, run_n,
    tn, i, idx, prev_idx, x, anchor_pos, same_day, day1, lbl) {
  if (run_n < 2) return
  tn = (run_n < 6) ? run_n : 6
  same_day = 1
  day1 = substr(iso[1], 1, 10)
  for (i = 1; i <= run_n; i++) {
    if (substr(iso[i], 1, 10) != day1) { same_day = 0; break }
  }
  prev_idx = -1
  for (i = 0; i < tn; i++) {
    idx = 1 + int(i * (run_n - 1) / (tn - 1) + 0.5)
    if (idx < 1) idx = 1
    if (idx > run_n) idx = run_n
    if (idx == prev_idx) continue
    prev_idx = idx
    x = (run_n > 1) ? left + int((idx - 1) * w / (run_n - 1)) : left + int(w / 2)
    anchor_pos = (i == 0) ? "start" : (i == tn - 1) ? "end" : "middle"
    lbl = same_day ? fmt_time_short(iso[idx]) : fmt_date_short(iso[idx])
    printf "<line class=\"axis-tick\" x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\"/>\n", x, top + h, x, top + h + 4
    printf "<text class=\"axis-text\" x=\"%d\" y=\"%d\" font-size=\"10\" text-anchor=\"%s\">%s</text>\n", x, top + h + 15, anchor_pos, esc(lbl)
  }
}

# sort_num(arr, cnt) — сортировка arr[1..cnt] по возрастанию на месте
# (вставками — наборы небольшие, встроенной sort в POSIX awk нет).
function sort_num(arr, cnt,   i, j, key) {
  for (i = 2; i <= cnt; i++) {
    key = arr[i]
    j = i - 1
    while (j >= 1 && arr[j] > key) {
      arr[j + 1] = arr[j]
      j--
    }
    arr[j + 1] = key
  }
}

# percentile(sorted_arr, cnt, p) — p-й процентиль (0..100) методом
# "ближайшего ранга" по уже отсортированному по возрастанию массиву.
function percentile(arr, cnt, p,   idx) {
  if (cnt <= 0) return 0
  idx = int((p / 100) * cnt + 0.9999999)
  if (idx < 1) idx = 1
  if (idx > cnt) idx = cnt
  return arr[idx]
}

# fmt_stat_val(v, mode) — mode="mb": байты в "X.Y МБ/с" через fmt_mb();
# иначе (mode="int") — целое число как есть (счётчики нод).
function fmt_stat_val(v, mode) {
  return (mode == "mb") ? (fmt_mb(v) " МБ/с") : (v + 0)
}

# stat_row_html(name, sw_cls, mode, vals, cnt) — печатает одну группу
# статистики (Мин/Р95/Макс/Сейчас) по значениям vals[1..cnt]. sw_cls -
# класс цветного квадратика легенды (sw-good/sw-winners/...), пустая
# строка — без квадратика (для агрегата "по всем нодам вместе").
# "Сейчас" — vals[cnt], последнее по порядку значение (для графика
# "Ноды" это последний прогон; для агрегата по нодам-победителям —
# порядок добавления в history.tsv совпадает с хронологическим, как и
# везде в этом файле, так что тоже самое свежее значение).
function stat_row_html(name, sw_cls, mode, vals, cnt,   tmp, i, mn, mx, p95, cur, label) {
  for (i = 1; i <= cnt; i++) tmp[i] = vals[i]
  sort_num(tmp, cnt)
  mn = tmp[1]; mx = tmp[cnt]
  p95 = percentile(tmp, cnt, 95)
  cur = vals[cnt]
  label = (sw_cls != "") ? ("<span class=\"sw " sw_cls "\"></span>" esc(name)) : esc(name)
  printf "<div class=\"stat-group\"><span class=\"stat-label\">%s</span>" \
    "<span class=\"stat\">Мин <b>%s</b></span><span class=\"stat\" title=\"95-й процентиль: 95%% замеров были не выше этого значения — устойчивая оценка «почти максимума» без случайных выбросов\">Р95 <b>%s</b></span>" \
    "<span class=\"stat\">Макс <b>%s</b></span><span class=\"stat\">Сейчас <b>%s</b></span></div>\n", \
    label, fmt_stat_val(mn, mode), fmt_stat_val(p95, mode), fmt_stat_val(mx, mode), fmt_stat_val(cur, mode)
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
    p_idx, p_speed, pn, ix, x, y, seg, segn, prev_idx, col, series_json,
    allspeed, acnt) {
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
  acnt = 0
  for (i = 1; i <= hn; i++) {
    nm = h_name[i]
    if (!(nm in rank)) continue
    if (h_speed[i] > hmax) hmax = h_speed[i]
    # копим скорость всех показанных нод вместе (порядок совпадает с
    # хронологическим - как и везде в history.tsv) для строки
    # Мин/Р95/Макс/Сейчас под графиком (агрегат, без привязки к линии).
    acnt++
    allspeed[acnt] = h_speed[i]
  }

  print "<h2>Скорость нод-победителей по прогонам</h2>"
  printf "<p class=\"legend\">показаны %d из %d нод (по частоте побед в fast.yaml):", topk, un
  for (k = 1; k <= topk; k++) {
    printf " <span class=\"sw\" style=\"background:%s\"></span>%s", PAL[k], esc(uniq[k])
  }
  print "</p>"

  left = 40; top = 10; w = 710; h = 170
  print "<div class=\"chart-wrap\">"
  print "<svg id=\"svg-hist\" viewBox=\"0 0 760 214\" xmlns=\"http://www.w3.org/2000/svg\">"
  printf "<line class=\"axis-line\" x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\"/>\n", left, top, left, top + h
  printf "<line class=\"axis-line\" x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\"/>\n", left, top + h, left + w, top + h
  printf "<text class=\"axis-text\" x=\"%d\" y=\"%d\" font-size=\"10\" text-anchor=\"end\">%s МБ/с</text>\n", left - 6, top + 4, fmt_mb(hmax)
  printf "<text class=\"axis-text\" x=\"%d\" y=\"%d\" font-size=\"10\" text-anchor=\"end\">0</text>\n", left - 6, top + h + 4
  render_x_axis_dates(left, top, w, h, run_n)

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

    printf "<g class=\"node-series\" id=\"series-hist-n%d\">\n", k

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
      printf "<circle class=\"node-dot\" cx=\"%d\" cy=\"%d\" r=\"3\" fill=\"%s\" stroke-width=\"1\"><title>%s · %s МБ/с · %s</title></circle>\n", \
        x, y, col, esc(iso[ix]), fmt_mb(p_speed[i]), esc(nm)
    }
    print "</g>"

    series_json[k] = "{id:\"n" k "\",name:\"" jsesc(esc(nm)) "\",color:\"" col "\",values:[" join_series_values(p_idx, p_speed, pn, run_n) "]}"
  }

  print "<line class=\"crosshair-line\" id=\"crosshair-hist\" x1=\"40\" y1=\"10\" x2=\"40\" y2=\"180\" visibility=\"hidden\"/>"
  for (k = 1; k <= topk; k++) {
    printf "<circle class=\"crosshair-dot\" id=\"dot-hist-n%d\" r=\"3.5\" fill=\"%s\" visibility=\"hidden\"/>\n", k, PAL[k]
  }
  print "<rect class=\"chart-capture\" id=\"capture-hist\" x=\"40\" y=\"10\" width=\"710\" height=\"170\"/>"
  print "</svg>"
  print "<div class=\"tooltip\" id=\"tooltip-hist\" hidden></div>"
  print "</div>"
  printf "<script>window.STATS_CHARTS=window.STATS_CHARTS||{};STATS_CHARTS.hist={left:%d,top:%d,w:%d,h:%d,n:%d,max:%d,unit:\"mb\",highlight:true,labels:[%s],series:[", \
    left, top, w, h, run_n, hmax, join_str_js(iso, run_n)
  for (k = 1; k <= topk; k++) printf "%s%s", (k > 1 ? "," : ""), series_json[k]
  print "]};</script>"
  print "<div class=\"stats-row\">"
  stat_row_html("все показанные ноды", "", "mb", allspeed, acnt)
  print "</div>"
}

# sparkline(win) - печатает строку из <span> на каждый символ window
# (A/D/.) для компактной визуализации истории ноды без SVG.
function sparkline(win,   i, ch, out, cls) {
  out = ""
  for (i = 1; i <= length(win); i++) {
    ch = substr(win, i, 1)
    cls = (ch == "A") ? "hist-ok" : (ch == "D") ? "hist-bad" : "hist-gap"
    out = out "<span class=\"" cls "\"></span>"
  }
  return out
}

# render_node_stability(path) - читает node_stability.tsv (path, может
# быть пустым/несуществующим) и печатает таблицу доступности ВСЕХ нод
# пула (не только победителей): статус на последнем прогоне, uptime за
# окно (по delay-check), спарклайн, отклонение последней измеренной
# скорости от собственного среднего этой ноды (Δ скорости), дату первого
# появления. Статус/uptime/спарклайн - из group delay-check (шаг 4
# main(), весь пул каждый прогон); средняя скорость (в скобках -
# отклонение последнего замера от неё) - из speed-теста (шаг 5,
# проходят не все ноды каждый прогон, см. ENOUGH в speedtest2.sh),
# поэтому у части нод может стоять «-», даже если они «живы» по задержке.
# Строки отсортированы по убыванию uptime за окно; клик-сортировка по
# любой колонке - в <script> в конце страницы.
function render_node_stability(path,
    line, f, nf, cnt, i, j, k, best, tmp, order,
    name, win, wlen, ch, cls, label, srt, pctv, avg_speed, delta, delta_cls,
    dv, dtxt, alive_n, total_n) {
  cnt = 0
  if (path != "") {
    while ((getline line < path) > 0) {
      nf = split(line, f, "\t")
      if (f[1] == "" || nf < 10) continue
      cnt++
      st_name[cnt] = f[1]
      st_first[cnt] = f[2]
      st_window[cnt] = f[10]
      st_last_speed[cnt] = f[11] + 0
      st_speed_sum[cnt] = f[12] + 0
      st_speed_samples[cnt] = f[13] + 0
    }
    close(path)
  }

  print "<h2>Доступность нод пула</h2>"
  print "<p class=\"legend\">статус, uptime и спарклайн - по проверке задержки (delay-check) каждого прогона, весь пул; средняя скорость - среднее всех замеров ноды, в скобках отклонение последнего замера от этого среднего; только у нод, хоть раз прошедших speed-тест (проходят не все ноды каждый прогон); серый индикатор и статус «нет в пуле» - нода сейчас не в пуле подписки.</p>"

  if (cnt == 0) {
    print "<p>Нет данных о стабильности нод.</p>"
    return
  }

  for (i = 1; i <= cnt; i++) {
    win = st_window[i]
    wlen = length(win)
    alive_n = 0; total_n = 0
    for (k = 1; k <= wlen; k++) {
      ch = substr(win, k, 1)
      if (ch == "A") { alive_n++; total_n++ }
      else if (ch == "D") total_n++
    }
    st_pct[i] = (total_n > 0) ? int(alive_n * 100 / total_n + 0.5) : -1
  }

  # сортировка по убыванию uptime за окно (набор невелик - выбором, как и везде в этом файле)
  for (i = 1; i <= cnt; i++) order[i] = i
  for (i = 1; i <= cnt; i++) {
    best = i
    for (j = i + 1; j <= cnt; j++) {
      if (st_pct[order[j]] > st_pct[order[best]]) best = j
    }
    if (best != i) { tmp = order[i]; order[i] = order[best]; order[best] = tmp }
  }

  print "<div class=\"table-scroll\">"
  print "<table id=\"stability-table\"><thead><tr>" \
        "<th data-sort=\"str\" data-col=\"0\">Нода</th>" \
        "<th data-sort=\"num\" data-col=\"1\">Сейчас</th>" \
        "<th data-sort=\"num\" data-col=\"2\">Uptime (окно)</th>" \
        "<th data-sort=\"none\" data-col=\"3\">Спарклайн</th>" \
        "<th data-sort=\"num\" data-col=\"4\">Средняя скорость</th>" \
        "<th data-sort=\"str\" data-col=\"5\">Впервые замечена</th>" \
        "</tr></thead><tbody>"

  for (i = 1; i <= cnt; i++) {
    k = order[i]
    name = st_name[k]
    win = st_window[k]
    wlen = length(win)
    ch = (wlen > 0) ? substr(win, wlen, 1) : "."
    if (ch == "A") { cls = "st-ok"; label = "жива"; srt = 2 }
    else if (ch == "D") { cls = "st-bad"; label = "не отвечает"; srt = 1 }
    else { cls = "st-gap"; label = "нет в пуле"; srt = 0 }

    pctv = st_pct[k]
    if (st_speed_samples[k] > 0) {
      avg_speed = st_speed_sum[k] / st_speed_samples[k]
      delta = st_last_speed[k] - avg_speed
      delta_cls = (delta > 0) ? "delta-pos" : (delta < 0) ? "delta-neg" : ""
      dv = avg_speed
      dtxt = fmt_mb(avg_speed) " МБ/с <span class=\"" delta_cls "\">(" fmt_mb_signed(delta) ")</span>"
    } else {
      dv = -1
      dtxt = "-"
    }

    printf "<tr><td data-v=\"%s\">%s</td>", jsesc(esc(name)), esc(name)
    printf "<td data-v=\"%d\"><span class=\"dot %s\"></span>%s</td>", srt, cls, label
    printf "<td data-v=\"%d\">%s</td>", pctv, (pctv >= 0 ? pctv "%" : "-")
    printf "<td data-v=\"0\">%s</td>", sparkline(win)
    printf "<td data-v=\"%d\">%s</td>", dv, dtxt
    printf "<td data-v=\"%s\">%s</td>", jsesc(esc(st_first[k])), esc(st_first[k])
    print "</tr>"
  }
  print "</tbody></table>"
  print "</div>"
}

# ==========================================================================
# JSON-режим (добавлено 2026-09-12, см. docs/plans/2026-09-12-web-spa-migration-design.md,
# шаг 2). Включается флагом -v format=json; по умолчанию (format не задан
# или не "json") ничего в этом разделе не выполняется, HTML-режим ниже не
# затронут. В отличие от HTML-режима, здесь отдаются только сырые данные
# (в байтах, без форматирования под МБ/с и без построения SVG/таблиц) -
# рендеринг для JSON-потребителя (см. app.js, шаг 4) остаётся на стороне
# клиента.
#
# Код отбора/сортировки нод в json_node_history()/json_node_stability()
# намеренно продублирован из render_node_history()/render_node_stability(),
# а не вынесен в общие функции - см. design-док: JSON-режим не должен
# рисковать сломать хорошо протестированный HTML-путь при рефакторинге
# общего кода. Использует отдельные глобальные scratch-массивы (h_epoch2/
# h_speed2/h_name2, s_name/s_first/...) - не те, что у HTML-функций
# (h_epoch/h_speed/h_name, st_name/st_first/...) - оба режима в одном
# прогоне не выполняются (JSON-ветка END делает exit), но так нет риска
# случайно задеть состояние HTML-функций при будущих правках.
# ==========================================================================

# json_esc(s) - экранирование строки для JSON: обратный слеш, двойная
# кавычка и управляющие \n/\r/\t. В отличие от jsesc() (для JS-литерала в
# HTML-режиме) HTML-сущности НЕ добавляются - потребитель JSON (JSON.parse)
# ожидает сырую строку, а не HTML-экранированную (esc()).
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

# json_node_history(path, run_n) - топ NODE_CAP нод-победителей по частоте
# побед (при равенстве - по свежести последнего появления), с плотным по
# прогонам массивом скорости в байтах (null там, где нода прогон
# пропустила) - тот же алгоритм отбора/сортировки, что и в
# render_node_history() (см. её комментарий), но результат - данные, а не
# SVG/легенда/тултипы.
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

  topk = (un < NODE_CAP) ? un : NODE_CAP
  for (k = 1; k <= topk; k++) rank[uniq[k]] = k

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
      ",\"color\":" json_str(PAL[k]) ",\"values\":[" join_series_values(p_idx, p_speed, pn, run_n) "]}"
  }
  out = out "]}"
  return out
}

# json_node_stability(path) - "Доступность нод пула" (node_stability.tsv) -
# тот же разбор и та же сортировка по убыванию uptime за окно, что и в
# render_node_stability(); результат - данные вместо таблицы (спарклайн
# клиент при желании нарисует сам по полю "window").
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
    status = (ch == "A") ? "alive" : (ch == "D") ? "down" : "absent"
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
# раздела). Использует уже заполненные основным телом скрипта глобальные
# epoch[1..n]/iso[1..n]/channel[1..n]/threshold[1..n]/total[1..n]/
# alive[1..n]/tested[1..n]/good[1..n]/winners[1..n] - тот же вход, что и
# у HTML-режима, распарсенный один раз до END{} независимо от формата.
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
  FORMAT = (format == "json") ? "json" : "html"
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
  if (FORMAT == "json") { render_json(); exit }
  max2 = 1
  for (i = 1; i <= n; i++) {
    if (good[i] > max2) max2 = good[i]
    if (winners[i] > max2) max2 = winners[i]
  }

  print "<!doctype html><meta charset=\"utf-8\">"
  print "<title>speedtest2 - статистика</title>"
  print "<style>"
  print ":root{--bg:#f5f6f8;--card:#ffffff;--card-border:#e2e2e2;--text:#1b1f24;--muted:#666666;--border:#e2e2e2;--shadow:0 1px 2px rgba(15,17,21,.06);--line-good:#16a34a;--line-winners:#f59e0b}"
  print "@media (prefers-color-scheme: dark){:root{--bg:#0b0d12;--card:#161a21;--card-border:#262b33;--text:#e7e9ec;--muted:#9aa0a6;--border:#262b33;--shadow:0 1px 3px rgba(0,0,0,.4);--line-good:#34d399;--line-winners:#fbbf24}}"
  print ":root[data-theme=\"light\"]{--bg:#f5f6f8;--card:#ffffff;--card-border:#e2e2e2;--text:#1b1f24;--muted:#666666;--border:#e2e2e2;--shadow:0 1px 2px rgba(15,17,21,.06);--line-good:#16a34a;--line-winners:#f59e0b}"
  print ":root[data-theme=\"dark\"]{--bg:#0b0d12;--card:#161a21;--card-border:#262b33;--text:#e7e9ec;--muted:#9aa0a6;--border:#262b33;--shadow:0 1px 3px rgba(0,0,0,.4);--line-good:#34d399;--line-winners:#fbbf24}"
  print "*{box-sizing:border-box}"
  print "body{font:14px/1.5 -apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,sans-serif;margin:0;background:var(--bg);color:var(--text)}"
  print ".wrap{max-width:820px;margin:0 auto;padding:20px 16px 40px}"
  print "header{display:flex;align-items:flex-start;justify-content:space-between;gap:12px;margin-bottom:16px}"
  print "h1{font-size:19px;margin:0}"
  print ".meta{color:var(--muted);font-size:12.5px;margin:2px 0 0}"
  print ".theme-btn{border:1px solid var(--card-border);background:var(--card);color:var(--text);border-radius:8px;padding:6px 10px;font-size:13px;cursor:pointer;flex:0 0 auto}"
  print ".theme-btn:disabled{opacity:.5;cursor:default}"
  print "#runStatus{min-height:1.4em}"
  print ".card{background:var(--card);border:1px solid var(--card-border);border-radius:14px;padding:16px 18px;margin-bottom:16px;box-shadow:var(--shadow)}"
  print "h2{font-size:14.5px;margin:0 0 8px;font-weight:600}"
  print "svg{max-width:100%;height:auto;display:block;margin-bottom:8px}"
  print ".axis-line{stroke:var(--border)}"
print ".axis-tick{stroke:var(--border)}"
  print ".axis-text{fill:var(--muted)}"
  print ".line-good{stroke:var(--line-good)}"
  print ".line-winners{stroke:var(--line-winners)}"
  print ".node-dot{stroke:var(--card)}"
  print "table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}"
  print "td,th{padding:6px 10px;text-align:right;border-bottom:1px solid var(--border)}"
  print "th{color:var(--muted);font-weight:600}"
  print "th:last-child,td:last-child{text-align:left}"
  print "tr:hover td{background:var(--bg)}"
  print ".legend{font-size:12px;color:var(--muted);margin:0 0 8px}"
  print ".sw{display:inline-block;width:10px;height:10px;border-radius:3px;margin-right:4px;vertical-align:-1px}"
  print ".sw-good{background:var(--line-good)}"
  print ".sw-winners{background:var(--line-winners)}"
  print ".chart-wrap{position:relative}"
  print ".chart-capture{fill:transparent;cursor:crosshair}"
  print ".crosshair-line{stroke:var(--muted);stroke-width:1;pointer-events:none}"
  print ".crosshair-dot{stroke:var(--card);stroke-width:1;pointer-events:none}"
  print ".dot-good{fill:var(--line-good)}"
  print ".dot-winners{fill:var(--line-winners)}"
  print ".node-series{opacity:1;transition:opacity .15s ease}"
  print ".node-series.dim{opacity:.2}"
  print ".tooltip{position:absolute;pointer-events:none;background:var(--card);border:1px solid var(--card-border);border-radius:8px;padding:6px 10px;font-size:12px;box-shadow:var(--shadow);max-width:240px;z-index:10}"
  print ".tooltip[hidden]{display:none}"
  print ".tooltip .tt-label{font-weight:600;margin-bottom:4px}"
  print ".tooltip .tt-row{display:flex;align-items:center;gap:6px;line-height:1.4}"
  print ".stats-row{display:flex;flex-wrap:wrap;gap:14px 22px;margin-top:10px;padding-top:10px;border-top:1px solid var(--border)}"
  print ".stat-group{display:flex;align-items:center;gap:10px;flex-wrap:wrap;font-size:12px;color:var(--muted)}"
  print ".stat-label{display:flex;align-items:center;gap:4px;font-weight:600;color:var(--text)}"
  print ".stat b{color:var(--text);font-weight:600}"
  print ".table-scroll{max-height:420px;overflow-y:auto}"
  print "table th[data-sort]{cursor:pointer;user-select:none}"
  print "table th[data-dir=\"asc\"]::after{content:\" \\2191\"}"
  print "table th[data-dir=\"desc\"]::after{content:\" \\2193\"}"
  print ".dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:5px;vertical-align:-1px}"
  print ".st-ok{background:var(--line-good)}"
  print ".st-bad{background:#e34948}"
  print ".st-gap{background:var(--muted)}"
  print ".delta-pos{color:var(--line-good)}"
  print ".delta-neg{color:#e34948}"
  print ".hist-ok,.hist-bad,.hist-gap{display:inline-block;width:5px;height:12px;margin-right:1px;border-radius:1px;vertical-align:middle}"
  print ".hist-ok{background:var(--line-good)}"
  print ".hist-bad{background:#e34948}"
  print ".hist-gap{background:var(--border)}"
  print "</style>"
  print "<div class=\"wrap\">"
  print "<header>"
  print "<div><h1>Статистика speedtest2</h1><p class=\"meta\">Сгенерировано: " esc(generated) " · прогонов в истории: " n "</p></div>"
  print "<div style=\"display:flex;gap:8px;flex:0 0 auto\">"
  print "<button class=\"theme-btn\" id=\"runBtn\" type=\"button\">Запустить прогон сейчас</button>"
  print "<a class=\"theme-btn\" href=\"cgi-bin/config\">Настройки</a>"
  print "<button class=\"theme-btn\" id=\"themeBtn\" type=\"button\">Тема</button>"
  print "</div>"
  print "</header>"
  print "<p class=\"meta\" id=\"runStatus\"></p>"

  if (n == 0) {
    print "<div class=\"card\"><p>Пока нет ни одного прогона в истории.</p></div>"
  } else {
    print "<div class=\"card\">"
    print "<h2>Ноды</h2>"
    print "<p class=\"legend\"><span class=\"sw sw-good\"></span>нод выше порога" \
          "&nbsp; <span class=\"sw sw-winners\"></span>победителей (в fast.yaml)</p>"
    print "<div class=\"chart-wrap\">"
    print "<svg id=\"svg-nodes\" viewBox=\"0 0 760 214\" xmlns=\"http://www.w3.org/2000/svg\">"
    printf "<line class=\"axis-line\" x1=\"40\" y1=\"10\" x2=\"40\" y2=\"180\"/>\n"
    printf "<line class=\"axis-line\" x1=\"40\" y1=\"180\" x2=\"750\" y2=\"180\"/>\n"
    printf "<text class=\"axis-text\" x=\"34\" y=\"14\" font-size=\"10\" text-anchor=\"end\">%d</text>\n", max2
    printf "<text class=\"axis-text\" x=\"34\" y=\"184\" font-size=\"10\" text-anchor=\"end\">0</text>\n"
    render_x_axis_dates(40, 10, 710, 170, n)
    printf "<polyline class=\"line-good\" fill=\"none\" stroke-width=\"2\" points=\"%s\"/>\n", poly(good, n, max2)
    printf "<polyline class=\"line-winners\" fill=\"none\" stroke-width=\"2\" points=\"%s\"/>\n", poly(winners, n, max2)
    print "<line class=\"crosshair-line\" id=\"crosshair-nodes\" x1=\"40\" y1=\"10\" x2=\"40\" y2=\"180\" visibility=\"hidden\"/>"
    print "<circle class=\"crosshair-dot dot-good\" id=\"dot-nodes-good\" r=\"3.5\" visibility=\"hidden\"/>"
    print "<circle class=\"crosshair-dot dot-winners\" id=\"dot-nodes-winners\" r=\"3.5\" visibility=\"hidden\"/>"
    print "<rect class=\"chart-capture\" id=\"capture-nodes\" x=\"40\" y=\"10\" width=\"710\" height=\"170\"/>"
    print "</svg>"
    print "<div class=\"tooltip\" id=\"tooltip-nodes\" hidden></div>"
    print "</div>"
    printf "<script>window.STATS_CHARTS=window.STATS_CHARTS||{};STATS_CHARTS.nodes={left:40,top:10,w:710,h:170,n:%d,max:%d,labels:[%s],series:[{id:\"good\",name:\"нод выше порога\",values:[%s]},{id:\"winners\",name:\"победителей\",values:[%s]}]};</script>\n", \
      n, max2, join_str_js(iso, n), join_num(good, n), join_num(winners, n)
    print "<div class=\"stats-row\">"
    stat_row_html("нод выше порога", "sw-good", "int", good, n)
    stat_row_html("победителей", "sw-winners", "int", winners, n)
    print "</div>"
    printf "<p>Последний прогон (%s): канал %s МБ/с, порог %s МБ/с, живых %d из %d, отобрано %d.</p>\n", \
      esc(iso[n]), fmt_mb(channel[n]), fmt_mb(threshold[n]), alive[n], total[n], winners[n]
    print "</div>"

    if (nodes != "") {
      print "<div class=\"card\">"
      render_node_history(nodes, n)
      print "</div>"
    }
  }

  if (stability != "") {
    print "<div class=\"card\">"
    render_node_stability(stability)
    print "</div>"
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
  print "function initChart(id){"
  print "var cfg=(window.STATS_CHARTS||{})[id];"
  print "if(!cfg)return;"
  print "var svg=document.getElementById('svg-'+id);"
  print "var capture=document.getElementById('capture-'+id);"
  print "var crosshair=document.getElementById('crosshair-'+id);"
  print "var tooltip=document.getElementById('tooltip-'+id);"
  print "var wrap=svg?svg.parentNode:null;"
  print "if(!svg||!capture||!crosshair||!tooltip||!wrap)return;"
  print "var dots={};"
  print "for(var i=0;i<cfg.series.length;i++){dots[cfg.series[i].id]=document.getElementById('dot-'+id+'-'+cfg.series[i].id);}"
  print "var groups={};"
  print "if(cfg.highlight){for(var gi=0;gi<cfg.series.length;gi++){groups[cfg.series[gi].id]=document.getElementById('series-'+id+'-'+cfg.series[gi].id);}}"
  print "function svgPoint(clientX,clientY){"
  print "var pt=svg.createSVGPoint();pt.x=clientX;pt.y=clientY;"
  print "return pt.matrixTransform(svg.getScreenCTM().inverse());"
  print "}"
  print "function idxAt(svgX){"
  print "var step=cfg.n>1?cfg.w/(cfg.n-1):0;"
  print "var idx=step>0?Math.round((svgX-cfg.left)/step):0;"
  print "if(idx<0)idx=0;if(idx>cfg.n-1)idx=cfg.n-1;"
  print "return idx;"
  print "}"
  print "function xFor(idx){return cfg.n>1?cfg.left+(idx*cfg.w/(cfg.n-1)):cfg.left+cfg.w/2;}"
  print "function yFor(v){var m=cfg.max||1;return cfg.top+cfg.h-(v*cfg.h/m);}"
print "function fmtVal(cfg,v){if(cfg.unit!==\"mb\")return v;var mb=Math.floor(v/1048576);var frac=Math.floor((v%1048576)*10/1048576);return mb+\".\"+frac+\" МБ/с\";}"
  print "function show(clientX,clientY){"
  print "if(!cfg.n)return;"
  print "var loc=svgPoint(clientX,clientY);"
  print "var idx=idxAt(loc.x);"
  print "var x=xFor(idx);"
  print "crosshair.setAttribute('x1',x);crosshair.setAttribute('x2',x);crosshair.setAttribute('visibility','visible');"
  print "var html='<div class=\"tt-label\">'+(cfg.labels[idx]||'')+'</div>';"
  print "var nearestId=null,nearestDist=Infinity;"
  print "for(var i=0;i<cfg.series.length;i++){"
  print "var s=cfg.series[i];var v=s.values[idx];"
  print "if(v===null||v===undefined)continue;"
  print "var dist=Math.abs(loc.y-yFor(v));"
  print "if(dist<nearestDist){nearestDist=dist;nearestId=s.id;}"
  print "}"
  print "for(var j=0;j<cfg.series.length;j++){"
  print "var s2=cfg.series[j];var v2=s2.values[idx];var dot=dots[s2.id];"
  print "if(v2===null||v2===undefined){if(dot)dot.setAttribute('visibility','hidden');}"
  print "else{if(dot){dot.setAttribute('cx',x);dot.setAttribute('cy',yFor(v2));dot.setAttribute('visibility','visible');}"
  print "html+='<div class=\"tt-row\"><span class=\"sw sw-'+s2.id+'\"></span>'+s2.name+': '+fmtVal(cfg,v2)+'</div>';}"
  print "if(cfg.highlight&&groups[s2.id]){groups[s2.id].classList.toggle('dim',s2.id!==nearestId);}"
  print "}"
  print "tooltip.innerHTML=html;tooltip.hidden=false;"
  print "var wrapRect=wrap.getBoundingClientRect();"
  print "var left=clientX-wrapRect.left+12;var top=clientY-wrapRect.top-12;"
  print "var maxLeft=wrapRect.width-tooltip.offsetWidth-4;"
  print "if(left>maxLeft)left=clientX-wrapRect.left-tooltip.offsetWidth-12;"
  print "if(left<0)left=0;"
  print "tooltip.style.left=left+'px';tooltip.style.top=top+'px';"
  print "}"
  print "function hide(){"
  print "crosshair.setAttribute('visibility','hidden');"
  print "for(var k in dots){if(dots[k])dots[k].setAttribute('visibility','hidden');}"
  print "if(cfg.highlight){for(var gk in groups){if(groups[gk])groups[gk].classList.remove('dim');}}"
  print "tooltip.hidden=true;"
  print "}"
  print "capture.addEventListener('mousemove',function(e){show(e.clientX,e.clientY);});"
  print "capture.addEventListener('mouseleave',hide);"
  print "capture.addEventListener('touchmove',function(e){if(e.touches&&e.touches[0])show(e.touches[0].clientX,e.touches[0].clientY);},{passive:true});"
  print "capture.addEventListener('touchend',hide);"
  print "}"
  print "for(var chartId in (window.STATS_CHARTS||{}))initChart(chartId);"
  print "})();"
  print "</script>"
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
  print "<script>"
  print "(function(){"
  print "var btn=document.getElementById('runBtn');"
  print "var status=document.getElementById('runStatus');"
  print "if(!btn||!status)return;"
  print "var timer=null;"
  print "var sawRunning=false;"
  print "function setIdle(){"
  print "btn.disabled=false;"
  print "btn.textContent='Запустить прогон сейчас';"
  print "status.textContent='';"
  print "}"
  print "function setRunning(){"
  print "btn.disabled=true;"
  print "btn.textContent='Выполняется...';"
  print "status.textContent='Прогон нод выполняется, страница обновится сама по готовности.';"
  print "}"
  print "function setError(msg){"
  print "btn.disabled=false;"
  print "btn.textContent='Запустить прогон сейчас';"
  print "status.textContent=msg;"
  print "}"
  print "function poll(){"
  print "fetch('cgi-bin/run').then(function(r){return r.json();}).then(function(d){"
  print "if(d.running){"
  print "sawRunning=true;"
  print "setRunning();"
  print "timer=setTimeout(poll,5000);"
  print "}else if(sawRunning){"
  print "location.reload();"
  print "}else{"
  print "setIdle();"
  print "}"
  print "}).catch(function(){"
  print "timer=setTimeout(poll,5000);"
  print "});"
  print "}"
  print "btn.addEventListener('click',function(){"
  print "clearTimeout(timer);"
  print "btn.disabled=true;"
  print "btn.textContent='Запуск...';"
  print "status.textContent='';"
  print "fetch('cgi-bin/run',{method:'POST'}).then(function(r){return r.json();}).then(function(d){"
  print "if(d.error){setError('Ошибка: '+d.error);return;}"
  print "sawRunning=true;"
  print "setRunning();"
  print "poll();"
  print "}).catch(function(){"
  print "setError('Не удалось запустить: ошибка сети.');"
  print "});"
  print "});"
  print "poll();"
  print "})();"
  print "</script>"
  print "<script>"
  print "(function(){"
  print "var table=document.getElementById('stability-table');"
  print "if(!table)return;"
  print "var tbody=table.tBodies[0];"
  print "var ths=table.querySelectorAll('th[data-sort]');"
  print "for(var i=0;i<ths.length;i++){(function(th){"
  print "if(th.getAttribute('data-sort')==='none')return;"
  print "th.addEventListener('click',function(){"
  print "var col=parseInt(th.getAttribute('data-col'),10);"
  print "var type=th.getAttribute('data-sort');"
  print "var dir=th.getAttribute('data-dir')==='asc'?'desc':'asc';"
  print "for(var j=0;j<ths.length;j++)ths[j].removeAttribute('data-dir');"
  print "th.setAttribute('data-dir',dir);"
  print "var rows=Array.prototype.slice.call(tbody.rows);"
  print "rows.sort(function(a,b){"
  print "var av=a.cells[col].getAttribute('data-v');var bv=b.cells[col].getAttribute('data-v');"
  print "if(type==='num'){av=parseFloat(av);bv=parseFloat(bv);}"
  print "var cmp=av<bv?-1:av>bv?1:0;"
  print "return dir==='asc'?cmp:-cmp;"
  print "});"
  print "for(var k=0;k<rows.length;k++)tbody.appendChild(rows[k]);"
  print "});"
  print "})(ths[i]);}"
  print "})();"
  print "</script>"
}
