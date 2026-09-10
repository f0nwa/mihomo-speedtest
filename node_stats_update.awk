# node_stats_update.awk - сливает данные группового delay-check одного
# прогона (map.txt: весь пул, alive.txt: живые + задержка) с агрегатом
# стабильности всех нод node_stability.tsv, печатает обновлённый агрегат
# на stdout. Не выполняется на роутере напрямую - вызывается из
# speedtest2.sh (update_node_stability()) сразу после шага 4 (group
# delay-check), независимо от исхода остальных шагов main().
#
# Использование:
#   awk -v iso="дата-время" -v window_len=N -v drop_after=N \
#       -v mapfile=PATH -v alivefile=PATH \
#       -f node_stats_update.awk OLD_STABILITY_TSV
#
# iso: строка "YYYY-MM-DD HH:MM:SS" (как $(date '+%Y-%m-%d %H:%M:%S') в
#   остальном проекте) - штамп этого прогона; хранится и используется как
#   строка, не как эпоха, чтобы не требовать strftime() от awk на роутере.
# mapfile: строки "idx<TAB>name" (map.txt из prep.awk) - весь пул этого
#   прогона.
# alivefile: строки "delay idx" (alive.txt из main(), поля через пробел,
#   не таб) - живые ноды этого прогона с задержкой delay-check в мс.
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
#   runs_alive<TAB>delay_sum_ms<TAB>delay_samples<TAB>consec_absent<TAB>window
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

    printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\n", \
      name, first_seen, last_seen, iso, runs_seen, runs_alive, delay_sum, delay_samples, 0, win
    done[name] = 1
  }

  for (i = 1; i <= nold; i++) {
    name = old_order[i]
    if (name in done) continue
    consec_absent = old_consec_absent[name] + 1
    if (drop_after > 0 && consec_absent >= drop_after) continue
    win = old_window[name] "."
    if (length(win) > window_len) win = substr(win, length(win) - window_len + 1)
    printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%s\n", \
      name, old_first[name], old_last_seen[name], old_last_pool[name], \
      old_runs_seen[name], old_runs_alive[name], old_delay_sum[name], \
      old_delay_samples[name], consec_absent, win
  }
}
