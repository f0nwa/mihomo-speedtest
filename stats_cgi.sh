#!/bin/sh
# CGI-скрипт формы настройки статистики speedtest2 (см. README.md, раздел
# про stats_www/cgi-bin/config). Ставится install.sh в $DIR/stats_cgi.sh;
# в раздаваемый каталог (STATS_CGI_SCRIPT, обычно $DIR/stats_www/cgi-bin/config)
# его копирует write_stats_cgi() из speedtest2.sh при каждом прогоне
# ensure_stats_httpd() - править нужно этот файл, копия перезаписывается
# автоматически и правки в ней не сохранятся.
#
# Полагается на то, что busybox httpd передаёт CGI-процессу окружение
# родителя: ensure_stats_httpd() в speedtest2.sh экспортирует DIR и ENV
# перед запуском веб-сервиса, поэтому сорс "$DIR/speedtest2.sh" ниже
# подхватывает те же настройки (включая текущий speedtest2.env), что и
# обычный прогон по cron - в т.ч. пересчитывает все зависящие от DIR пути
# (HISTORY_RUNS, STATS_HTML и т.д.), а не только те, что перечислены тут.

export MST_LIB_ONLY=1
[ -n "$DIR" ] && [ -f "$DIR/speedtest2.sh" ] && . "$DIR/speedtest2.sh"

if [ -z "$DIR" ] || ! command -v render_stats >/dev/null 2>&1; then
  echo "Content-Type: text/plain; charset=utf-8"
  echo
  echo "Ошибка конфигурации: не удалось подключить speedtest2.sh (DIR=[$DIR])."
  echo "Обычно это значит, что CGI запущен не через busybox httpd, поднятый ensure_stats_httpd()."
  exit 0
fi

urldecode() {
  # busybox httpd -d делает то же декодирование, что браузер для
  # application/x-www-form-urlencoded: '+' -> пробел, %XX -> байт.
  busybox httpd -d "$1"
}

html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

