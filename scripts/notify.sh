#!/usr/bin/env bash
#   notify.sh process <exit-status> <seconds> <command>   (shell hooks)
#   notify.sh claude                                      (Claude Code hooks, JSON on stdin)
#   notify.sh bar-refresh                                 (tmux hooks)
#   notify.sh sidebar-toggle [client]                     (key binding)
#   notify.sh sidebar                                     (runs inside the sidebar pane)
#
# Sourcing the file defines the functions without running anything (tests).

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# @pane_notify_entry_<seq> = state<US>where<US>label<US>detail<US>window-id
ENTRY_PREFIX=@pane_notify_entry_
US=$'\x1f'
TEXT_MAX=300

opt() {
  local value
  value="$(tmux show-option -gqv "$1")"
  printf '%s' "${value:-$2}"
}

# Character counts, wrapping and [[:cntrl:]] need a UTF-8 locale.
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

# Newlines would split an entry's fields; BEL/ESC would end a desktop
# notification's escape sequence early.
clean() {
  local s=${1//[[:cntrl:]]/ }
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

# Foreground SGR for a tmux colour: a name, brightNAME, colourN or #rrggbb.
# "default" and anything unknown give no colour.
sgr() {
  local c=$1 base=30 i=0 name h
  case $c in
    \#*)
      h=${c#\#}
      [[ $h =~ ^[0-9a-fA-F]{6}$ ]] || return 0
      printf '\033[38;2;%d;%d;%dm' "0x${h:0:2}" "0x${h:2:2}" "0x${h:4:2}"
      return 0
      ;;
    colour[0-9]*|color[0-9]*)
      [[ ${c#colo*r} =~ ^[0-9]+$ ]] && printf '\033[38;5;%dm' "${c#colo*r}"
      return 0
      ;;
    bright*) base=90 c=${c#bright} ;;
  esac
  for name in black red green yellow blue magenta cyan white; do
    [ "$c" = "$name" ] && { printf '\033[%dm' $((base + i)); return 0; }
    i=$((i + 1))
  done
}

# An option's value with formats such as #{@my_colour} expanded.
colour_of() { tmux display-message -p "$(opt "$1" "$2")"; }

entry_names() {
  tmux show-options -g | awk -v p="$ENTRY_PREFIX" 'index($1, p) == 1 { print $1 }' \
    | sort -t_ -k4,4nr
}

drop_entries_for() {
  local name target
  for name in $(entry_names); do
    IFS=$US read -r _ _ _ _ target <<<"$(tmux show-option -gqv "$name")"
    [ "$target" = "$1" ] && tmux set-option -gu "$name"
  done
}

# One entry per window. Runs under with_lock, which keeps the sequence unique.
add_entry() {
  local state=$1 where=$2 label=$3 detail=$4 win=$5 seq
  drop_entries_for "$win"
  seq=$(( $(opt @pane_notify_seq 0) + 1 ))
  tmux set-option -g @pane_notify_seq "$seq"
  tmux set-option -g "${ENTRY_PREFIX}${seq}" "${state}${US}${where}${US}${label}${US}${detail}${US}${win}"
}

# Prints entries newest first as name<US>value. With "prune", first deletes
# ones whose window is on screen or gone, and any beyond @pane-notify-bar-max.
list_entries() {
  local prune=${1:-} max in_view windows name value target n=0
  max="$(opt @pane-notify-bar-max 10)"
  if [ -n "$prune" ]; then
    in_view=" $(windows_in_view | tr '\n' ' ') "
    windows=" $(tmux list-windows -a -F '#{window_id}' | tr '\n' ' ') "
  fi
  for name in $(entry_names); do
    value="$(tmux show-option -gqv "$name")"
    IFS=$US read -r _ _ _ _ target <<<"$value"
    if [ -n "$prune" ] && { [ "$n" -ge "$max" ] || [[ $in_view == *" $target "* ]] || [[ $windows != *" $target "* ]]; }; then
      tmux set-option -gu "$name"
      continue
    fi
    printf '%s%s%s\n' "$name" "$US" "$value"
    n=$((n + 1))
  done
}

# Serialises entry changes and renders per tmux server. The lock holds its
# owner's token, so only the owner releases it; a lock kept by the same owner
# for ~4s (stalled, or killed with SIGKILL) is taken over.
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
  # shellcheck disable=SC2064 # expand now: the locals are gone at exit
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

# Runs a tmux command whose hooks (after-kill-pane, window-unlinked, ...)
# must not trigger another render. tmux runs after-* hooks before the command
# returns; the flag is cleared separately in case the command fails.
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

# refresh-client -S so the bell does not wait for status-interval.
set_count() {
  local client
  if [ "$1" -gt 0 ]; then
    tmux set-option -g @pane_notify_count "$1" \; set-option -g @pane_notify_bar_active 1
  else
    tmux set-option -gu @pane_notify_count \; set-option -gu @pane_notify_bar_active
  fi
  while read -r client; do
    [ -n "$client" ] && tmux refresh-client -S -t "$client" 2>/dev/null
  done < <(tmux list-clients -F '#{client_name}')
}

# Opening a split sidebar shrinks the window's columns, but closing it gives
# all the space to the column next to it. So the columns' widths are saved
# when it opens and restored when it closes, or, if the panes changed in the
# meantime, scaled back in proportion.
#
# Columns are found from pane positions: a border that no pane crosses
# separates two of them. A column is resized through a pane spanning its full
# width; one without such a pane keeps what tmux gives it.

# Prints "pane width" for each column but the last (which takes the rest).
# $2: a sidebar pane to leave out, scaling the others to the full window.
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
        # Old border b maps to b * (W + 1) / sl: the span up to the sidebar
        # (with its border) grows to the whole window.
        prev = -1
        for (i = 1; i <= m; i++) {
          nb = int(s[i] * (W + 1) / sl + 0.5)
          cs = (i == 1 ? 0 : s[i - 1] + 1)
          for (j = 1; j <= n; j++) if (l[j] == cs && r[j] == s[i] - 1) { print id[j], nb - prev - 1; break }
          prev = nb
        }
      }'
}

# The tiled panes' geometry; floating panes do not affect the columns.
pane_signature() {
  tmux list-panes -t "$1" -F '#{?pane_floating_flag,,#{pane_id}:#{pane_left}:#{pane_top}:#{pane_width}:#{pane_height}}' |
    awk 'NF' | tr '\n' ' '
}

# Called around creating a split sidebar: $2 is the plan from before it.
save_columns() {
  local win=$1 plan=$2
  [ -n "$plan" ] || { tmux set-option -wu -t "$win" @pane_notify_columns; return 0; }
  tmux set-option -w -t "$win" @pane_notify_columns "$(pane_signature "$win")|$(tr '\n' ';' <<<"$plan")"
}

# Removing a split unzooms its window anyway, and the column widths are only
# readable unzoomed, so a zoomed window is unzoomed first and zoomed again.
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

# pane_floating_flag does not exist before tmux 3.7; the conditional reads 0.
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
  live="$(list_entries prune)"
  set_count "$(grep -c . <<<"$live")"

  if [ -z "$live" ] || [ "$(tmux show-option -gqv @pane_notify_sidebar_open)" != 1 ]; then
    [ -z "$live" ] && tmux set-option -gu @pane_notify_sidebar_open
    kill_all_sidebars
    return 0
  fi

  # A zoomed window needs a floating sidebar (tmux 3.8+), since a split would
  # unzoom it. Without floating panes a split sidebar just stays hidden behind
  # the zoom. Replacements are created before the old ones are removed: with
  # one real pane left, a zoom lost to the removal can only be restored while
  # the floating sidebar exists.
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
  if [ -z "$(list_entries prune)" ]; then
    set_count 0
    tmux display-message ${client:+-c "$client"} "No notifications"
    return 0
  fi
  tmux set-option -g @pane_notify_sidebar_open 1
  render_bar
}

record() {
  add_entry "$@"
  render_bar
}

forget() {
  drop_entries_for "$1"
  render_bar
}

# Sidebar row -> entry index, for clicks.
declare -a ROW_ENTRY=() ENTRY_NAME=() ENTRY_TARGET=()

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

# Uses sidebar_draw's locals row, rows and col.
put() {
  [ "$row" -le "$rows" ] && printf '\033[%d;%dH%s' "$row" "$col" "$1"
  row=$((row + 1))
}

sidebar_draw() {
  local cols rows floating inner col reset=$'\033[0m' c_text c_subtle c_muted c_rule
  read -r cols rows floating <<<"$(tmux display-message -p -t "$TMUX_PANE" '#{pane_width} #{pane_height} #{?pane_floating_flag,1,0}')"
  # A split already has tmux's border on its left; a floating one draws its own.
  col=2
  [ "$floating" = 1 ] && col=3
  inner=$((cols - col))
  c_text="$(sgr "$(colour_of @pane-notify-sidebar-text default)")"
  c_subtle="$(sgr "$(colour_of @pane-notify-sidebar-subtle default)")"
  c_muted="$(sgr "$(colour_of @pane-notify-sidebar-muted brightblack)")"
  c_rule="$(sgr "$(colour_of @pane-notify-sidebar-rule brightblack)")"

  local entries row=1 r i=0 name value state where label detail target icon colour l first
  entries="$(list_entries)"
  ROW_ENTRY=() ENTRY_NAME=() ENTRY_TARGET=()

  printf '\033[H\033[2J'
  if [ "$floating" = 1 ]; then
    for ((r = 1; r <= rows; r++)); do printf '\033[%d;1H%s│%s' "$r" "$c_rule" "$reset"; done
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%"$US"*}
    value=${line#*"$US"}
    IFS=$US read -r state where label detail target <<<"$value"
    icon="$(opt "@pane_notify_icon_$state" "●")"
    colour="$(colour_of "@pane_notify_color_$state" "")"
    ENTRY_NAME[i]=$name
    ENTRY_TARGET[i]=$target
    first=1
    while IFS= read -r l; do
      if [ -n "$first" ]; then
        ROW_ENTRY[row]=$i; put "$(sgr "$colour")$icon$reset $c_text$l$reset"
        first=""
      else
        ROW_ENTRY[row]=$i; put "  $c_text$l$reset"
      fi
    done < <(wrap "$where" $((inner - 2)))
    while IFS= read -r l; do
      ROW_ENTRY[row]=$i; put "  $c_subtle$l$reset"
    done < <(wrap "$label" $((inner - 2)))
    while IFS= read -r l; do
      ROW_ENTRY[row]=$i; put "  $c_muted$l$reset"
    done < <(wrap "$detail" $((inner - 2)))
    row=$((row + 1))
    i=$((i + 1))
  done <<<"$entries"
}

sidebar_click() {
  local i=${ROW_ENTRY[$1]:-}
  [ -n "$i" ] || return 0
  # The click made the sidebar the active pane; hand focus back first.
  tmux last-pane -t "$TMUX_PANE" 2>/dev/null
  tmux set-option -gu "${ENTRY_NAME[i]}" 2>/dev/null
  tmux switch-client -t "${ENTRY_TARGET[i]}" 2>/dev/null
  tmux run-shell -b "'$self' bar-refresh"
}

# The pane-exited hook then renders, closing the sidebar in other windows.
sidebar_close() {
  tmux set-option -gu @pane_notify_sidebar_open
  exit 0
}

sidebar() {
  trap sidebar_close INT
  printf '\033[?25l\033[?7l\033[?1000h\033[?1006h'
  sidebar_draw
  local c pending="" seq o b y
  while :; do
    if [ -n "$pending" ]; then
      c=$pending pending=""
    else
      IFS= read -rsn1 c || break
    fi
    case "$c" in
      R) sidebar_draw ;;
      q) sidebar_close ;;
      $'\033')
        IFS= read -rsn1 c || break
        # A lone Esc: the next key is handled normally.
        [ "$c" = '[' ] || { pending=$c; continue; }
        # CSI ends at a byte in 0x40-0x7E (arrow keys, mouse reports).
        seq=""
        while IFS= read -rsn1 c; do
          seq="$seq$c"
          printf -v o '%d' "'$c"
          [ "$o" -ge 64 ] && [ "$o" -le 126 ] && break
        done
        # SGR mouse: <button;x;yM
        [[ $seq == '<'*M ]] || continue
        IFS=';' read -r b _ y <<<"${seq#<}"
        [ "$b" = 0 ] && sidebar_click "${y%M}"
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

  tmux set-option -w -t "$pane" @pane_notify "$state"
  where="$(clean "$(tmux display-message -p -t "$pane" '#{window_name}')")"

  if [ "$(opt @pane-notify-sidebar on)" = on ]; then
    with_lock record "$state" "$where" "$label" "$detail" "$(tmux display-message -p -t "$pane" '#{window_id}')"
  fi

  local desktop
  desktop="$(opt @pane-notify-desktop unfocused)"
  if [ "$desktop" = always ] || { [ "$desktop" = unfocused ] && ! any_client_focused; }; then
    desktop_notify "$where" "$label${detail:+ · $detail}"
  fi
}

# Written to each client's terminal directly, past tmux. OSC 9 has no title
# field; terminals such as Ghostty and iTerm2 add their own. ';' separates
# fields in all three sequences.
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

main() {
  local locale_name status seconds cmd took input event message
  [ -n "${TMUX:-}" ] || return 0
  case "${1:-}" in
    process|claude)
      [ -n "${TMUX_PANE:-}" ] || return 0
      pane=$TMUX_PANE
      ;;
  esac
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
    claude)
      command -v jq >/dev/null || return 0
      input="$(cat)"
      event="$(jq -r '.hook_event_name // empty' <<<"$input")"
      case "$event" in
        Stop)
          notify waiting "Claude is waiting for input" ""
          ;;
        Notification)
          message="$(jq -r '.message // empty' <<<"$input")"
          notify waiting "${message:-Claude needs you}" ""
          ;;
        UserPromptSubmit)
          tmux set-option -wu -t "$pane" @pane_notify
          if [ -n "$(tmux show-option -gqv @pane_notify_bar_active)" ]; then
            with_lock forget "$(tmux display-message -p -t "$pane" '#{window_id}')"
          fi
          ;;
      esac
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
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit 0
fi
