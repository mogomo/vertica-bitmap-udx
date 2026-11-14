# Shared shell functions. Sourced, not run. Expects the repository root as working directory.
# Connection: vsql reads VSQL_HOST, VSQL_PORT, VSQL_USER, VSQL_PASSWORD and VSQL_DATABASE.

# sql_literal TEXT: TEXT as an SQL string literal.
sql_literal() { local s="${1//\'/\'\'}"; printf "'%s'" "$s"; }

# like_prefix TEXT: a LIKE pattern matching strings that start with TEXT (\ _ % escaped).
like_prefix() { local s="${1//\\/\\\\}"; s="${s//_/\\_}"; s="${s//%/\\%}"; printf "'%s%%'" "${s//\'/\'\'}"; }

# ts_literal 'YYYY-MM-DD[ HH:MM[:SS]]': a TIMESTAMP literal; fails on any other text.
ts_literal() {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,6})?)?)?$ ]] \
        || { echo "not a timestamp (YYYY-MM-DD HH:MM:SS): $1" >&2; return 1; }
    printf "'%s'::TIMESTAMP" "${1/T/ }"
}

# fill_placeholders TEXT TENANT SNAPSHOT [WATERMARK]: TEXT with ${tenant}, ${snapshot} and
# ${watermark} replaced. Fails if TEXT uses ${watermark} and none is given.
fill_placeholders() {
    local s="$1" wm=""
    s="${s//\$\{tenant\}/$2}"
    s="${s//\$\{snapshot\}/$3}"
    if [[ "$s" == *'${watermark}'* ]]; then
        [ -n "${4:-}" ] || { echo "a watermark is needed (the text uses \${watermark})" >&2; return 1; }
        wm=$(ts_literal "$4") || return 1
        s="${s//\$\{watermark\}/$wm}"
    fi
    printf '%s\n' "$s"
}

# query_sql NAME TENANT SNAPSHOT [WATERMARK]: the text of sql/queries/NAME.sql with the
# placeholders filled and the final semicolon removed, ready to be embedded as a subquery.
query_sql() {
    local f="sql/queries/$1.sql" s
    [ -f "$f" ] || { echo "query_sql: no such query: $1" >&2; return 1; }
    s=$(fill_placeholders "$(<"$f")" "$2" "$3" "${4:-}") || { echo "query_sql: $1" >&2; return 1; }
    printf '%s\n' "${s%;*}"
}

