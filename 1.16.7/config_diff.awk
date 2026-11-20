# Сравнение текста корневых разделов без вывода значений конфигурации.
# Запуск: awk -v OLD=/path/old -v NEW=/path/new -f config_diff.awk
# Проверку полной схемы YAML и размера файлов выполняет вызывающий код.
BEGIN {
    if (OLD == "" || NEW == "" || !read_sections(OLD, 1) || !read_sections(NEW, 2)) {
        print "ERROR" > "/dev/stderr"
        exit 1
    }
    printf "["
    separator = ""
    for (i = 1; i <= counts[1]; i++) {
        key = ordered[1, i]
        if (!((2 SUBSEP key) in sections)) {
            emit(key, "removed")
        } else if (sections[1, key] != sections[2, key]) {
            emit(key, "changed")
        }
    }
    for (i = 1; i <= counts[2]; i++) {
        key = ordered[2, i]
        if (!((1 SUBSEP key) in sections)) emit(key, "added")
    }
    print "]"
    exit 0
}

function emit(key, change) {
    printf "%s{\"section\":\"%s\",\"change\":\"%s\"}", separator, key, change
    separator = ","
}

function read_sections(path, side,    line, result, current, key) {
    current = ""
    while ((result = (getline line < path)) > 0) {
        sub(/\r$/, "", line)
        # Корневые комментарии и разделители документа не принадлежат разделу.
        if (line ~ /^#/ || line ~ /^(---|\.\.\.)([ \t]+#.*)?[ \t]*$/) continue
        if (line ~ /^[ \t]*$/) {
            if (current != "") sections[side, current] = sections[side, current] line "\n"
            continue
        }
        if (line ~ /^[ \t]/) {
            if (current == "") { close(path); return 0 }
            sections[side, current] = sections[side, current] line "\n"
            continue
        }
        # Только простые ASCII-ключи: их безопасно помещать в JSON без значений.
        if (line !~ /^[A-Za-z0-9_-]+:([ \t]|$)/) { close(path); return 0 }
        key = line
        sub(/:.*/, "", key)
        if ((side SUBSEP key) in sections) { close(path); return 0 }
        current = key
        ordered[side, ++counts[side]] = key
        sections[side, key] = line "\n"
    }
    close(path)
    return result == 0
}
