#!/usr/bin/env bash
#   notify.sh process <exit-status> <seconds> <command>   (shell hooks)
#   notify.sh claude|codex                                (agent hooks, JSON on stdin)
#   notify.sh bar-refresh                                 (tmux hooks)
#   notify.sh sidebar-toggle [client]                     (key binding)
#   notify.sh sidebar                                     (runs inside the sidebar pane)
#
# Sourcing the file defines the functions without running anything (tests).

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

ENTRY_PREFIX=@pane_notify_entry_
SEP=$'\xe2\x90\x9f'
TEXT_MAX=300

opt() {
  local value
  value="$(tmux show-option -gqv "$1")"
  printf '%s' "${value:-$2}"
}

utf8_locale() {
  local l
  for l in "${LC_ALL:-}" "${LC_CTYPE:-}" "${LANG:-}"; do
    case $l in *.[Uu][Tt][Ff]-8|*.[Uu][Tt][Ff]8|*.[Uu][Tt][Ff]-8@*|*.[Uu][Tt][Ff]8@*)
      printf '%s' "$l"; return 0 ;;
    esac
  done
  locale -a 2>/dev/null | grep -i -m1 -E '^(C|en_US)\.utf-?8$'
}

human_duration() {
  local s=$1
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60))
  else printf '%ds' "$s"
  fi
}

