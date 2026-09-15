# render_progress.awk - прогресс скоростного теста по нодам ТЕКУЩЕГО
# прогона (шаг 5 main() в speedtest2.sh) - отдельный от render_stats.awk
# файл, потому что источник другой (progress.tsv - накопительный за
# один прогон, а не история прошлых прогонов) и назначение другое (что
# происходит ПРЯМО СЕЙЧАС, а не аналитика по прошлым прогонам).
# Вызывается из write_progress() в speedtest2.sh после каждой
# протестированной ноды (и ещё раз из cleanup() при завершении прогона) -
# на каждый вызов честно перечитывает весь входной TSV с нуля,
# накопительных счётчиков внутри awk-процесса нет (каждый вызов - новый
# процесс awk, как и везде в проекте).
#
# Использование:
#   awk -v running=0|1 -v total=N -v started_iso="дата-время" \
#       -v updated_iso="дата-время" -f render_progress.awk PROGRESS_TSV
#
# running: 1, пока идёт цикл шага 5 (тестирование кандидатов по одному),
#   0 - цикл этой стадии завершён (нормально или прерван - см.
#   write_progress()/cleanup() в speedtest2.sh). running=0 не означает,
#   что fast.yaml уже опубликован - только что цикл загрузок закончился,
#   дальше ещё отбор победителей и публикация (шаги 6-8 main()).
# total: число кандидатов на скоростной тест в этом прогоне (CANDIDATES
#   в speedtest2.sh, известно до начала цикла - см. select_candidates()).
# started_iso/updated_iso: строки "YYYY-MM-DD HH:MM:SS" - когда начался
#   цикл и когда сформирован этот конкретный ответ (тот же формат, что и
#   iso в остальном проекте, не эпоха - см. node_stats_update.awk).
# PROGRESS_TSV: по строке на КАЖДУЮ уже протестированную в этом прогоне
#   ноду, в порядке тестирования: name<TAB>speed_bytes<TAB>status
#   (status: "ok" - скорость >= порога этого прогона (EFFECTIVE_MIN),
#   "slow" - ниже). Пустой/отсутствующий файл - ни одна нода ещё не
#   протестирована (цикл только начался).
#
# Вывод (stdout) - один JSON-объект:
#   {"running":bool,"started_iso":str,"updated_iso":str,"total":int,
#    "tested":int,"results":[{"name":str,"speed_bytes":int,"status":str},...]}
# results - в том же порядке, что и строки входного TSV (порядок
# тестирования, не отсортировано по скорости).
#
# JSON-эскейпинг (json_esc/json_str) продублирован из render_stats.awk -
# намеренно, по тому же принципу, что и код отбора в
# json_node_history()/json_node_stability() там же: отдельный маленький
# файл проще держать самостоятельным, чем городить общий inc-файл для
# awk (у busybox awk нет include).

BEGIN {
  FS = "\t"
}

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

{
  if (NF < 3 || $1 == "") next
  cnt++
  p_name[cnt] = $1
  p_speed[cnt] = $2 + 0
  p_status[cnt] = $3
}

END {
  printf "{\"running\":%s,\"started_iso\":%s,\"updated_iso\":%s,\"total\":%d,\"tested\":%d,\"results\":[", \
    (running + 0 ? "true" : "false"), json_str(started_iso), json_str(updated_iso), total + 0, cnt + 0
  for (i = 1; i <= cnt; i++) {
    printf "%s{\"name\":%s,\"speed_bytes\":%d,\"status\":%s}", \
      (i > 1 ? "," : ""), json_str(p_name[i]), p_speed[i], json_str(p_status[i])
  }
  print "]}"
}
