# Миграция структуры конфига проекта. YAML общего назначения не разбирается.
# Значения сохраняются текстом, отчёт содержит только типы и имена полей.
BEGIN {
  scalar_indent=-1
  split("log-level allow-lan redir-port tproxy-port port socks-port mixed-port bind-address find-process-mode unified-delay external-controller external-ui external-ui-url secret authentication skip-auth-prefixes lan-allowed-ips lan-disallowed-ips ipv6 profile sniffer routing-mark", list, " ")
  for (i in list) local_key[list[i]]=1
  managed["anchors"]=managed["proxies"]=managed["proxy-providers"]=managed["proxy-groups"]=managed["rule-providers"]=managed["rules"]=managed["dns"]=managed["listeners"]=1
  # Служебный вход mihomo-speedtest (замер WG/AWG через основное ядро) берётся
  # из шаблона; одноимённый вход источника заменяется, чужой вход на его
  # порту или такой же порт в локальных ключах - отказ.
  SERVICE_LISTENER="mst-speedtest"; SERVICE_PORT="7896"
  split("port mixed-port socks-port redir-port tproxy-port", port_keys, " ")
}
# Причина отказа - в REASONF (первая же, дальше не перезаписывается).
# Только имена ключей/провайдеров и номера строк: значения (ссылки
# подписок, пароли) в причину не попадают.
# busybox awk (роутер) требует объявлять функцию до первого вызова -
# порядок функций ниже важен; конкатенацию со скобками пишем без
# пробела "имя (" - иначе busybox видит вызов функции.
function bad(reason) {
  if(!failed && REASONF!="" && reason!="") {printf "%s\n", reason > REASONF; close(REASONF)}
  failed=1; exit 1
}
# Разделитель списка: "" перед первым элементом, ", " перед остальными.
# Не "x=x (n++ ? ...)": busybox awk читает "имя (" как вызов функции.
function sep_next(n) {return (n ? ", " : "")}
function where() {return (side==1 ? "конфиг" : "шаблон") ", строка " FNR}
function trim(s) { sub(/^[ \t]+/,"",s); sub(/[ \t\r]+$/,"",s); return s }
function header(s, t) { t=s; sub(/:.*/,"",t); return t }
{
  side=(FILENAME==SOURCE ? 1 : 2)
  line=$0; sub(/\r$/,"",line)
  if (line ~ /\t/) bad(where() ": табуляция - YAML допускает только пробелы")
  if (line ~ /^---/ || line ~ /^\.\.\./) bad(where() ": разделитель документов YAML (--- или ...) - нужен один документ")
  if (line ~ /^[A-Za-z0-9_-]+:/) {
    key=header(line)
    if (seen[side,key]++) bad(where() ": ключ " key ": повторяется")
    order[side,++nkeys[side]]=key
  } else if (line ~ /^[^ #]/) bad(where() ": строка без отступа не похожа на ключ верхнего уровня (ключ в кавычках, список или поток?)")
  sections[side,key]=sections[side,key] line "\n"
}
function save_provider(name,part) {
  if (provider_seen[name]++) bad("proxy-providers: провайдер " name " повторяется")
  if (name=="fast") {if(part !~ /\n    type: file[ ]*\n/ || part ~ /\n    url:/) bad("proxy-providers: провайдер fast зарезервирован под быстрый пул и должен быть type: file без url - переименуйте свою подписку fast"); return}
  if (part ~ /\n    type: file[ ]*\n/) {print "REVIEW|file-provider-replaced|" name > REPORT;return}
  if (part !~ /\n    url:/) bad("proxy-providers: у провайдера " name " нет url: на отступе 4 пробела (поддерживаются http-подписки и type: file)")
  # Ограниченная структура ключей с именами проекта, значения не интерпретируем.
  sub(/\n[ \n]*$/,"\n",part)
  providers=providers part
  subnames=subnames sep_next(nprov++) name
  print "PRESERVED|subscription|" name > REPORT
}
function extract_providers(text, a,n,j,s,name,part,type,names) {
  n=split(text,a,"\n"); name=""; part=""
  for (j=2;j<=n;j++) {
    s=a[j]
    if (s ~ /^  [A-Za-z0-9_-]+:[ ]*$/) {
      if (name!="") save_provider(name,part)
      name=trim(s);sub(/:.*$/,"",name);part=s "\n"
    } else if(s ~ /^  [^ #]/) bad("proxy-providers: имя провайдера должно быть простым словом (латиница, цифры, - и _) без кавычек, а параметры - с отступом 4 пробела")
    else if (name!="" && s !~ /^  # --- SUBSCRIPTIONS:/ && s !~ /^#/) part=part s "\n"
  }
  if (name!="") save_provider(name,part)
}
function unquote(v) {v=trim(v);if(v ~ /^".*"$/ || v ~ /^\047.*\047$/) v=substr(v,2,length(v)-2);return v}
function save_listener(entry,name,port) {
  if(name=="" || name ~ /[|]/) bad("listeners: у входа нет name или в name есть символ |")
  if(listener_seen[name]++) bad("listeners: вход " name " повторяется")
  if(name==SERVICE_LISTENER) return
  if(port==SERVICE_PORT) bad("listeners: вход " name " занимает порт " SERVICE_PORT ", нужный mihomo-speedtest - смените порт")
  listenertext=listenertext entry
  nlisteners++
}
# Свои входы пользователя: только блочные записи "  - ключ: ..." с
# вложенными строками на 4+ пробела. Служебный вход не переносится.
function extract_listeners(text, a,n,j,s,entry,name,port) {
  n=split(text,a,"\n")
  if(a[1] !~ /^listeners:[ ]*(\[\])?[ ]*$/) bad("listeners: поддерживается только блочный список (каждый вход с \"  - \")")
  if(a[1] ~ /\[\]/) return
  entry=""
  for(j=2;j<=n;j++) {
    s=a[j]
    if(s ~ /^[ ]*$/ || s ~ /^#/ || s ~ /^  #/) continue
    if(s ~ /^  - [A-Za-z0-9_-]+:/) {
      if(entry!="") save_listener(entry,name,port)
      entry=s "\n";name="";port=""
    } else if(s ~ /^    / && entry!="") entry=entry s "\n"
    else bad("listeners: поддерживается только блочный список, параметры входа - с отступом 4 пробела")
    if(s ~ /^(  - |    )name:/) {name=s;sub(/^[ -]*name:/,"",name);name=unquote(name)}
    if(s ~ /^(  - |    )port:/) {port=s;sub(/^[ -]*port:/,"",port);port=unquote(port)}
  }
  if(entry!="") save_listener(entry,name,port)
}
function static_names(text, side,a,n,j,s,value) {
  n=split(text,a,"\n")
  for (j=2;j<=n;j++) {
    s=a[j]
    if (s ~ /^  - name:/) {
      value=s;sub(/^  - name:[ ]*/,"",value);value=trim(value)
      if (value=="" || value ~ /[|\r\n]/) bad("proxies: пустое имя ноды или в имени есть символ |")
      if (side==1) { staticnames=staticnames sep_next(nstatic++) value }
      else template_names[value]=1
    } else if (s ~ /^  - /) bad("proxies: у каждой ноды первым ключом должен идти name (\"  - name: ...\")")
  }
}
# Разбивает только однострочные flow-списки ссылок, сохраняя кавычки и запятые.
function remap_refs(s, start,end,body,j,ch,quote,escape,token,count,result,inserted) {
  if (s !~ /proxies:[ ]*\[/) return s
  start=index(s,"[");end=0;quote="";escape=0;token="";count=0
  for (j=start+1;j<=length(s);j++) {
    ch=substr(s,j,1)
    if (quote!="") {
      token=token ch
      if (escape) escape=0
      else if (quote=="\"" && ch=="\\") escape=1
      else if (ch==quote) {
        if (quote=="\047" && substr(s,j+1,1)=="\047") {token=token "\047";j++}
        else quote=""
      }
    } else if (ch=="\047" || ch=="\"") {quote=ch;token=token ch}
    else if (ch=="," || ch=="]") {
      token=trim(token)
      if (token in template_names) {
        if (!inserted) {if (nstatic) result=result sep_next(count++) staticnames;inserted=1}
      } else if (token!="") result=result sep_next(count++) token
      token=""
      if (ch=="]") {end=j;break}
    } else token=token ch
  }
  if (!end || quote!="") bad("proxy-groups/anchors: не удалось разобрать однострочный список proxies: [...]")
  return substr(s,1,start) result substr(s,end)
}
# Проверяет ссылки вне кавычек и комментариев, не исполняя YAML.
function aliases(s, j,ch,quote,escape,name,k,previous,indent) {
  match(s,/[^ ]/);indent=RSTART-1
  if(scalar_indent>=0) {
    if(s ~ /^[ ]*$/ || indent>scalar_indent) return
    scalar_indent=-1
  }
  for(j=1;j<=length(s);j++) {
    ch=substr(s,j,1)
    if(quote!="") {
      if(escape) escape=0
      else if(quote=="\"" && ch=="\\") escape=1
      else if(ch==quote) {
        if(quote=="\047" && substr(s,j+1,1)=="\047") j++
        else quote=""
      }
    } else if(ch=="#" && (j==1 || substr(s,j-1,1) ~ /[ ]/)) break
    else if((ch=="\047" || ch=="\"") && (j==1 || substr(s,j-1,1) ~ /[ :,[{-]/)) quote=ch
    else if((ch=="|" || ch==">") && j>1 && substr(s,j-1,1)==" " && substr(s,j) ~ /^[|>][0-9+-]*[ ]*(#.*)?$/) {scalar_indent=indent;break}
    else if((ch=="*" || ch=="&") && (j==1 || substr(s,j-1,1) ~ /[ :,[{-]/)) {
      name="";k=j+1
      while(substr(s,k,1) ~ /^[A-Za-z0-9_-]$/) {name=name substr(s,k,1);k++}
      if(name=="") bad("якорь или ссылка (& или *) без имени")
      if(ch=="&") definitions[name]=1;else references[name]=1
      j=k-1
    }
  }
}
function is_marker(s,name) {return s ~ ("^[ ]*# --- " name " ---($|[ ])")}
function marker_position(text,name, a,n,j,offset) {
  n=split(text,a,"\n");offset=1
  for(j=1;j<=n;j++) {if(is_marker(a[j],name)) return offset;offset+=length(a[j])+1}
  return 0
}
function marker_count(text,name, a,n,j,k) {
  n=split(text,a,"\n");k=0
  for(j=1;j<=n;j++) if(is_marker(a[j],name)) k++
  return k
}
function render(text, section, a,n,j,s,subsection,proxies,dns,listeners) {
  n=split(text,a,"\n")
  for(j=1;j<n;j++) {
    s=a[j]
    if(is_marker(s,"SUBSCRIPTIONS:BEGIN")) {print s > OUT;printf "%s",providers > OUT;subsection=1;continue}
    if(is_marker(s,"SUBSCRIPTIONS:END")) {subsection=0;print s > OUT;continue}
    if(is_marker(s,"STATIC_PROXIES:BEGIN")) {print s > OUT;printf "%s",statictext > OUT;proxies=1;continue}
    if(is_marker(s,"STATIC_PROXIES:END")) {proxies=0;print s > OUT;continue}
    if(is_marker(s,"STATIC_DNS:BEGIN")) {print s > OUT;printf "%s",sections[1,"dns"] > OUT;dns=1;continue}
    if(is_marker(s,"STATIC_LISTENERS:BEGIN")) {print s > OUT;printf "%s",listenertext > OUT;listeners=1;continue}
    if(is_marker(s,"STATIC_LISTENERS:END")) {listeners=0;print s > OUT;continue}
    if(is_marker(s,"STATIC_DNS:END")) {dns=0;print s > OUT;continue}
    if(subsection || proxies || dns || listeners) continue
    if(s ~ /^  sub-names: &sub-names /) s="  sub-names: &sub-names [" subnames "]"
    print ((section=="proxy-groups" || section=="anchors") ? remap_refs(s) : s) > OUT
  }
}
END {
  if(failed) exit 1
  if(!seen[1,"proxy-providers"]) bad("в конфиге нет секции proxy-providers: - миграция переносит подписки оттуда")
  if(sections[1,"proxy-providers"] !~ /^proxy-providers:[ ]*\n/) bad("proxy-providers: поддерживается только блочная запись (proxy-providers: и провайдеры на следующих строках), не { ... }")
  # Нет своих нод - то же, что "proxies: []" (многие конфиги живут только
  # на подписках и секцию proxies не заводят вовсе).
  if(!seen[1,"proxies"]) {seen[1,"proxies"]=1; sections[1,"proxies"]="proxies: []\n"}
  if(sections[1,"proxies"] !~ /^proxies:[ ]*(\[\])?[ ]*\n/) bad("proxies: поддерживается блочный список нод или пустой proxies: [] - не однострочная запись")
  if(sections[2,"proxy-providers"] !~ /^proxy-providers:[ ]*\n/ || !seen[2,"anchors"] || !seen[2,"proxy-groups"]) bad("шаблон config.example.yaml повреждён (нет proxy-providers/anchors/proxy-groups) - переустановите проект")
  template="";for(j=1;j<=nkeys[2];j++) template=template sections[2,order[2,j]]
  split("SUBSCRIPTIONS STATIC_PROXIES STATIC_DNS STATIC_LISTENERS",markers," ")
  for(j=1;j<=4;j++) if(marker_count(template,markers[j] ":BEGIN")!=1 || marker_count(template,markers[j] ":END")!=1) bad("шаблон config.example.yaml повреждён (маркер " markers[j] ") - переустановите проект")
  for(j=1;j<=4;j++) if(marker_position(template,markers[j] ":BEGIN")>marker_position(template,markers[j] ":END")) bad("шаблон config.example.yaml повреждён (порядок маркеров " markers[j] ") - переустановите проект")
  if(sections[2,"anchors"] !~ /\n  sub-names: &sub-names /) bad("шаблон config.example.yaml повреждён (нет sub-names) - переустановите проект")
  if(marker_position(sections[1,"dns"],"STATIC_DNS:END")) sections[1,"dns"]=substr(sections[1,"dns"],1,marker_position(sections[1,"dns"],"STATIC_DNS:END")-1)
  sub(/\n[ \n]*$/,"\n",sections[1,"dns"])
  # Файлы создаются только после первичной проверки; обёртка не публикует ошибочный результат.
  printf "" > OUT; printf "" > REPORT
  extract_providers(sections[1,"proxy-providers"])
  static_names(sections[1,"proxies"],1);static_names(sections[2,"proxies"],2)
  old_static=sections[1,"proxies"];n=split(old_static,rows,"\n")
  for(j=2;j<n;j++) {
    if(rows[j] ~ /^  # --- STATIC_PROXIES:END/) break
    if(rows[j] !~ /^  # --- STATIC_PROXIES:/ && rows[j] !~ /^#/) statictext=statictext rows[j] "\n"
  }
  sub(/\n[ \n]*$/,"\n",statictext)
  print "PRESERVED|section|proxies" > REPORT
  if(seen[1,"listeners"]) extract_listeners(sections[1,"listeners"])
  if(failed) exit 1
  if(nlisteners) print "PRESERVED|section|listeners" > REPORT
  for(j=1;j<=5;j++) if(seen[1,port_keys[j]]) {
    v=sections[1,port_keys[j]];sub(/^[^:]*:/,"",v);sub(/\n.*/,"",v)
    if(unquote(v)==SERVICE_PORT) bad(port_keys[j] ": порт " SERVICE_PORT " нужен mihomo-speedtest - смените порт")
  }
  if(failed) exit 1
  if(seen[1,"dns"]) print "PRESERVED|section|dns" > REPORT
  # DNS-маркеры в преамбуле относятся к последнему локальному ключу шаблона.
  for(j=1;j<=nkeys[2];j++) {
    key=order[2,j]
    if(local_key[key] && seen[1,key]) {
      old=sections[1,key];new=sections[2,key]
      # Комментарии-маркеры DNS берём из нового шаблона, не дублируем старые.
      if(marker_position(old,"STATIC_DNS:BEGIN")) old=substr(old,1,marker_position(old,"STATIC_DNS:BEGIN")-1)
      if(marker_position(new,"STATIC_DNS:BEGIN")) {
        prefix=substr(new,1,marker_position(new,"STATIC_DNS:BEGIN")-1)
        sections[2,key]=old substr(new,length(prefix)+1)
      } else sections[2,key]=old
      print "PRESERVED|local-key|" key > REPORT
    }
  }
  for(j=1;j<=nkeys[1];j++) {
    key=order[1,j]
    if(local_key[key] && !seen[2,key]) {printf "%s",sections[1,key] > OUT;print "PRESERVED|local-key|" key > REPORT}
    else if(!local_key[key] && !managed[key]) print "REVIEW|unknown-top-key|" key > REPORT
    else if(key=="anchors" || key=="proxy-groups" || key=="rule-providers" || key=="rules") {
      if(sections[1,key]!=sections[2,key]) print "REVIEW|managed-section-replaced|" key > REPORT
    }
  }
  for(j=1;j<=nkeys[2];j++) render(sections[2,order[2,j]],order[2,j])
  close(OUT);close(REPORT)
  while((getline candidate_line < OUT)>0) aliases(candidate_line)
  close(OUT)
  for(alias_name in references) if(!(alias_name in definitions)) bad("ссылка *" alias_name " осталась без определения: якорь &" alias_name " был в заменяемой секции (anchors/proxy-groups/rules) - перенесите значение в саму ноду или настройку")
}