clean() {
  local s=${1//[[:cntrl:]]/ }
  s=${s//"$SEP"/ }
  [ "${#s}" -le "$TEXT_MAX" ] || s="${s:0:TEXT_MAX-1}…"
  printf '%s' "$s"
}

windows_in_view() {
  tmux list-clients -F '#{client_flags}|#{window_id}' | awk -F'|' '","$1"," ~ /,focused,/ { print $2 }'
}

window_in_view() {
  local win
  win="$(tmux display-message -p -t "$pane" '#{window_id}')" || return 1
  windows_in_view | grep -qxF "$win"
}

any_client_focused() {
  tmux list-clients -F '#{client_flags}' | awk '","$0"," ~ /,focused,/ { f = 1 } END { exit !f }'
}

sgr() {
  local c=$1 layer=3 base i=0 name h
  [ "${2:-}" = bg ] && layer=4
  base=$((layer * 10))
  case $c in
    \#*)
      h=${c#\#}
      [[ $h =~ ^[0-9a-fA-F]{6}$ ]] || return 0
      printf '\033[%d8;2;%d;%d;%dm' "$layer" "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
      return 0
      ;;
    colour[0-9]*|color[0-9]*)
      [[ ${c#colo*r} =~ ^[0-9]+$ ]] && printf '\033[%d8;5;%dm' "$layer" "${c#colo*r}"
      return 0
      ;;
    bright*) base=$((base + 60)) c=${c#bright} ;;
  esac
  for name in black red green yellow blue magenta cyan white; do
    [ "$c" = "$name" ] && { printf '\033[%dm' $((base + i)); return 0; }
    i=$((i + 1))
  done
}

colour_of() { tmux display-message -p "$(opt "$1" "$2")"; }

shade() {
  local spec=${1#rgb:} r g b v h l
  [[ $spec =~ ^[0-9a-fA-F]{1,4}/[0-9a-fA-F]{1,4}/[0-9a-fA-F]{1,4}$ ]] || return 1
  IFS=/ read -r r g b <<<"$spec"
  for v in r g b; do
    h=${!v}
    printf -v "$v" '%d' $(( 16#$h * 255 / ((1 << (4 * ${#h})) - 1) ))
  done
  l=$(( (299 * r + 587 * g + 114 * b) / 1000 ))
  for v in r g b; do
    if [ "$l" -lt 128 ]; then
      printf -v "$v" '%d' $(( ${!v} + (255 - ${!v}) * 18 / 100 ))
    else
      printf -v "$v" '%d' $(( ${!v} - ${!v} * 15 / 100 ))
    fi
  done
  printf '#%02x%02x%02x' "$r" "$g" "$b"
}

entry_ids() {
  tmux show-options -g | awk -v p="$ENTRY_PREFIX" 'index($1, p) == 1 { print substr($1, length(p) + 1) }' \
    | sort -nr
}

entries_each() {
  local id v state where label detail
  for id in $(entry_ids); do
    v="$(tmux show-option -gqv "$ENTRY_PREFIX$id")"
    [ -n "$v" ] || continue
    state=${v%%"$SEP"*}; v=${v#*"$SEP"}
    where=${v%%"$SEP"*}; v=${v#*"$SEP"}
    label=${v%%"$SEP"*}; v=${v#*"$SEP"}
    detail=${v%%"$SEP"*}
    "$1" "$id" "$state" "$where" "$label" "$detail" "${v#*"$SEP"}"
  done
  return 0
}

entries_add() {
  local seq
  entries_drop "$5"
  seq=$(( $(opt @pane_notify_seq 0) + 1 ))
  tmux set-option -g @pane_notify_seq "$seq" \; set-option -g "$ENTRY_PREFIX$seq" "$1$SEP$2$SEP$3$SEP$4$SEP$5"
}

entries_drop() {
  local drop_window
  case $1 in
    @*) drop_window=$1; entries_each drop_if_window ;;
    *) tmux set-option -gu "$ENTRY_PREFIX$1" 2>/dev/null ;;
  esac
}

drop_if_window() {
  [ "$6" != "$drop_window" ] || tmux set-option -gu "$ENTRY_PREFIX$1"
}

entries_prune() {
  local max in_view windows kept=0 badges=" " win badge want client
  local -a cmds=()
  max="$(opt @pane-notify-bar-max 10)"
  in_view=" $(windows_in_view | tr '\n' ' ') "
  windows="$(tmux list-windows -a -F '#{window_id} #{@pane_notify}' | sort -u)"
  entries_each prune_entry

  while read -r win badge; do
    [ -n "$win" ] || continue
    want=""
    case $badges in *" $win="*) want=${badges#*" $win="}; want=${want%% *} ;; esac
    [ "$want" = "$badge" ] && continue
    if [ -n "$want" ]; then
      cmds+=(\; set-option -w -t "$win" @pane_notify "$want")
    else
      cmds+=(\; set-option -wu -t "$win" @pane_notify)
    fi
  done <<<"$windows"
  if [ "$kept" -gt 0 ]; then
    cmds+=(\; set-option -g @pane_notify_count "$kept")
  else
    cmds+=(\; set-option -gu @pane_notify_count)
  fi
  tmux "${cmds[@]:1}" 2>/dev/null
  while read -r client; do
    [ -n "$client" ] && tmux refresh-client -S -t "$client" 2>/dev/null
  done < <(tmux list-clients -F '#{client_name}')
  printf '%d' "$kept"
}

prune_entry() {
  if [ "$kept" -ge "$max" ] || [[ $in_view == *" $6 "* ]] || [[ $'\n'$windows != *$'\n'"$6 "* ]]; then
    tmux set-option -gu "$ENTRY_PREFIX$1"
    return 0
  fi
  kept=$((kept + 1))
  badges="$badges$6=$2 "
}

with_lock() {
  local dir token seen="" owner i=0
  dir="${TMPDIR:-/tmp}/pane-notify-$(id -u)-$(tmux display-message -p '#{pid}').lock"
  token="$$.$RANDOM"
  until mkdir "$dir" 2>/dev/null; do
    owner="$(cat "$dir/owner" 2>/dev/null)"
    if [ "$owner" != "$seen" ]; then
      seen=$owner i=0
    elif [ $((i += 1)) -ge 60 ]; then
      rm -rf "$dir"
      i=0
      continue
    fi
    sleep 0.05
  done
  printf '%s' "$token" > "$dir/owner"
  trap "unlock '$dir' '$token'" EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  "$@"
  unlock "$dir" "$token"
  trap - EXIT HUP INT TERM
}

unlock() {
  tmux set-option -gu @pane_notify_busy
  [ "$(cat "$1/owner" 2>/dev/null)" = "$2" ] && rm -rf "$1"
}

quietly() {
  tmux set-option -g @pane_notify_busy 1 \; "$@" 2>/dev/null
  tmux set-option -gu @pane_notify_busy
}

close_sidebar_only_windows() {
  local win
  for win in $(tmux list-panes -a -F '#{window_id} #{@pane_notify_sidebar}' \
               | awk '{ n[$1]++; if ($2 == 1) s[$1]++ } END { for (w in n) if (n[w] == s[w]) print w }'); do
    quietly kill-window -t "$win"
  done
}

column_plan() {
  local win=$1 sidebar=${2:-} ww
  ww="$(tmux display-message -p -t "$win" '#{window_width}')"
  tmux list-panes -t "$win" -F '#{pane_id} #{pane_left} #{pane_right} #{?pane_floating_flag,1,0}' |
    awk -v W="$ww" -v SB="$sidebar" '
      $4 == 1 { next }
      $1 == SB { sl = $2; next }
      { n++; id[n] = $1; l[n] = $2; r[n] = $3 }
      END {
        if (n == 0) exit
        if (sl == "") sl = W + 1
        for (i = 1; i <= n; i++) {
          b = r[i] + 1
          if (b >= sl - 1) continue
          crossed = 0
          for (j = 1; j <= n; j++) if (l[j] <= b && b <= r[j]) crossed = 1
          if (!crossed) border[b] = 1
        }
        m = 0
        for (b in border) s[++m] = b + 0
        for (i = 2; i <= m; i++) for (j = i; j > 1 && s[j - 1] > s[j]; j--) { t = s[j]; s[j] = s[j - 1]; s[j - 1] = t }
        prev = -1
        for (i = 1; i <= m; i++) {
          nb = int(s[i] * (W + 1) / sl + 0.5)
          cs = (i == 1 ? 0 : s[i - 1] + 1)
          for (j = 1; j <= n; j++) if (l[j] == cs && r[j] == s[i] - 1) { print id[j], nb - prev - 1; break }
          prev = nb
        }
      }'
}

pane_signature() {
  tmux list-panes -t "$1" -F '#{?pane_floating_flag,,#{pane_id}:#{pane_left}:#{pane_top}:#{pane_width}:#{pane_height}}' |
    awk 'NF' | tr '\n' ' '
}

save_columns() {
  local win=$1 plan=$2
  [ -n "$plan" ] || { tmux set-option -wu -t "$win" @pane_notify_columns; return 0; }
  tmux set-option -w -t "$win" @pane_notify_columns "$(pane_signature "$win")|$(tr '\n' ';' <<<"$plan")"
}

kill_sidebar() {
  local id=$1 win=$2 floating=$3 zoomed=$4 zoomed_pane saved plan pane width
  if [ "$floating" = 1 ]; then
    quietly kill-pane -t "$id"
    return 0
  fi
  if [ "$zoomed" = 1 ]; then
    zoomed_pane="$(tmux display-message -p -t "$win" '#{pane_id}')"
    quietly resize-pane -Z -t "$zoomed_pane"
  fi
  saved="$(tmux show-option -wqv -t "$win" @pane_notify_columns)"
  if [ -n "$saved" ] && [ "${saved%%|*}" = "$(pane_signature "$win")" ]; then
    plan="$(tr ';' '\n' <<<"${saved#*|}")"
  else
    plan="$(column_plan "$win" "$id")"
  fi
  tmux set-option -wu -t "$win" @pane_notify_columns 2>/dev/null
  quietly kill-pane -t "$id"
  while read -r pane width; do
    [ -n "$pane" ] && quietly resize-pane -t "$pane" -x "$width"
  done <<<"$plan"
  [ "$zoomed" = 1 ] && quietly resize-pane -Z -t "$zoomed_pane"
  return 0
}

list_sidebars() {
  tmux list-panes -a -F '#{pane_id} #{window_id} #{?pane_floating_flag,1,0} #{window_zoomed_flag} #{@pane_notify_sidebar}' \
    | awk '$5 == 1 { print $1, $2, $3, $4 }'
}

kill_all_sidebars() {
  local id win floating zoomed
  while read -r id win floating zoomed; do
    [ -n "$id" ] && kill_sidebar "$id" "$win" "$floating" "$zoomed"
  done <<<"$(list_sidebars)"
}

render_bar() {
  local live viewed kept="" stale="" win id floating zoomed ww wh w can_float plan
  [ -z "${PANE_NOTIFY_TRACE:-}" ] || echo render >> "$PANE_NOTIFY_TRACE"
  close_sidebar_only_windows
  live="$(entries_prune)"

  if [ "$live" = 0 ] || [ "$(opt @pane-notify-sidebar on)" != on ]; then
    tmux set-option -gu @pane_notify_sidebar_open
  fi
  if [ "$(tmux show-option -gqv @pane_notify_sidebar_open)" != 1 ]; then
    kill_all_sidebars
    return 0
  fi

  can_float="$(opt @pane_notify_floating 0)"
  viewed=" $(tmux list-clients -F '#{window_id}' | sort -u | tr '\n' ' ') "
  while read -r id win floating zoomed; do
    [ -n "$id" ] || continue
    if [[ $viewed == *" $win "* ]] && { [ "$floating" = "$zoomed" ] || [ "$can_float" != 1 ]; }; then
      tmux send-keys -t "$id" R
      kept="$kept $win "
    else
      stale="$stale$id $win $floating $zoomed"$'\n'
    fi
  done <<<"$(list_sidebars)"

  for win in $viewed; do
    [[ $kept == *" $win "* ]] && continue
    read -r ww wh zoomed <<<"$(tmux display-message -p -t "$win" '#{window_width} #{window_height} #{window_zoomed_flag}')"
    [ -n "$wh" ] || continue
    w="$(opt @pane-notify-sidebar-width 30)"
    [ "$w" -le $((ww / 3)) ] || w=$((ww / 3))
    [ "$w" -ge 12 ] || continue
    if [ "$zoomed" = 1 ]; then
      [ "$can_float" = 1 ] || continue
      id="$(tmux new-pane -d -A -P -F '#{pane_id}' -t "$win" -x "$w" -y "$wh" -X "$((ww - w))" -Y 0 -B none \
              "'$self' sidebar")" || continue
    else
      plan="$(column_plan "$win")"
      id="$(tmux split-window -d -h -f -l "$w" -P -F '#{pane_id}' -t "$win" "'$self' sidebar")" || continue
      save_columns "$win" "$plan"
    fi
    tmux set-option -p -t "$id" @pane_notify_sidebar 1
  done

  while read -r id win floating zoomed; do
    [ -n "$id" ] && kill_sidebar "$id" "$win" "$floating" "$zoomed"
  done <<<"$stale"
}

sidebar_toggle() {
  local client=${1:-}
  if [ "$(tmux show-option -gqv @pane_notify_sidebar_open)" = 1 ]; then
    tmux set-option -gu @pane_notify_sidebar_open
    kill_all_sidebars
    return 0
  fi
  if [ "$(opt @pane-notify-sidebar on)" != on ]; then
    tmux display-message ${client:+-c "$client"} "The pane-notify sidebar is off"
    return 0
  fi
  if [ "$(entries_prune)" = 0 ]; then
    tmux display-message ${client:+-c "$client"} "No notifications"
    return 0
  fi
  tmux set-option -g @pane_notify_sidebar_open 1
  render_bar
  focus_sidebar "$client"
}

focus_sidebar() {
  local win id
  if [ -n "$1" ]; then
    win="$(tmux list-clients -F '#{client_name} #{window_id}' | awk -v c="$1" '$1 == c { print $2 }')"
  else
    win="$(tmux display-message -p '#{window_id}')"
  fi
  [ -n "$win" ] || return 0
  id="$(tmux list-panes -t "$win" -F '#{pane_id} #{@pane_notify_sidebar}' | awk '$2 == 1 { print $1; exit }')"
  [ -n "$id" ] && tmux select-pane -Z -t "$id"
  return 0
}

record() {
  entries_add "$@"
  render_bar
}

forget() {
  entries_drop "$1"
  render_bar
}

declare -a ROW_ENTRY=() ENTRY_ID=() ENTRY_TARGET=() ENTRY_WHERE=() ENTRY_LABEL=() ENTRY_DETAIL=() \
  ENTRY_ICON=()
SEL=0 SEL_WINDOW="" FOCUSED=0 BG_SEEN=""

wrap() {
  local width=$2 line="" word
  local -a words=()
  read -ra words <<<"$1"
  for word in "${words[@]}"; do
    while [ "${#word}" -gt "$width" ]; do
      [ -n "$line" ] && printf '%s\n' "$line" && line=""
      printf '%s\n' "${word:0:width}"
      word=${word:width}
    done
    if [ -z "$line" ]; then
      line=$word
    elif [ $(( ${#line} + 1 + ${#word} )) -le "$width" ]; then
      line="$line $word"
    else
      printf '%s\n' "$line"
      line=$word
    fi
  done
  [ -n "$line" ] && printf '%s\n' "$line"
  return 0
}

put() {
  local line
  if [ "$row" -le "$rows" ]; then
    printf -v line '\033[%d;%dH%s%*s\033[%d;%dH%s\033[0m' "$row" $((col - 1)) "$bg" $((inner + 2)) "" "$row" "$col" "$1"
    frame=$frame$line
  fi
  row=$((row + 1))
}

blank() {
  local line
  if [ "$row" -le "$rows" ]; then
    printf -v line '\033[%d;%dH\033[K' "$row" $((col - 1))
    frame=$frame$line
  fi
  row=$((row + 1))
}

sidebar_load() {
  local i
  read -r cols rows floating FOCUSED <<<"$(tmux display-message -p -t "$TMUX_PANE" \
    '#{pane_width} #{pane_height} #{?pane_floating_flag,1,0} #{pane_active}')"
  col=2
  [ "$floating" = 1 ] && col=3
  inner=$((cols - col))
  c_text="$(sgr "$(colour_of @pane-notify-sidebar-text default)")"
  c_subtle="$(sgr "$(colour_of @pane-notify-sidebar-subtle default)")"
  c_muted="$(sgr "$(colour_of @pane-notify-sidebar-muted brightblack)")"
  c_rule="$(sgr "$(colour_of @pane-notify-sidebar-rule brightblack)")"
  selected_auto=""
  if [ "$(opt @pane-notify-sidebar-selected auto)" = auto ]; then
    selected_auto=1
    sidebar_background "$(tmux show-option -gqv @pane_notify_selected_bg)"
    printf '\033]11;?\033\\\033[c'
  else
    c_selected="$(sgr "$(colour_of @pane-notify-sidebar-selected "")" bg)"
    [ -n "$c_selected" ] || c_selected=$'\033[7m'
  fi
  ENTRY_ID=() ENTRY_TARGET=() ENTRY_WHERE=() ENTRY_LABEL=() ENTRY_DETAIL=() ENTRY_ICON=()
  entries_each load_entry
  for i in "${!ENTRY_ID[@]}"; do
    [ "${ENTRY_TARGET[i]}" = "$SEL_WINDOW" ] && SEL=$i
  done
  sidebar_select "$SEL"
}

load_entry() {
  local n=${#ENTRY_ID[@]}
  ENTRY_ID[n]=$1 ENTRY_WHERE[n]=$3 ENTRY_LABEL[n]=$4 ENTRY_DETAIL[n]=$5 ENTRY_TARGET[n]=$6
  ENTRY_ICON[n]="$(sgr "$(colour_of "@pane_notify_color_$2" "")")$(opt "@pane_notify_icon_$2" "●")"
}

sidebar_background() {
  if [ -n "$1" ]; then
    c_selected="$(sgr "$1" bg)"
  else
    c_selected=$'\033[7m'
  fi
}

sidebar_reply() {
  local colour="" old=$c_selected
  if [ "$1" = da ]; then
    [ -z "$BG_SEEN" ] || { BG_SEEN=""; return 0; }
  else
    colour="$(shade "$1")" || return 0
    BG_SEEN=1
  fi
  [ -n "$selected_auto" ] || return 0
  if [ -n "$colour" ]; then
    [ "$(tmux show-option -gqv @pane_notify_selected_bg)" = "$colour" ] ||
      tmux set-option -g @pane_notify_selected_bg "$colour"
  else
    tmux set-option -gu @pane_notify_selected_bg
  fi
  sidebar_background "$colour"
  [ "$c_selected" = "$old" ] || sidebar_paint
}

sidebar_select() {
  SEL=$1
  [ "$SEL" -lt "${#ENTRY_ID[@]}" ] || SEL=$((${#ENTRY_ID[@]} - 1))
  [ "$SEL" -ge 0 ] || SEL=0
  SEL_WINDOW=${ENTRY_TARGET[SEL]:-}
}

sidebar_paint() {
  local row=1 r i bg l first fg=$'\033[39m' frame=$'\033[0m' line
  ROW_ENTRY=()
  if [ "$floating" = 1 ]; then
    for ((r = 1; r <= rows; r++)); do
      printf -v line '\033[%d;1H%s│\033[0m' "$r" "$c_rule"
      frame=$frame$line
    done
  fi
  for i in "${!ENTRY_ID[@]}"; do
    bg=""
    [ "$FOCUSED" = 1 ] && [ "$i" = "$SEL" ] && bg=$c_selected
    first=1
    while IFS= read -r l; do
      ROW_ENTRY[row]=$i
      if [ -n "$first" ]; then
        put "${ENTRY_ICON[i]}$fg $c_text$l"
        first=""
      else
        put "  $c_text$l"
      fi
    done < <(wrap "${ENTRY_WHERE[i]}" $((inner - 2)))
    while IFS= read -r l; do
      ROW_ENTRY[row]=$i; put "  $c_subtle$l"
    done < <(wrap "${ENTRY_LABEL[i]}" $((inner - 2)))
    while IFS= read -r l; do
      ROW_ENTRY[row]=$i; put "  $c_muted$l"
    done < <(wrap "${ENTRY_DETAIL[i]}" $((inner - 2)))
    blank
  done
  while [ "$row" -le "$rows" ]; do blank; done
  printf '%s' "$frame"
}

sidebar_move() {
  [ "${#ENTRY_ID[@]}" -gt 0 ] || return 0
  FOCUSED=1
  sidebar_select $((SEL + $1))
  sidebar_paint
}

sidebar_open() {
  local i=$1
  [ -n "${ENTRY_ID[i]:-}" ] || return 0
  tmux last-pane -t "$TMUX_PANE" 2>/dev/null
  entries_drop "${ENTRY_ID[i]}"
  tmux switch-client -t "${ENTRY_TARGET[i]}" 2>/dev/null
  tmux run-shell -b "'$self' bar-refresh"
}

sidebar_remove() {
  local i=$1
  [ -n "${ENTRY_ID[i]:-}" ] || return 0
  entries_drop "${ENTRY_ID[i]}"
  sidebar_load
  sidebar_paint
  tmux run-shell -b "'$self' bar-refresh"
}

sidebar_close() {
  tmux set-option -gu @pane_notify_sidebar_open
  exit 0
}

sidebar_decode() {
  local c seq o b y
  IFS= read -rsn1 -d '' c || return 1
  while :; do
    case $c in
      R) echo redraw; return 0 ;;
      q) echo quit; return 0 ;;
      x) echo remove; return 0 ;;
      $'\r'|$'\n') echo open; return 0 ;;
      $'\033')
        IFS= read -rsn1 -d '' c || return 1
        if [ "$c" = ']' ]; then
          seq=""
          while IFS= read -rsn1 -d '' c; do
            case $c in
              $'\a') break ;;
              $'\033') IFS= read -rsn1 -d '' c; break ;;
            esac
            seq="$seq$c"
          done
          [[ $seq == 11\;* ]] && { echo "bg ${seq#11;}"; return 0; }
          IFS= read -rsn1 -d '' c || return 1
          continue
        fi
        [ "$c" = '[' ] || continue
        seq=""
        while IFS= read -rsn1 c; do
          seq="$seq$c"
          printf -v o '%d' "'$c"
          [ "$o" -ge 64 ] && [ "$o" -le 126 ] && break
        done
        case $seq in
          A) echo up; return 0 ;;
          B) echo down; return 0 ;;
          I|O) echo redraw; return 0 ;;
          '?'*c) echo "bg da"; return 0 ;;
          '<'*M)
            IFS=';' read -r b _ y <<<"${seq#<}"
            [ "$b" = 0 ] && { echo "click ${y%M}"; return 0; }
            ;;
        esac
        ;;
    esac
    IFS= read -rsn1 -d '' c || return 1
  done
}

sidebar() {
  local event cols rows floating col inner c_text c_subtle c_muted c_rule c_selected selected_auto i
  trap sidebar_close INT
  printf '\033[?25l\033[?7l\033[?1000h\033[?1006h\033[?1004h'
  sidebar_load
  sidebar_paint
  while event="$(sidebar_decode)"; do
    case $event in
      redraw) sidebar_load; sidebar_paint ;;
      quit) sidebar_close ;;
      up) sidebar_move -1 ;;
      down) sidebar_move 1 ;;
      open) sidebar_open "$SEL" ;;
      remove) sidebar_remove "$SEL" ;;
      bg\ *) sidebar_reply "${event#bg }" ;;
      click\ *)
        i=${ROW_ENTRY[${event#click }]:-}
        [ -z "$i" ] || sidebar_open "$i"
        ;;
    esac
  done
}

notify() {
  local state=$1 label detail where
  label="$(clean "$2")"
  detail="$(clean "$3")"

  if [ "$(opt @pane-notify-when-visible off)" != on ] && window_in_view; then
    return 0
  fi

  where="$(clean "$(tmux display-message -p -t "$pane" '#{window_name}')")"
  with_lock record "$state" "$where" "$label" "$detail" "$(tmux display-message -p -t "$pane" '#{window_id}')"

  local desktop
  desktop="$(opt @pane-notify-desktop unfocused)"
  if [ "$desktop" = always ] || { [ "$desktop" = unfocused ] && ! any_client_focused; }; then
    desktop_notify "$where" "$label${detail:+ · $detail}"
  fi
}

desktop_notify() {
  local title=${1//;/,} body=${2//;/,} tty seq st=$'\033\\'
  case "$(opt @pane-notify-desktop-protocol osc9)" in
    osc777) seq=$'\033]777;notify;'"$title;$body$st" ;;
    osc99)  seq=$'\033]99;i=pane-notify:d=0;'"$title$st"$'\033]99;i=pane-notify:p=body;'"$body$st" ;;
    *)      seq=$'\033]9;'"$body$st" ;;
  esac
  while read -r tty; do
    [ -w "$tty" ] && printf '%s' "$seq" > "$tty"
  done < <(tmux list-clients -F '#{client_tty}')
}

