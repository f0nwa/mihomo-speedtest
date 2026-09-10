# node_stats_update.awk - сливает данные группового delay-check и (когда
# он был в этом прогоне) speed-теста одного прогона (map.txt: весь пул,
# alive.txt: живые + задержка, speedfile: опционально - "скорость idx" по
# нодам, реально прошедшим speed-тест этого прогона, см. ENOUGH в
# speedtest2.sh - тестируются не все живые ноды каждый прогон) с агрегатом
# стабильности всех нод node_stability.tsv, печатает обновлённый агрегат
# на stdout. Не выполняется на роутере напрямую - вызывается из
# speedtest2.sh (update_node_stability()) после шага 5 (speed-тест),
# независимо от исхода остальных шагов main().
#
# Использование:
#   awk -v iso="дата-время" -v window_len=N -v drop_after=N \
#       -v mapfile=PATH -v alivefile=PATH -v speedfile=PATH \
#       -f node_stats_update.awk OLD_STABILITY_TSV
#
# iso: строка "YYYY-MM-DD HH:MM:SS" (как $(date '+%Y-%m-%d %H:%M:%S') в
#   остальном проекте) - штамп этого прогона; хранится и используется как
#   строка, не как эпоха, чтобы не требовать strftime() от awk на роутере.
# mapfile: строки "idx<TAB>name" (map.txt из prep.awk) - весь пул этого
#   прогона.
# alivefile: строки "delay idx" (alive.txt из main(), поля через пробел,
#   не таб) - живые ноды этого прогона с задержкой delay-check в мс.
# speedfile: строки "скорость_байт/с idx" (res.txt из main(), поля через
#   пробел) - только ноды, реально прошедшие speed-тест этого прогона;
#   опционально - пустой/отсутствующий файл просто не добавляет ни одной
#   ноде замера скорости в этом прогоне ("копим только когда есть замер").
# window_len: максимальная длина поля window (пустое/некорректное - 200).
# drop_after: нода, отсутствующая в пуле drop_after прогонов подряд
#   (consec_absent >= drop_after), в вывод не попадает - удаляется из
#   агрегата. 0 - не удалять никогда.
# OLD_STABILITY_TSV: позиционный аргумент, предыдущий node_stability.tsv;
#   передавайте /dev/null, если файла ещё нет - сам awk файл не создаёт и
#   не проверяет его существование.
#
# Вывод (stdout), одна строка на ноду, TSV:
#   name<TAB>first_seen<TAB>last_seen<TAB>last_in_pool<TAB>runs_seen<TAB>
#   runs_alive<TAB>delay_sum_ms<TAB>delay_samples<TAB>consec_absent<TAB>window<TAB>
#   last_speed_bytes<TAB>speed_sum_bytes<TAB>speed_samples
# last_speed_bytes/speed_sum_bytes/speed_samples копятся только по тем
# прогонам, где нода реально попала в speedfile - счётчики растут не на
# каждом прогоне, в отличие от delay_sum/delay_samples (те - из
# alivefile, покрывают весь живой пул каждый прогон).
# first_seen/last_seen/last_in_pool - строки "YYYY-MM-DD HH:MM:SS"
# (last_seen пусто, если нода ни разу не отвечала). window - до
# window_len символов, один на прогон: A (жива), D (в пуле, не ответила),
# . (не в пуле); новый символ дописывается справа, старые обрезаются
# слева. Дубли имён в map.txt (разные idx, одно имя) схлопываются в одну
# ноду - то же допущение, что и у speedtest_history.tsv; среди дублей
# среди живых берётся минимальная задержка.

BEGIN {
  FS = "\t"
  if (window_len + 0 < 1) window_len = 200
  drop_after = drop_after + 0
  nold = 0
  npool = 0

  while ((getline mline < mapfile) > 0) {
    n = split(mline, mf, "\t")
    if (n < 2 || mf[2] == "") continue
    idx = mf[1]; name = mf[2]
    idx_name[idx] = name
    if (!(name in pool)) { pool[name] = 1; pool_order[++npool] = name }
  }
  close(mapfile)

  while ((getline aline < alivefile) > 0) {
    split(aline, af, " ")
    delay = af[1] + 0; idx = af[2]
    if (!(idx in idx_name)) continue
    name = idx_name[idx]
    if (!(name in alive_delay) || delay < alive_delay[name]) alive_delay[name] = delay
  }
  close(alivefile)

  if (speedfile != "") {
    while ((getline sline < speedfile) > 0) {
      split(sline, sf, " ")
      sp = sf[1] + 0; idx = sf[2]
      if (!(idx in idx_name)) continue
      name = idx_name[idx]
      if (!(name in node_speed) || sp > node_speed[name]) node_speed[name] = sp
    }
    close(speedfile)
  }
}

NF >= 10 && $1 != "" {
  oname = $1
  old_first[oname] = $2
  old_last_seen[oname] = $3
  old_last_pool[oname] = $4
  old_runs_seen[oname] = $5 + 0
  old_runs_alive[oname] = $6 + 0
  old_delay_sum[oname] = $7 + 0
  old_delay_samples[oname] = $8 + 0
  old_consec_absent[oname] = $9 + 0
  old_window[oname] = $10
  old_last_speed[oname] = $11 + 0
  old_speed_sum[oname] = $12 + 0
  old_speed_samples[oname] = $13 + 0
  have_old[oname] = 1
  old_order[++nold] = oname
}

END {
  for (i = 1; i <= npool; i++) {
    name = pool_order[i]
    is_new = !(name in have_old)
    first_seen = is_new ? iso : old_first[name]
    runs_seen = (is_new ? 0 : old_runs_seen[name]) + 1
    runs_alive = is_new ? 0 : old_runs_alive[name]
    delay_sum = is_new ? 0 : old_delay_sum[name]
    delay_samples = is_new ? 0 : old_delay_samples[name]
    last_seen = is_new ? "" : old_last_seen[name]
    win = is_new ? "" : old_window[name]
    last_speed = is_new ? 0 : old_last_speed[name]
    speed_sum = is_new ? 0 : old_speed_sum[name]
    speed_samples = is_new ? 0 : old_speed_samples[name]

    if (name in alive_delay) {
      runs_alive++
      delay_sum += alive_delay[name]
      delay_samples++
      last_seen = iso
      win = win "A"
    } else {
      win = win "D"
    }
    if (length(win) > window_len) win = substr(win, length(win) - window_len + 1)

    if (name in node_speed) {
      last_speed = node_speed[name]
      speed_sum += node_speed[name]
      speed_samples++
    }

    printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\n", \
      name, first_seen, last_seen, iso, runs_seen, runs_alive, delay_sum, delay_samples, 0, win, \
      last_speed, speed_sum, speed_samples
    done[name] = 1
  }

  for (i = 1; i <= nold; i++) {
    name = old_order[i]
    if (name in done) continue
    consec_absent = old_consec_absent[name] + 1
    if (drop_after > 0 && consec_absent >= drop_after) continue
    win = old_window[name] "."
    if (length(win) > window_len) win = substr(win, length(win) - window_len + 1)
    printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\n", \
      name, old_first[name], old_last_seen[name], old_last_pool[name], \
      old_runs_seen[name], old_runs_alive[name], old_delay_sum[name], \
      old_delay_samples[name], consec_absent, win, \
      old_last_speed[name], old_speed_sum[name], old_speed_samples[name]
  }
}
