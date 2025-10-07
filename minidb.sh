#!/usr/bin/env zsh

# ./minidb.sh create users.tsv id name email age
# ./minidb.sh insert users.tsv id=1 name=Bo email=bo@test.com age=41
# ./minidb.sh insert users.tsv id=2 name=Spencer email=sp@test.com age=12
# # All columns
# ./minidb.sh select users.tsv
# # Projection + equality
# ./minidb.sh select users.tsv --cols=name,email --where='id=1'
# # Regex (bash needs quotes)
# ./minidb.sh select users.tsv --where='name~/^S/'
# # Update
# ./minidb.sh update users.tsv --set=age=13 --where='name=Spencer'
# # Delete
# ./minidb.sh delete users.tsv --where='id=1'


set -euo pipefail

DELIM=$'\t'   # TSV
HEADER_PREFIX="# "
LOCKSUFFIX=".lockdir"

function lock() {
  local f="$1"; local l="${f}${LOCKSUFFIX}"
  local waited=0
  while ! mkdir "$l" 2>/dev/null; do
    sleep 0.05
    waited=$((waited+1))
    # fail after ~5s to avoid infinite waits
    if (( waited > 100 )); then
      echo "lock: timeout acquiring $l" >&2
      exit 1
    fi
  done
  trap 'rmdir "$l" 2>/dev/null || true' EXIT
}

function require_table() {
  [[ -f "$1" ]] || { echo "no such table: $1" >&2; exit 1; }
}

# Read header columns (space-separated)
function cols_of() {
  # prints: col1 col2 ...
  sed -n "1{s/^${HEADER_PREFIX}//;p}" "$1" | tr "$DELIM" ' '
}

function col_index() {
  # 1-based column index by name
  local tbl="$1" name="$2"
  local i=1
  while IFS= read -r c; do
    [[ "$c" == "$name" ]] && { echo "$i"; return 0; }
    i=$((i+1))
  done < <(cols_of "$tbl" | tr ' ' '\n')
  echo "unknown column: $name" >&2
  exit 1
}

