# providers.awk
# Разбирает секцию proxy-providers: config.yaml mihomo, печатает на stdout
# shell-присваивания SOURCES/EXTYPE/BLOCK_N, готовые для `eval` в install.sh.
# Якоря и фильтры добавляются следующими задачами плана.
BEGIN {
  in_pp = 0
  prov_indent = -1
  cur_name = ""
  nsrc = 0
  ntype = 0
  nfilter = 0

  if (CONFIG != "") {
    in_anchors = 0
    while ((getline aline < CONFIG) > 0) {
      if (aline ~ /^anchors:[ \t]*$/) { in_anchors = 1; continue }
      if (in_anchors && aline ~ /^[^ \t#]/) in_anchors = 0
      if (in_anchors) collect_anchor(aline)
    }
    close(CONFIG)
  }
}

function collect_anchor(line,    outer, seg, inner, val) {
  outer = ""
  if (match(line, /&[A-Za-z0-9_-]+/)) outer = substr(line, RSTART + 1, RLENGTH - 1)

  if (match(line, /exclude-filter:[ \t]*&[A-Za-z0-9_-]+[ \t]+'[^']*'/)) {
    seg = substr(line, RSTART, RLENGTH)
    match(seg, /&[A-Za-z0-9_-]+/)
    inner = substr(seg, RSTART + 1, RLENGTH - 1)
    match(seg, /'[^']*'/)
    val = substr(seg, RSTART + 1, RLENGTH - 2)
    anchor_filter[inner] = val
    if (outer != "") anchor_filter[outer] = val
  } else if (match(line, /exclude-filter:[ \t]*'[^']*'/)) {
    seg = substr(line, RSTART, RLENGTH)
    match(seg, /'[^']*'/)
    val = substr(seg, RSTART + 1, RLENGTH - 2)
    if (outer != "") anchor_filter[outer] = val
  } else if (outer != "" && match(line, /&[A-Za-z0-9_-]+[ \t]+'[^']*'/)) {
    seg = substr(line, RSTART, RLENGTH)
    match(seg, /'[^']*'/)
    val = substr(seg, RSTART + 1, RLENGTH - 2)
    anchor_filter[outer] = val
  }

  if (match(line, /exclude-type:[ \t]*[A-Za-z0-9|_-]+/)) {
    seg = substr(line, RSTART, RLENGTH)
    sub(/^exclude-type:[ \t]*/, "", seg)
    if (outer != "") anchor_type[outer] = seg
  }
}

/^proxy-providers:[ \t]*$/ { in_pp = 1; next }

in_pp && /^[^ \t#]/ { flush_provider(); in_pp = 0 }

in_pp && $0 ~ /^[ \t]+[A-Za-z0-9_-]+:[ \t]*$/ {
  match($0, /[^ \t]/)
  ind = RSTART - 1
  if (prov_indent < 0) prov_indent = ind
  if (ind == prov_indent) {
    flush_provider()
    cur_name = $0
    sub(/^[ \t]+/, "", cur_name)
    sub(/:.*/, "", cur_name)
    has_url = 0
    is_file = 0
    path = ""
    ex_type = ""
    ex_filter = ""
    merge_name = ""
    next
  }
}

in_pp && cur_name != "" {
  if ($0 ~ /url:/) has_url = 1
  if ($0 ~ /^[ \t]*type:[ \t]*file[ \t]*$/) is_file = 1
  if (match($0, /^[ \t]*path:[ \t]*.*$/)) {
    v = $0
    sub(/^[ \t]*path:[ \t]*/, "", v)
    gsub(/^["']|["'][ \t]*$/, "", v)
    path = v
  }
  if (match($0, /exclude-type:[ \t]*[A-Za-z0-9|_-]+/)) {
    seg = substr($0, RSTART, RLENGTH)
    sub(/^exclude-type:[ \t]*/, "", seg)
    ex_type = seg
  }
  if (match($0, /exclude-filter:[ \t]*'[^']*'/)) {
    seg = substr($0, RSTART, RLENGTH)
    match(seg, /'[^']*'/)
    ex_filter = substr(seg, RSTART + 1, RLENGTH - 2)
  }
  if ($0 ~ /^[ \t]*<<:[ \t]*\*/) {
    v = $0
    sub(/.*\*/, "", v)
    gsub(/[ \t]+$/, "", v)
    merge_name = v
  }
  if (ex_filter == "" && $0 ~ /exclude-filter:[ \t]*\*/) {
    v = $0
    sub(/.*\*/, "", v)
    gsub(/[ \t]+$/, "", v)
    if (v in anchor_filter) ex_filter = anchor_filter[v]
  }
  if (ex_type == "" && $0 ~ /exclude-type:[ \t]*\*/) {
    v = $0
    sub(/.*\*/, "", v)
    gsub(/[ \t]+$/, "", v)
    if (v in anchor_type) ex_type = anchor_type[v]
  }
}

END {
  flush_provider()
  if (nsrc == 0) {
    print "providers.awk: не найдено ни одного проверенного proxy-provider с url" > "/dev/stderr"
    exit 2
  }
  out = sources[0]
  for (i = 1; i < nsrc; i++) out = out " " sources[i]
  printf "SOURCES='%s'\n", out
  if (ntype > 1) {
    printf "providers.awk: у провайдеров найдено %d разных значений exclude-type, используется первое ('%s'), остальные проигнорированы: ", ntype, type_list[0] > "/dev/stderr"
    for (i = 0; i < ntype; i++) {
      if (i > 0) printf ", " > "/dev/stderr"
      printf "'%s'", type_list[i] > "/dev/stderr"
    }
    printf "\n" > "/dev/stderr"
  }
  if (ntype > 0) printf "EXTYPE='%s'\n", type_list[0]
  printf "BLOCK_COUNT='%d'\n", nfilter
  for (i = 0; i < nfilter; i++) printf "BLOCK_%d='%s'\n", i + 1, filter_list[i]
}

function flush_provider() {
  if (cur_name == "") return
  if (!is_file && has_url) {
    if (path == "") {
      printf "providers.awk: провайдер %s без path, пропущен\n", cur_name > "/dev/stderr"
    } else {
      resolved = path
      if (path ~ /^\.\//) resolved = CONFDIR "/" substr(path, 3)
      sources[nsrc++] = resolved
      if (ex_filter == "" && merge_name != "" && (merge_name in anchor_filter)) {
        ex_filter = anchor_filter[merge_name]
      }
      if (ex_type == "" && merge_name != "" && (merge_name in anchor_type)) {
        ex_type = anchor_type[merge_name]
      }
      if (ex_type != "" && !(ex_type in type_seen)) {
        type_seen[ex_type] = 1
        type_list[ntype++] = ex_type
      }
      if (ex_filter != "" && !(ex_filter in filter_seen)) {
        filter_seen[ex_filter] = 1
        filter_list[nfilter++] = ex_filter
      }
    }
  }
  cur_name = ""
}