# family_union_sql TENANT SOURCE_SNAPSHOT WATERMARK DOMAIN [FAMILY ...]: one query returning
# (family, predicate, entity_id) for the families of the catalog (all families of the domain if
# none are named). WATERMARK may be empty if no definition uses ${watermark}. Fails if a named
# family is not in the catalog.
family_union_sql() {
    local tenant="$1" snapshot="$2" wm="$3" domain="$4"; shift 4
    local fs=$'\x1f' rs=$'\x1e' filter="" rows rec fam def out="" f n=0
    if [ $# -gt 0 ]; then
        filter="AND family IN ("
        for f in "$@"; do filter+="$(sql_literal "$f"),"; done
        filter="${filter%,})"
    fi
    rows=$(vsql -X -A -t -q -v ON_ERROR_STOP=1 -F "$fs" -R "$rs" -c \
        "SELECT family, definition FROM bitmap_demo.bitmap_family
         WHERE tenant_id = $tenant AND domain = $(sql_literal "$domain") $filter ORDER BY family") || return 1
    local -a records
    IFS="$rs" read -r -d '' -a records <<< "$rows" || true
    for rec in "${records[@]}"; do
        rec="${rec%$'\n'}"
        [ -z "$rec" ] && continue
        IFS="$fs" read -r -d "" fam def <<< "$rec" || true   # whole record: definitions span lines
        def="${def%$'\n'}"
        [[ "$fam" =~ ^[A-Za-z0-9_]+$ ]] || { echo "family_union_sql: bad family name: $fam" >&2; return 1; }
        def=$(fill_placeholders "$def" "$tenant" "$snapshot" "$wm") || { echo "family_union_sql: family $fam" >&2; return 1; }
        out+="
      UNION ALL SELECT '$fam', * FROM ($def) f_$fam"
        n=$((n + 1))
    done
    if [ $# -gt 0 ] && [ "$n" -ne $# ]; then
        echo "family_union_sql: tenant $tenant domain $domain: not every family of '$*' is in the catalog" >&2
        return 1
    fi
    printf '%s\n' "SELECT family, predicate, entity_id FROM (
      SELECT NULL::VARCHAR(40) AS family, NULL::VARCHAR(80) AS predicate, NULL::INT AS entity_id WHERE FALSE$out) u"
}

# family_branches TENANT SOURCE_SNAPSHOT WATERMARK DOMAIN [FAMILY ...]: the definitions of the
# families, placeholders filled, one record per SELECT: a definition made of several SELECTs
# joined by UNION ALL on a line of its own (outside parentheses) gives one record per SELECT. Record: family, 0x1f, the
# SELECT, 0x1e. Used by the aggregate builder, which groups each SELECT on its own.
family_branches() {
    local tenant="$1" snapshot="$2" wm="$3" domain="$4"; shift 4
    local fs=$'\x1f' rs=$'\x1e' filter="" rows rec fam def f n=0 line branch depth opens closes
    if [ $# -gt 0 ]; then
        filter="AND family IN ("
        for f in "$@"; do filter+="$(sql_literal "$f"),"; done
        filter="${filter%,})"
    fi
    rows=$(vsql -X -A -t -q -v ON_ERROR_STOP=1 -F "$fs" -R "$rs" -c \
        "SELECT family, definition FROM bitmap_demo.bitmap_family
         WHERE tenant_id = $tenant AND domain = $(sql_literal "$domain") $filter ORDER BY family") || return 1
    local -a records
    IFS="$rs" read -r -d '' -a records <<< "$rows" || true
    for rec in "${records[@]}"; do
        rec="${rec%$'\n'}"
        [ -z "$rec" ] && continue
        IFS="$fs" read -r -d "" fam def <<< "$rec" || true
        def="${def%$'\n'}"
        [[ "$fam" =~ ^[A-Za-z0-9_]+$ ]] || { echo "family_branches: bad family name: $fam" >&2; return 1; }
        def=$(fill_placeholders "$def" "$tenant" "$snapshot" "$wm") || { echo "family_branches: family $fam" >&2; return 1; }
        branch=""; depth=0
        while IFS= read -r line; do
            # a UNION ALL line outside every parenthesis separates two SELECTs of the definition
            if [ "$depth" -eq 0 ] && [[ "$line" =~ ^[[:space:]]*[Uu][Nn][Ii][Oo][Nn][[:space:]]+[Aa][Ll][Ll][[:space:]]*$ ]]; then
                printf '%s%s%s%s' "$fam" "$fs" "$branch" "$rs"
                branch=""
            else
                branch+="$line"$'\n'
                opens="${line//[^(]/}"; closes="${line//[^)]/}"
                depth=$((depth + ${#opens} - ${#closes}))
            fi
        done <<< "$def"
        printf '%s%s%s%s' "$fam" "$fs" "$branch" "$rs"
        n=$((n + 1))
    done
    if [ $# -gt 0 ] && [ "$n" -ne $# ]; then
        echo "family_branches: tenant $tenant domain $domain: not every family of '$*' is in the catalog" >&2
        return 1
    fi
}

# catalog_families TENANT DOMAIN: the family names of the catalog, one per line, sorted.
catalog_families() {
    vsql -X -A -t -q -v ON_ERROR_STOP=1 -c "SELECT family FROM bitmap_demo.bitmap_family
        WHERE tenant_id = $1 AND domain = $(sql_literal "$2") ORDER BY family"
}