is_uint() {
  case $1 in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

get_field() {
  # $1 = имя поля. Ожидает $body с искусственным ведущим '&' (см. ниже) -
  # так шаблону не нужна альтернация "^|&", которую понимает не всякий sed.
  printf '%s' "$body" | sed -n "s/.*&$1=\\([^&]*\\).*/\\1/p"
}

set_env_var() {
  # $1=имя (без спецсимволов регулярных выражений - все имена ниже фиксированы),
  # $2=значение. Атомарно заменяет/добавляет строку NAME='значение' в $ENV -
  # в кавычках, как install.sh пишет write_env(). Остальные строки (BLOCK,
  # SOURCES, комментарии...) не трогает.
  name=$1; val=$2
  esc=$(printf '%s' "$val" | sed "s/'/'\\\\''/g")
  tmp="$ENV.cgi.$$"
  { [ -f "$ENV" ] && grep -v "^$name=" "$ENV"; printf "%s='%s'\\n" "$name" "$esc"; } > "$tmp" 2>/dev/null
  mv "$tmp" "$ENV"
}

method=${REQUEST_METHOD:-GET}
msg=""
err=""

if [ "$method" = "POST" ]; then
  len=${CONTENT_LENGTH:-0}
  is_uint "$len" || len=0
  if [ "$len" -gt 0 ]; then
    body=$(dd bs=1 count="$len" 2>/dev/null)
  else
    body=""
  fi
  body="&$body"

  node_cap=$(urldecode "$(get_field node_cap)")
  keep_runs=$(urldecode "$(get_field keep_runs)")
  keep_days=$(urldecode "$(get_field keep_days)")
  auth_user=$(urldecode "$(get_field auth_user)")
  auth_pass=$(urldecode "$(get_field auth_pass)")
  no_auth=$(urldecode "$(get_field no_auth)")
  geo_filter=$(urldecode "$(get_field geo_filter)")

  if ! is_uint "$node_cap" || [ "$node_cap" -lt 1 ] || [ "$node_cap" -gt 8 ]; then
    err="${err}Число нод на графике должно быть от 1 до 8.<br>"
  fi
  if ! is_uint "$keep_runs"; then
    err="${err}«Хранить прогонов» должно быть целым числом (0 = не ограничивать).<br>"
  fi
  if ! is_uint "$keep_days"; then
    err="${err}«Хранить дней» должно быть целым числом (0 = не ограничивать).<br>"
  fi
  if [ -z "$err" ] && [ "$keep_runs" = 0 ] && [ "$keep_days" = 0 ]; then
    err="${err}Нельзя одновременно занулить оба лимита хранения истории.<br>"
  fi
  if [ -z "$geo_filter" ]; then
    err="${err}Гео-фильтр обязателен - без него подписка может подставить российскую ноду.<br>"
  fi
  if [ -z "$no_auth" ]; then
    if [ -n "$auth_user" ] && [ -z "$auth_pass" ]; then
      err="${err}Для смены пароля укажите и логин, и пароль.<br>"
    elif [ -z "$auth_user" ] && [ -n "$auth_pass" ]; then
      err="${err}Для смены пароля укажите и логин, и пароль.<br>"
    fi
  fi

  if [ -z "$err" ]; then
    set_env_var STATS_NODE_CAP "$node_cap"
    set_env_var HISTORY_KEEP_RUNS "$keep_runs"
    set_env_var HISTORY_KEEP_DAYS "$keep_days"
    set_env_var BLOCK "$geo_filter"
    if [ -n "$no_auth" ]; then
      set_env_var STATS_AUTH_USER ""
      set_env_var STATS_AUTH_PASS ""
    elif [ -n "$auth_user" ] && [ -n "$auth_pass" ]; then
      set_env_var STATS_AUTH_USER "$auth_user"
      set_env_var STATS_AUTH_PASS "$auth_pass"
    fi

    # перечитываем свежесохранённые значения и применяем сразу, не дожидаясь
    # следующего прогона по cron: перегенерируем stats.html (новый NODE_CAP)
    # и переподнимаем веб-сервис (новые логин/пароль/защита cgi-bin).
    [ -f "$ENV" ] && . "$ENV"
    WORK=$(mktemp -d "${TMPROOT:-/tmp}/mst-cgi.XXXXXX" 2>/dev/null) || WORK=${TMPROOT:-/tmp}/mst-cgi.$$
    mkdir -p "$WORK" 2>/dev/null
    RUN_LOG=$WORK/cgi.log
    render_stats
    ensure_stats_httpd
    rm -rf "$WORK"
    msg="Настройки сохранены."
  fi
fi

echo "Content-Type: text/html; charset=utf-8"
echo

cat <<HTML
<!doctype html><meta charset="utf-8">
<title>speedtest2 - настройка статистики</title>
<style>
:root{--bg:#f5f6f8;--card:#ffffff;--card-border:#e2e2e2;--text:#1b1f24;--muted:#666666;--border:#e2e2e2;--shadow:0 1px 2px rgba(15,17,21,.06);--accent:#2a78d6}
@media (prefers-color-scheme: dark){:root{--bg:#0b0d12;--card:#161a21;--card-border:#262b33;--text:#e7e9ec;--muted:#9aa0a6;--border:#262b33;--shadow:0 1px 3px rgba(0,0,0,.4);--accent:#2a78d6}}
:root[data-theme="light"]{--bg:#f5f6f8;--card:#ffffff;--card-border:#e2e2e2;--text:#1b1f24;--muted:#666666;--border:#e2e2e2;--shadow:0 1px 2px rgba(15,17,21,.06);--accent:#2a78d6}
:root[data-theme="dark"]{--bg:#0b0d12;--card:#161a21;--card-border:#262b33;--text:#e7e9ec;--muted:#9aa0a6;--border:#262b33;--shadow:0 1px 3px rgba(0,0,0,.4);--accent:#2a78d6}
*{box-sizing:border-box}
body{font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;margin:0;background:var(--bg);color:var(--text)}
.wrap{max-width:520px;margin:0 auto;padding:20px 16px 40px}
header{display:flex;align-items:flex-start;justify-content:space-between;gap:12px;margin-bottom:16px}
h1{font-size:19px;margin:0}
.meta{color:var(--muted);font-size:12.5px;margin:2px 0 0}
.theme-btn{border:1px solid var(--card-border);background:var(--card);color:var(--text);border-radius:8px;padding:6px 10px;font-size:13px;cursor:pointer;text-decoration:none;display:inline-block;flex:0 0 auto}
.card{background:var(--card);border:1px solid var(--card-border);border-radius:14px;padding:16px 18px;margin-bottom:16px;box-shadow:var(--shadow)}
h2{font-size:14.5px;margin:0 0 8px;font-weight:600}
label{display:block;font-size:13px;color:var(--muted);margin:12px 0 4px}
label:first-child{margin-top:0}
input[type=text],input[type=password],input[type=number]{width:100%;padding:7px 9px;border:1px solid var(--card-border);border-radius:6px;background:var(--bg);color:var(--text);font-size:14px}
.hint{color:var(--muted);font-size:12px;margin:4px 0 0}
.row-checkbox{display:flex;align-items:center;gap:6px;margin-top:12px}
.row-checkbox label{margin:0}
button.submit{margin-top:16px;padding:8px 16px;border:0;border-radius:8px;background:var(--accent);color:#fff;font-size:14px;cursor:pointer;box-shadow:var(--shadow)}
.msg-ok{background:#16a34a22;border:1px solid #16a34a;border-radius:8px;padding:8px 12px;margin-bottom:16px;font-size:13px}
.msg-err{background:#dc262622;border:1px solid #dc2626;border-radius:8px;padding:8px 12px;margin-bottom:16px;font-size:13px}
</style>
<div class="wrap">
<header>
<div><h1>Настройка статистики</h1><p class="meta">speedtest2</p></div>
<div style="display:flex;gap:8px;flex:0 0 auto">
<a class="theme-btn" href="../stats.html">К статистике</a>
<button class="theme-btn" id="themeBtn" type="button">Тема</button>
</div>
</header>
HTML

[ -n "$msg" ] && printf '<p class="msg-ok">%s</p>\n' "$(html_escape "$msg")"
[ -n "$err" ] && printf '<p class="msg-err">%s</p>\n' "$err"

cur_auth_user=$(html_escape "$STATS_AUTH_USER")

# Кандидаты гео-фильтра из текущего config.yaml - те же, что install.sh
# предложил бы при переустановке (providers.awk ищет exclude-filter у
# proxy-providers). Файла может не быть или providers.awk не найти в нём
# провайдеров - тогда просто нет подсказок, поле остаётся обычным текстовым.
BLOCK_COUNT=0
CONFIG_YAML=$DIR/config.yaml
if [ -f "$CONFIG_YAML" ] && [ -n "${UPDATE_PROVIDERS_AWK:-}" ] && [ -f "$UPDATE_PROVIDERS_AWK" ]; then
  block_candidates=$(awk -v CONFIG="$CONFIG_YAML" -v CONFDIR="$DIR" -f "$UPDATE_PROVIDERS_AWK" "$CONFIG_YAML" 2>/dev/null | grep -E '^BLOCK_(COUNT|[0-9]+)=')
  [ -n "$block_candidates" ] && eval "$block_candidates"
fi
geo_filter_options=""
i=1
while [ "$i" -le "$BLOCK_COUNT" ]; do
  eval "cand=\$BLOCK_$i"
  geo_filter_options="$geo_filter_options<option value=\"$(html_escape "$cand")\">
"
  i=$((i + 1))
done

cat <<HTML
<form method="post">
<div class="card">
<h2>Гео-фильтр (BLOCK)</h2>
<label for="geo_filter">Регулярное выражение для исключения нод</label>
<input type="text" id="geo_filter" name="geo_filter" list="geo_filter_options" value="$(html_escape "$BLOCK")" autocomplete="off">
<datalist id="geo_filter_options">
$geo_filter_options</datalist>
<p class="hint">Обязательное поле - без него подписка может подставить российскую ноду, которая выиграет замер по пингу. Подсказки в списке - варианты exclude-filter, найденные в текущем config.yaml.</p>
</div>
<div class="card">
<h2>График по нодам</h2>
<label for="node_cap">Число нод на графике (1-8)</label>
<input type="number" min="1" max="8" id="node_cap" name="node_cap" value="$(html_escape "$STATS_NODE_CAP")">
<p class="hint">Больше 8 не поддерживается - столько цветов в палитре легенды.</p>
</div>
<div class="card">
<h2>Хранение истории</h2>
<label for="keep_runs">Хранить прогонов (0 = не ограничивать)</label>
<input type="number" min="0" id="keep_runs" name="keep_runs" value="$(html_escape "$HISTORY_KEEP_RUNS")">
<label for="keep_days">Хранить дней (0 = не ограничивать)</label>
<input type="number" min="0" id="keep_days" name="keep_days" value="$(html_escape "$HISTORY_KEEP_DAYS")">
<p class="hint">Нельзя занулить оба сразу.</p>
</div>
<div class="card">
<h2>Защита формы настройки</h2>
<p class="hint">Страница статистики (stats.html) всегда открыта без пароля. Этой формой можно закрыть только саму настройку.</p>
<label for="auth_user">Логин</label>
<input type="text" id="auth_user" name="auth_user" placeholder="$([ -n "$cur_auth_user" ] && echo "текущий: $cur_auth_user" || echo "не задан")" autocomplete="off">
<label for="auth_pass">Новый пароль</label>
<input type="password" id="auth_pass" name="auth_pass" placeholder="оставьте пустым, если не меняете" autocomplete="new-password">
<div class="row-checkbox">
<input type="checkbox" id="no_auth" name="no_auth" value="1">
<label for="no_auth">Отключить защиту (доступ без пароля)</label>
</div>
</div>
<button class="submit" type="submit">Сохранить</button>
</form>
</div>
<script>
(function(){
var KEY='speedtest2-theme';
var root=document.documentElement;
var btn=document.getElementById('themeBtn');
function label(){var cur=root.getAttribute('data-theme');btn.textContent=cur==='dark'?'Светлая тема':cur==='light'?'Тёмная тема':'Тема: авто';}
function apply(t){if(t){root.setAttribute('data-theme',t);}else{root.removeAttribute('data-theme');}label();}
var saved=null;
try{saved=localStorage.getItem(KEY);}catch(e){}
apply(saved);
btn.addEventListener('click',function(){
var cur=root.getAttribute('data-theme');
var next=cur==='dark'?'light':cur==='light'?null:'dark';
apply(next);
try{if(next){localStorage.setItem(KEY,next);}else{localStorage.removeItem(KEY);}}catch(e){}
});
})();
</script>
HTML