agent_label() {
  case "$1" in
    claude) echo Claude ;;
    codex)  echo Codex ;;
  esac
}

agent_event() {
  local label=$1 input event message
  command -v jq >/dev/null || return 0
  input="$(cat)"
  event="$(jq -r '.hook_event_name // empty' <<<"$input")"
  case "$event" in
    Stop)
      notify waiting "$label is waiting for input" ""
      ;;
    Notification)
      message="$(jq -r '.message // empty' <<<"$input")"
      notify waiting "${message:-$label needs you}" ""
      ;;
    PermissionRequest)
      message="$(jq -r '.tool_input.description? // .tool_name // empty' <<<"$input")"
      notify waiting "$label needs your approval" "$message"
      ;;
    UserPromptSubmit)
      if [ -n "$(tmux show-option -gqv @pane_notify_count)" ]; then
        with_lock forget "$(tmux display-message -p -t "$pane" '#{window_id}')"
      fi
      ;;
  esac
}

main() {
  local locale_name status seconds cmd took label
  [ -n "${TMUX:-}" ] || return 0
  label="$(agent_label "${1:-}")"
  if [ "${1:-}" = process ] || [ -n "$label" ]; then
    [ -n "${TMUX_PANE:-}" ] || return 0
    pane=$TMUX_PANE
  fi
  locale_name="$(utf8_locale)"
  [ -z "$locale_name" ] || export LC_ALL="$locale_name"

  case "${1:-}" in
    process)
      status=$2 seconds=$3 cmd=$4
      took="$(human_duration "$seconds")"
      if [ "$status" -eq 0 ]; then
        notify "done" "finished in $took" "$cmd"
      else
        notify failed "failed ($status) after $took" "$cmd"
      fi
      ;;
    bar-refresh)
      with_lock render_bar
      ;;
    sidebar-toggle)
      with_lock sidebar_toggle "${2:-}"
      ;;
    sidebar)
      sidebar
      ;;
    *)
      [ -z "$label" ] || agent_event "$label"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit 0
fi
