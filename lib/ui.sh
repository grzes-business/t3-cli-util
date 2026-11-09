# shellcheck shell=bash disable=SC2034  # glyph globals are consumed by other lib files
# Presentation helpers: glyphs, bars and aligned tables.
#
# Output stays readable without colour (pipes, NO_COLOR) and without Unicode
# (non-UTF-8 locales, or T3CTL_ASCII=1): every glyph has an ASCII fallback.

ui_init() {
  local loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  if [[ ${T3CTL_ASCII:-0} != 1 && ($loc == *[Uu][Tt][Ff]-8* || $loc == *[Uu][Tt][Ff]8*) ]]; then
    U_OK='●' U_RISK='▲' U_NO='✖' U_UP='↑' U_DOWN='↓' U_FULL='█' U_EMPTY='░'
    U_RULE='─' U_DOT='·' U_ARROW='→' U_DONE='✔' U_ELL='…'
  else
    U_OK='o' U_RISK='!' U_NO='x' U_UP='+' U_DOWN='-' U_FULL='#' U_EMPTY='.'
    U_RULE='-' U_DOT='-' U_ARROW='->' U_DONE='ok' U_ELL='~'
  fi
}
ui_init

# Repeat a string N times.
ui_repeat() {
  local s=$1 n=$2 out=''
  while ((n-- > 0)); do out+=$s; done
  printf '%s' "$out"
}

# Horizontal bar: ui_bar VALUE MAX [WIDTH]. Unknown values give blank space;
# any positive value shows at least one cell.
ui_bar() {
  local v=$1 m=$2 w=${3:-10} f
  if [[ ! $v =~ ^[0-9]+$ || ! $m =~ ^[0-9]+$ ]] || ((m == 0)); then
    printf '%*s' "$w" ''
    return
  fi
  f=$((v * w / m))
  ((v > 0 && f == 0)) && f=1
  ((f > w)) && f=$w
  ui_repeat "$U_FULL" "$f"
  ui_repeat "$U_EMPTY" $((w - f))
}

# Truncate to MAX characters, marking the cut.
ui_trunc() {
  local s=$1 max=$2
  if ((${#s} > max)); then
    printf '%s%s' "${s:0:max-1}" "$U_ELL"
  else
    printf '%s' "$s"
  fi
}

ui_color() {
  case $1 in
    g) printf '%s' "$C_GRN" ;;
    y) printf '%s' "$C_YEL" ;;
    r) printf '%s' "$C_RED" ;;
    d) printf '%s' "$C_DIM" ;;
    b) printf '%s' "$C_BLD" ;;
  esac
}

# Split a tab-separated line into UI_CELLS (empty cells are preserved).
ui_split() {
  local rest=$1$'\t'
  UI_CELLS=()
  while [[ -n $rest ]]; do
    UI_CELLS+=("${rest%%$'\t'*}")
    rest=${rest#*$'\t'}
  done
}

# A cell may start with a colour tag: {g} green, {y} yellow, {r} red, {d} dim,
# {b} bold. Sets UI_TAG and UI_PLAIN.
ui_plain() {
  UI_TAG='' UI_PLAIN=$1
  if [[ $1 == '{'[gyrdb]'}'* ]]; then
    UI_TAG=${1:1:1}
    UI_PLAIN=${1:3}
  fi
}

# Print an aligned table from tab-separated rows on stdin; the first row is
# the header. ALIGN is one letter per column (l or r, default l). A row that
# is exactly "@rule" prints a separator. The last column is never padded.
#   printf '%s\n' "$rows" | ui_table lrl
ui_table() {
  local align=${1:-} line i n total w pad out last row=0
  local -a rows=() widths=()
  while IFS= read -r line; do rows+=("$line"); done
  ((${#rows[@]})) || return 0
  for line in "${rows[@]}"; do
    [[ $line == @rule ]] && continue
    ui_split "$line"
    for ((i = 0; i < ${#UI_CELLS[@]}; i++)); do
      ui_plain "${UI_CELLS[i]}"
      n=${#UI_PLAIN}
      ((n > ${widths[i]:-0})) && widths[i]=$n
    done
  done
  total=0
  for w in "${widths[@]}"; do total=$((total + w + 2)); done
  ((total -= 2))
  for line in "${rows[@]}"; do
    if [[ $line == @rule ]]; then
      printf '%s%s%s\n' "$C_DIM" "$(ui_repeat "$U_RULE" "$total")" "$C_RST"
      continue
    fi
    ui_split "$line"
    out=''
    last=$((${#UI_CELLS[@]} - 1))
    for ((i = 0; i <= last; i++)); do
      ui_plain "${UI_CELLS[i]}"
      pad=$((${widths[i]:-0} - ${#UI_PLAIN}))
      ((pad < 0)) && pad=0
      local cell=$UI_PLAIN tag=$UI_TAG
      ((row == 0)) && tag=b
      if [[ ${align:i:1} == r ]]; then
        cell=$(printf '%*s%s' "$pad" '' "$cell")
      elif ((i < last)); then
        cell=$(printf '%s%*s' "$cell" "$pad" '')
      fi
      if [[ -n $tag && -n $C_RST ]]; then
        cell="$(ui_color "$tag")$cell$C_RST"
      fi
      out+=$cell
      ((i < last)) && out+='  '
    done
    printf '%s\n' "$out"
    if ((row == 0)); then
      printf '%s%s%s\n' "$C_DIM" "$(ui_repeat "$U_RULE" "$total")" "$C_RST"
    fi
    row=$((row + 1))
  done
}

# Section heading.
ui_heading() { printf '\n%s%s%s\n' "$C_BLD" "$1" "$C_RST"; }