function create() {
  local tbl="$1"; shift
  [[ $# -gt 0 ]] || { echo "usage: $0 create table.tsv col1 col2 ..." >&2; exit 1; }
  lock "$tbl"
  if [[ -s "$tbl" ]]; then
    echo "refusing to overwrite existing table: $tbl" >&2; exit 1
  fi
  local header="$HEADER_PREFIX$(printf "%s" "$1"; shift; for c in "$@"; do printf "%s%s" "$DELIM" "$c"; done)"
  printf "%s\n" "$header" > "$tbl"
}

function insert() {
  local tbl="$1"; shift
  require_table "$tbl"
  lock "$tbl"
  # Build an associative array col->value from key=value pairs
  declare -A kv=()
  for pair in "$@"; do
    [[ "$pair" == *"="* ]] || { echo "bad pair: $pair (use col=value)" >&2; exit 1; }
    local k="${pair%%=*}"; local v="${pair#*=}"
    kv["$k"]="$v"
  done
  # Emit row in header order
  local cols; cols=($(cols_of "$tbl"))
  local out=""
  for c in "${cols[@]}"; do
    local v="${kv[$c]:-}"
    # forbid tabs in values to keep TSV well-formed
    [[ "$v" != *$'\t'* ]] || { echo "value for $c contains tab; refuse" >&2; exit 1; }
    if [[ -z "$out" ]]; then out="$v"; else out+="$DELIM$v"; fi
  done
  printf "%s\n" "$out" >> "$tbl"
}

# WHERE: either col=value  OR  col~REGEX
function parse_where() {
  local tbl="$1" where="$2"
  local op col val idx
  if [[ "$where" == *"~"* ]]; then
    op="~"; col="${where%%~*}"; val="${where#*~}"
    idx=$(col_index "$tbl" "$col")
    printf '($%d ~ %s)' "$idx" "$val"
  elif [[ "$where" == *"="* ]]; then
    op="="; col="${where%%=*}"; val="${where#*=}"
    idx=$(col_index "$tbl" "$col")
    # Escape backslashes and double quotes in val for AWK string literal
    val=${val//\\/\\\\}; val=${val//\"/\\\"}
    printf '($%d == "%s")' "$idx" "$val"
  else
    echo "bad WHERE (use col=value or col~REGEX)" >&2; exit 1
  fi
}

function select_cmd() {
  local tbl="$1"; shift
  require_table "$tbl"
  local cols="*"; local where=""; local i
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cols=*) cols="${1#--cols=}";;
      --where=*) where="${1#--where=}";;
      *) echo "unknown arg: $1" >&2; exit 1;;
    esac
    shift
  done
  local cols_list; cols_list=($(cols_of "$tbl"))
  # Map projection
  local proj_idxs=()
  if [[ "$cols" == "*" ]]; then
    for ((i=1;i<=${#cols_list[@]};i++)); do proj_idxs+=("$i"); done
  else
    IFS=',' read -r -a want <<<"$cols"
    for w in "${want[@]}"; do
      proj_idxs+=("$(col_index "$tbl" "$w")")
    done
  fi
  local filter='1'
  if [[ -n "$where" ]]; then
    filter="$(parse_where "$tbl" "$where")"
  fi
  awk -v OFS='\t' -v header="$HEADER_PREFIX" -v filter="$filter" -v idxs="$(printf "%s " "${proj_idxs[@]}")" '
    BEGIN{
      split(idxs, P, " ")
    }
    NR==1{
      # project header
      sub("^"header, "", $0)
      n=split($0, H, "\t")
      line=""
      for(i=1;i<=length(P);i++){
        if(P[i]!=""){ if(line!="") line=line OFS; line=line H[P[i]] }
      }
      print line
      next
    }
    {
      # apply filter
      if (eval(filter)) {
        line=""
        for(i=1;i<=length(P);i++){
          if(P[i]!=""){ if(line!="") line=line OFS; line=line $P[i] }
        }
        print line
      }
    }
  ' "$tbl"
}

function update_cmd() {
  local tbl="$1"; shift
  require_table "$tbl"
  local set="" where=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --set=*) set="${1#--set=}";;
      --where=*) where="${1#--where=}";;
      *) echo "unknown arg: $1" >&2; exit 1;;
    esac; shift
  done
  [[ -n "$set" && -n "$where" ]] || { echo "update needs --set and --where" >&2; exit 1; }
  # parse set as col=value (single pair)
  [[ "$set" == *"="* ]] || { echo "bad --set (use col=value)" >&2; exit 1; }
  local scol="${set%%=*}" sval="${set#*=}"
  local sidx; sidx=$(col_index "$tbl" "$scol")
  local filter; filter="$(parse_where "$tbl" "$where")"
  lock "$tbl"
  awk -v OFS='\t' -v header="$HEADER_PREFIX" -v sidx="$sidx" -v sval="$sval" -v filter="$filter" '
    NR==1{ print; next }
    {
      if (eval(filter)) { $sidx = sval }
      print
    }
  ' "$tbl" > "${tbl}.tmp" && mv "${tbl}.tmp" "$tbl"
}

function delete_cmd() {
  local tbl="$1"; shift
  require_table "$tbl"
  local where=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --where=*) where="${1#--where=}";;
      *) echo "unknown arg: $1" >&2; exit 1;;
    esac; shift
  done
  [[ -n "$where" ]] || { echo "delete needs --where" >&2; exit 1; }
  local filter; filter="$(parse_where "$tbl" "$where")"
  lock "$tbl"
  awk -v header="$HEADER_PREFIX" -v filter="$filter" '
    NR==1{ print; next }
    { if (!eval(filter)) print }
  ' "$tbl" > "${tbl}.tmp" && mv "${tbl}.tmp" "$tbl"
}

function usage() {
  cat >&2 <<EOF
Usage:
  $0 create  table.tsv col1 col2 ...
  $0 insert  table.tsv col1=val1 col2=val2 ...
  $0 select  table.tsv [--cols=colA,colB|*] [--where='col=value'|--where='col~/regex/']
  $0 update  table.tsv --set=col=value --where='col=value|col~/regex/'
  $0 delete  table.tsv --where='col=value|col~/regex/'
EOF
  exit 1
}

cmd="${1:-}"; [[ -n "${cmd:-}" ]] || usage; shift || true
case "$cmd" in
  create) create "$@";;
  insert) insert "$@";;
  select) select_cmd "$@";;
  update) update_cmd "$@";;
  delete) delete_cmd "$@";;
  *) usage;;
esac
