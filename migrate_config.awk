# Миграция структуры конфига проекта. YAML общего назначения не разбирается.
# Значения сохраняются текстом, отчёт содержит только типы и имена полей.
BEGIN {
  scalar_indent=-1
  split("log-level allow-lan redir-port tproxy-port port socks-port mixed-port bind-address find-process-mode unified-delay external-controller external-ui external-ui-url secret authentication skip-auth-prefixes lan-allowed-ips lan-disallowed-ips ipv6 profile sniffer routing-mark", list, " ")
  for (i in list) local_key[list[i]]=1
  managed["anchors"]=managed["proxies"]=managed["proxy-providers"]=managed["proxy-groups"]=managed["rule-providers"]=managed["rules"]=managed["dns"]=1
}
function bad() { failed=1; exit 1 }
function trim(s) { sub(/^[ \t]+/,"",s); sub(/[ \t\r]+$/,"",s); return s }
function header(s, t) { t=s; sub(/:.*/,"",t); return t }
{
  side=(FILENAME==SOURCE ? 1 : 2)
  line=$0; sub(/\r$/,"",line)
  if (line ~ /\t/ || line ~ /^---/ || line ~ /^\.\.\./) bad()
  if (line ~ /^[A-Za-z0-9_-]+:/) {
    key=header(line)
    if (seen[side,key]++) bad()
    order[side,++nkeys[side]]=key
  } else if (line ~ /^[^ #]/) bad()
  sections[side,key]=sections[side,key] line "\n"
}
function extract_providers(text, a,n,j,s,name,part,type,names) {
  n=split(text,a,"\n"); name=""; part=""
  for (j=2;j<=n;j++) {
    s=a[j]
    if (s ~ /^  [A-Za-z0-9_-]+:[ ]*$/) {
      if (name!="") save_provider(name,part)
      name=trim(s);sub(/:.*$/,"",name);part=s "\n"
    } else if(s ~ /^  [^ #]/) bad()
    else if (name!="" && s !~ /^  # --- SUBSCRIPTIONS:/ && s !~ /^#/) part=part s "\n"
  }
  if (name!="") save_provider(name,part)
}
function save_provider(name,part) {
  if (provider_seen[name]++) bad()
  if (name=="fast") {if(part !~ /\n    type: file[ ]*\n/ || part ~ /\n    url:/) bad(); return}
  if (part ~ /\n    type: file[ ]*\n/) {print "REVIEW|file-provider-replaced|" name > REPORT;return}
  if (part !~ /\n    url:/) bad()
  # Ограниченная структура ключей с именами проекта, значения не интерпретируем.
  sub(/\n[ \n]*$/,"\n",part)
  providers=providers part
  subnames=subnames (nprov++ ? ", " : "") name
  print "PRESERVED|subscription|" name > REPORT
}
function static_names(text, side,a,n,j,s,value) {
  n=split(text,a,"\n")
  for (j=2;j<=n;j++) {
    s=a[j]
    if (s ~ /^  - name:/) {
      value=s;sub(/^  - name:[ ]*/,"",value);value=trim(value)
      if (value=="" || value ~ /[|\r\n]/) bad()
      if (side==1) { staticnames=staticnames (nstatic++ ? ", " : "") value }
      else template_names[value]=1
    } else if (s ~ /^  - /) bad()
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
        if (!inserted) {if (nstatic) result=result (count++ ? ", " : "") staticnames;inserted=1}
      } else if (token!="") result=result (count++ ? ", " : "") token
      token=""
      if (ch=="]") {end=j;break}
    } else token=token ch
  }
  if (!end || quote!="") bad()
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
      if(name=="") bad()
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
function render(text, section, a,n,j,s,subsection,proxies,dns) {
  n=split(text,a,"\n")
  for(j=1;j<n;j++) {
    s=a[j]
    if(is_marker(s,"SUBSCRIPTIONS:BEGIN")) {print s > OUT;printf "%s",providers > OUT;subsection=1;continue}
    if(is_marker(s,"SUBSCRIPTIONS:END")) {subsection=0;print s > OUT;continue}
    if(is_marker(s,"STATIC_PROXIES:BEGIN")) {print s > OUT;printf "%s",statictext > OUT;proxies=1;continue}
    if(is_marker(s,"STATIC_PROXIES:END")) {proxies=0;print s > OUT;continue}
    if(is_marker(s,"STATIC_DNS:BEGIN")) {print s > OUT;printf "%s",sections[1,"dns"] > OUT;dns=1;continue}
    if(is_marker(s,"STATIC_DNS:END")) {dns=0;print s > OUT;continue}
    if(subsection || proxies || dns) continue
    if(s ~ /^  sub-names: &sub-names /) s="  sub-names: &sub-names [" subnames "]"
    print ((section=="proxy-groups" || section=="anchors") ? remap_refs(s) : s) > OUT
  }
}
END {
  if(failed) exit 1
  if(sections[1,"proxy-providers"] !~ /^proxy-providers:[ ]*\n/ || sections[2,"proxy-providers"] !~ /^proxy-providers:[ ]*\n/) exit 1
  if(sections[1,"proxies"] !~ /^proxies:[ ]*(\[\])?[ ]*\n/) exit 1
  if (!seen[1,"proxy-providers"] || !seen[1,"proxies"] || !seen[2,"anchors"] || !seen[2,"proxy-groups"]) exit 1
  template="";for(j=1;j<=nkeys[2];j++) template=template sections[2,order[2,j]]
  split("SUBSCRIPTIONS STATIC_PROXIES STATIC_DNS",markers," ")
  for(j=1;j<=3;j++) if(marker_count(template,markers[j] ":BEGIN")!=1 || marker_count(template,markers[j] ":END")!=1) exit 1
  for(j=1;j<=3;j++) if(marker_position(template,markers[j] ":BEGIN")>marker_position(template,markers[j] ":END")) exit 1
  if(sections[2,"anchors"] !~ /\n  sub-names: &sub-names /) exit 1
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
  for(alias_name in references) if(!(alias_name in definitions)) bad()
}
