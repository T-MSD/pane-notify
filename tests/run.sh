#!/usr/bin/env bash
# Integration tests. Each run uses private tmux servers (-L) and a temporary
# directory, so the user's own tmux is never touched.
#
#   tests/run.sh            run everything
#   tests/run.sh -v         also print each check's details on success
#
# shellcheck disable=SC2016 # wait_for takes expressions to evaluate later

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="$ROOT/scripts/notify.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pane-notify-test.XXXXXX")"
RUN=0
IN="pn-test-$$-0" OUT="pn-outer-$$-0"
VERBOSE=${1:-}
RESULTS="$WORK/results"
OUTER_BG='#20242c'
TMUX_VERSION="$(tmux -V | sed -E 's/^tmux (next-)?//; s/^([0-9]+)\.([0-9]+).*/\1 \2/' | awk '{ print $1 * 100 + $2 }')"
REVERSE=$'\e\\[7m'
if [ "$TMUX_VERSION" -ge 304 ]; then HL='48;2;72;75;81m'; else HL=$REVERSE; fi

T() { tmux -L "$IN" "$@"; }
O() { tmux -L "$OUT" "$@"; }

cleanup() {
  T kill-server 2>/dev/null
  O kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

ok()      { echo pass >> "$RESULTS"; printf '  ok    %s\n' "$1"; }
bad()     { echo fail >> "$RESULTS"; printf '  FAIL  %s\n        %s\n' "$1" "$2"; }
skipped() { echo skip >> "$RESULTS"; printf '  skip  %s (%s)\n' "$1" "$2"; }

expect() {
  if [ "$2" = "$3" ]; then ok "$1"; [ -z "$VERBOSE" ] || printf '        = %s\n' "$2"
  else bad "$1" "expected [$3], got [$2]"
  fi
}

wait_for() {
  local i
  for ((i = 0; i < ${2:-5} * 10; i++)); do
    eval "$1" && return 0
    sleep 0.1
  done
  return 1
}

eventually() {
  local i v
  for ((i = 0; i < 50; i++)); do
    v="$(eval "$1")"
    [ "$v" = "$2" ] && break
    sleep 0.1
  done
  printf '%s' "$v"
}

section() { printf '\n%s\n' "$1"; }

sock() { T display -p '#{socket_path}'; }
pane_of() { T display -p -t "$1" '#{pane_id}'; }
notify() { TMUX="$(sock),1,0" TMUX_PANE="$(pane_of "$1")" bash "$N" "${@:2}"; }
opencode_plugin() {
  local env=(TMUX= TMUX_PANE=)
  [ -z "$1" ] || env=(TMUX="$(sock),1,0" TMUX_PANE="$(pane_of "$1")")
  env "${env[@]}" node --input-type=module -e "
    const { PaneNotify } = await import('$ROOT/opencode/pane-notify.js');
    const sessions = { child: { id: 'child', parentID: 's1' } };
    const client = { session: { get: async ({ path }) => {
      if (path.id === 'broken') throw new Error('unreachable');
      if (path.id === 'missing') return { error: { name: 'NotFoundError' } };
      return { data: sessions[path.id] ?? { id: path.id } };
    } } };
    const hooks = await PaneNotify({ client });
    const status = (sessionID, type) =>
      hooks.event({ event: { type: 'session.status', properties: { sessionID, status: { type } } } });
    $2"
}
toggle() { T run-shell "'$N' sidebar-toggle"; }
count() { T show -gqv @pane_notify_count; }
entries() { T show -g | grep -ac '^@pane_notify_entry_'; }
sidebars() { T list-panes -a -F '#{pane_id} #{@pane_notify_sidebar}' | awk '$2 == 1 { print $1 }' | tr '\n' ' ' | sed 's/ $//'; }
sidebar_in() { T list-panes -t "$1" -F '#{pane_id} #{@pane_notify_sidebar}' | awk '$2 == 1 { print $1 }'; }
drawn() { T capture-pane -p -t "$1" | grep -ac '●'; }
client_window() { T list-clients -F '#{window_name}'; }
SEP=$'\xe2\x90\x9f'
field() { awk -F "$SEP" -v n="$1" '{ print $n }'; }
sidebar_kind() { T list-panes -t a:0 -F '#{@pane_notify_sidebar}#{?pane_floating_flag,1,0}' | grep -c "^$1\$"; }
lockdir() { echo "${TMPDIR:-/tmp}/pane-notify-$(id -u)-$(T display -p '#{pid}').lock"; }
settle_kind() {
  local other=10
  [ "$1" = 10 ] && other=11
  wait_for "[ \"\$(sidebar_kind $1)\" = 1 ] && [ \"\$(sidebar_kind $other)\" = 0 ] && [ ! -d \"\$(lockdir)\" ]" 8
  sleep 0.3
  wait_for '[ ! -d "$(lockdir)" ]'
}

setup() {
  T kill-server 2>/dev/null
  O kill-server 2>/dev/null
  RUN=$((RUN + 1))
  IN="pn-test-$$-$RUN" OUT="pn-outer-$$-$RUN"
  : > "$WORK/out.raw"
  T -f /dev/null new-session -d -s a -n main -x 120 -y 30
  T set -g focus-events on \; set -g mouse on \; set -g base-index 0 \
    \; set -g @pane-notify-desktop off \; set-environment -g PANE_NOTIFY_TRACE "$WORK/renders"
  local o
  for o in "$@"; do eval "T set -g $o"; done
  T run-shell "'$ROOT/pane-notify.tmux'"
  local i
  for i in 1 2 3 4 5; do T new-window -d -t "a:$i" -n "w$i"; done
  if [ -n "$OUTER_BG" ]; then
    O -f /dev/null new-session -d -s o -x 120 -y 32 "TMUX= tmux -L $IN attach -t a:0" \; set -g window-style "bg=$OUTER_BG"
  else
    O -f /dev/null new-session -d -s o -x 120 -y 32 "TMUX= tmux -L $IN attach -t a:0"
  fi
  O set -g status off
  O pipe-pane -O -t o "cat >> '$WORK/out.raw'"
  wait_for '[ -n "$(T list-clients)" ]' || { echo "inner client did not attach"; exit 1; }
}

section "functions"
(
  source "$N"
  LC_ALL="$(utf8_locale)"
  export LC_ALL
  expect "utf8_locale finds a UTF-8 locale" "$([ -n "$LC_ALL" ] && echo yes)" yes
  expect "clean turns control characters into spaces" "$(clean $'a\nb\x07c\x1b]2;x')" "a b c ]2;x"
  expect "clean removes the entry separator" "$(clean "a${SEP}b")" "a b"
  long="$(printf 'x%.0s' $(seq 400))"
  r="$(clean "$long")"
  expect "clean caps the length" "${#r}" 300
  expect "sgr hex" "$(sgr '#ff5050' | od -An -c | tr -d ' \n')" '033[38;2;255;80;80m'
  expect "sgr name" "$(sgr red | od -An -c | tr -d ' \n')" '033[31m'
  expect "sgr bright name" "$(sgr brightblack | od -An -c | tr -d ' \n')" '033[90m'
  expect "sgr colourN" "$(sgr colour208 | od -An -c | tr -d ' \n')" '033[38;5;208m'
  expect "sgr default is empty" "$(sgr default)" ""
  expect "wrap splits on words" "$(wrap 'one two three four' 9 | tr '\n' '|')" "one two|three|four|"
  expect "wrap splits long words" "$(wrap 'abcdefghijkl' 5 | tr '\n' '|')" "abcde|fghij|kl|"
  expect "human_duration" "$(human_duration 59) $(human_duration 61) $(human_duration 3700)" "59s 1m01s 1h01m"
  expect "decode: R redraws" "$(printf 'R' | sidebar_decode)" redraw
  expect "sgr background hex" "$(sgr '#303030' bg | od -An -c | tr -d ' \n')" '033[48;2;48;48;48m'
  expect "sgr background name" "$(sgr brightred bg | od -An -c | tr -d ' \n')" '033[101m'
  expect "sgr background colourN" "$(sgr colour236 bg | od -An -c | tr -d ' \n')" '033[48;5;236m'
  expect "decode: up and down arrows" "$(printf '\e[A\e[B' | { sidebar_decode; sidebar_decode; } | tr '\n' ' ')" "up down "
  expect "decode: other sequences are skipped" "$(printf '\e[Cq' | sidebar_decode)" quit
  expect "decode: Enter opens" "$(printf '\r\n' | { sidebar_decode; sidebar_decode; } | tr '\n' ' ')" "open open "
  expect "decode: x removes" "$(printf 'x' | sidebar_decode)" remove
  expect "shade lightens a dark background" "$(shade rgb:2020/2424/2c2c)" '#484b51'
  expect "shade lightens a grey one" "$(shade rgb:3c3c/3c3c/3c3c)" '#5f5f5f'
  expect "shade darkens a light one" "$(shade rgb:fafa/fafa/fafa)" '#d5d5d5'
  expect "shade takes short channels" "$(shade rgb:0/0/0)" '#2d2d2d'
  expect "shade rejects other formats" "$(shade '#ffffff' || echo rejected)" rejected
  expect "decode: OSC 11 reply with ST" "$(printf '\e]11;rgb:2020/2424/2c2c\e\\' | sidebar_decode)" "bg rgb:2020/2424/2c2c"
  expect "decode: OSC 11 reply with BEL" "$(printf '\e]11;rgb:ff/ff/ff\aq' | { sidebar_decode; sidebar_decode; } | tr '\n' ' ')" "bg rgb:ff/ff/ff quit "
  expect "decode: DA1 reply" "$(printf '\e[?1;2c' | sidebar_decode)" "bg da"
  expect "decode: other OSC replies are skipped" "$(printf '\e]10;rgb:0/0/0\aq' | sidebar_decode)" quit
  expect "decode: focus changes redraw" "$(printf '\e[I\e[O' | { sidebar_decode; sidebar_decode; } | tr '\n' ' ')" "redraw redraw "
  expect "decode: lone Esc keeps the key" "$(printf '\eq' | sidebar_decode)" quit
  expect "decode: left click" "$(printf '\e[<0;5;3M' | sidebar_decode)" "click 3"
  expect "decode: release is ignored" "$(printf '\e[<0;5;1m' | sidebar_decode)" ""
  expect "decode: right click is ignored" "$(printf '\e[<2;5;3M' | sidebar_decode)" ""
  expect "decode: other keys are ignored" "$(printf 'zy' | sidebar_decode)" ""
  expect "decode: one event per call" "$(printf 'Rq' | { sidebar_decode; sidebar_decode; } | tr '\n' ' ')" "redraw quit "
)

section "entry functions"
setup
(
  TMUX="$(sock),1,0"
  export TMUX
  source "$N"
  row() { printf '%s|%s|%s|%s|%s|%s\n' "$@"; }
  fields() { entries_each row | cut -d'|' -f"$1" | tr '\n' ' '; }
  w0="$(T display -p -t a:0 '#{window_id}')" w2="$(T display -p -t a:2 '#{window_id}')" w3="$(T display -p -t a:3 '#{window_id}')"
  entries_add "done" w2 finished "make all" "$w2"
  entries_add failed w3 "failed (1)" "make test" "$w3"
  expect "entries_each lists newest first, field by field" "$(fields 2-6)" \
    "failed|w3|failed (1)|make test|$w3 done|w2|finished|make all|$w2 "
  entries_add waiting w2 "Claude is waiting" "" "$w2"
  expect "entries_add replaces the window's entry" "$(fields 2,6)" "waiting|$w2 failed|$w3 "
  entries_drop "$(entries_each row | head -1 | cut -d'|' -f1)"
  expect "entries_drop takes an entry id" "$(fields 6)" "$w3 "
  entries_drop "$w3"
  expect "entries_drop takes a window id" "$(fields 6)" ""
  entries_add "done" w0 finished x "$w0"
  entries_add "done" w2 finished x "$w2"
  entries_add failed w3 failed x "$w3"
  T set -g @pane-notify-bar-max 1
  expect "entries_prune prints what is left" "$(entries_prune)" 1
  expect "and drops what is in view or beyond bar-max" "$(fields 6)" "$w3 "
  expect "and badges only the kept entry's window" \
    "$(T show -wqv -t a:0 @pane_notify)|$(T show -wqv -t a:2 @pane_notify)|$(T show -wqv -t a:3 @pane_notify)" "||failed"
  expect "and sets the bell" "$(T show -gqv @pane_notify_count)" 1
  entries_drop "$w3"
  entries_prune >/dev/null
  expect "an empty prune clears the badge and the bell" \
    "$(T show -wqv -t a:3 @pane_notify)|$(T show -gqv @pane_notify_count)" "|"
)

section "plugin load"
setup
expect "key binding" "$(T list-keys -T prefix a | grep -c sidebar-toggle)" 1
expect "status-right gets the bell" "$(T show -gv status-right | grep -c '@pane-notify-status')" 1
expect "window format gets the badge" "$(T show -gwv window-status-format | grep -c '@pane-notify-badge')" 1
T run-shell "'$ROOT/pane-notify.tmux'"
expect "reload does not add the badge twice" \
  "$(T show -gwv window-status-current-format | grep -o '@pane-notify-badge' | wc -l | tr -d ' ')" 1
missing=""
for h in session-window-changed client-session-changed client-focus-in window-unlinked \
         after-resize-pane pane-exited after-kill-pane; do
  T set-hook -g "${h}[99]" 'display x' 2>/dev/null || continue
  T set-hook -gu "${h}[99]"
  { T show-hooks -g "$h"; T show-hooks -gw "$h"; } 2>/dev/null | grep -q bar-refresh || missing="$missing $h"
done
expect "follow hooks installed" "$missing" ""

setup "@pane-notify-auto-format off" "@pane-notify-key off"
expect "auto-format off leaves status-right alone" "$(T show -gv status-right | grep -c '@pane-notify-status')" 0
expect "key off binds nothing" "$(T list-keys -T prefix a 2>/dev/null | grep -c sidebar-toggle)" 0

section "entries"
setup
notify a:0 process 0 12 visible
expect "a window being looked at gets no entry" "$(entries)" 0
notify a:3 process 0 12 $'for i in 1 2\ndo sleep 1; done'
expect "multi-line command keeps its entry" "$(count)" 1
expect "newlines stored as spaces" "$(T show -gv @pane_notify_entry_1 | sed "s/$SEP/|/g")" \
  "done|w3|finished in 12s|for i in 1 2 do sleep 1; done|$(T display -p -t a:3 '#{window_id}')"
expect "badge set on the window" "$(T show -wv -t a:3 @pane_notify)" "done"
notify a:2 process 1 75 make
notify a:3 process 0 12 again
expect "newer entry from the same window replaces the old" "$(entries)" 2
expect "newest has the highest sequence" "$(T show -gv @pane_notify_entry_3 | field 4)" again
T select-window -t a:3
wait_for '[ "$(count)" = 1 ]'
expect "opening a window drops its entry" "$(count)" 1
expect "and clears its badge" "$(T show -wqv -t a:3 @pane_notify)" ""
T select-window -t a:2
wait_for '[ -z "$(count)" ]'
expect "bell clears when every entry is seen" "$(count)" ""

setup "@pane-notify-bar-max 1"
notify a:2 process 0 12 one
notify a:3 process 0 12 two
expect "an entry beyond bar-max loses its badge" \
  "$(T show -wqv -t a:2 @pane_notify)|$(T show -wqv -t a:3 @pane_notify)" "|done"

setup "@pane-notify-sidebar off"
notify a:2 process 0 12 one
expect "sidebar off still sets the badge and the bell" "$(T show -wqv -t a:2 @pane_notify) $(count)" "done 1"
toggle
expect "sidebar off opens no sidebar" "$(sidebars)|$(T show -gqv @pane_notify_sidebar_open)" "|"

setup
notify a:2 process 0 12 one
toggle
wait_for '[ -n "$(sidebar_in a:0)" ]'
T set -g @pane-notify-sidebar off
T run-shell "'$N' bar-refresh"
wait_for '[ -z "$(sidebars)" ]'
expect "turning the sidebar off closes an open one" "$(sidebars)|$(T show -gqv @pane_notify_sidebar_open)" "|"

section "desktop notifications"
setup "@pane-notify-desktop always"
notify a:2 process 1 12 $'make\a\e]2;PWNED\a'
wait_for 'grep -aq "PWNED" "$WORK/out.raw"'
expect "OSC 9 body is cleaned and terminated once" \
  "$(printf '%s' "$(grep -ao $'\e]9;[^\e]*\e\\\\' "$WORK/out.raw")" | od -An -c | tr -d ' \n')" \
  "$(printf '\e]9;failed (1) after 12s · make  ]2,PWNED \e\\' | od -An -c | tr -d ' \n')"
expect "no title sequence reaches the terminal" "$(grep -ac $'\e]2;' "$WORK/out.raw")" 0
T set -g @pane-notify-desktop-protocol osc777
notify a:3 process 0 12 build
wait_for 'grep -aq "777;" "$WORK/out.raw"'
expect "OSC 777 has the window as title" "$(grep -ao $'\e]777;[^\e]*' "$WORK/out.raw" | tail -1)" \
  $'\e]777;notify;w3;finished in 12s · build'
T set -g @pane-notify-desktop-protocol osc99
notify a:4 process 0 12 test
wait_for 'grep -aq "99;i=" "$WORK/out.raw"'
expect "OSC 99 sends title then body" "$(grep -ao $'\e]99;[^\e]*' "$WORK/out.raw" | tail -2 | tr '\n' '|')" \
  $'\e]99;i=pane-notify:d=0;w4|\e]99;i=pane-notify:p=body;finished in 12s · test|'

section "sidebar"
setup
toggle
expect "toggle with nothing to show opens nothing" "$(sidebars)" ""
notify a:1 process 0 12 one
notify a:2 process 0 12 two
toggle
wait_for '[ -n "$(sidebar_in a:0)" ] && [ "$(drawn "$(sidebar_in a:0)")" = 2 ]'
sb="$(sidebar_in a:0)"
expect "opens as a split in the viewed window" "$(T display -p -t "$sb" '#{?pane_floating_flag,1,0} #{pane_width}')" "0 30"
expect "lists both entries" "$(eventually 'drawn "$sb"' 2)" 2
T send-keys -t "$sb" Up
notify a:3 process 0 12 three
wait_for '[ "$(drawn "$sb")" = 3 ]'
expect "redraws after an arrow key" "$(eventually 'drawn "$sb"' 3)" 3
T send-keys -t "$sb" Escape
notify a:4 process 0 12 four
wait_for '[ "$(drawn "$sb")" = 4 ]'
expect "redraws after a lone Esc" "$(eventually 'drawn "$sb"' 4)" 4
O send-keys -t o -l $'\e[<0;95;2M'
wait_for '[ "$(client_window)" = w4 ]'
expect "clicking an entry opens its window" "$(client_window)" w4
wait_for '[ "$(count)" = 3 ]'
expect "and removes the entry" "$(count)" 3
wait_for '[ -n "$(sidebar_in a:4)" ] && [ -z "$(sidebar_in a:0)" ]'
expect "the sidebar follows to the new window" "$([ -n "$(sidebar_in a:4)" ] && [ -z "$(sidebar_in a:0)" ] && echo yes)" yes
expect "without taking the focus" "$(T display -p -t a:4 '#{@pane_notify_sidebar}')" ""

settled() { wait_for '[ -n "$(sidebars)" ] && [ "$(drawn "$(sidebars)")" -gt 0 ]'; sleep 0.8; }

settled
: > "$WORK/renders"
T send-keys -t "$(sidebar_in a:4)" Up q
wait_for '[ -z "$(sidebars)" ]'
sleep 0.5
expect "q after an arrow key closes it" "$(sidebars)|$(T show -gqv @pane_notify_sidebar_open)" "|"
expect "closing renders once" "$(wc -l < "$WORK/renders" | tr -d ' ')" 1
toggle
settled
: > "$WORK/renders"
T send-keys -t "$(sidebars)" C-c
wait_for '[ -z "$(sidebars)" ]'
sleep 0.5
expect "Ctrl-C closes it" "$(sidebars)|$(T show -gqv @pane_notify_sidebar_open)" "|"
expect "Ctrl-C renders once" "$(wc -l < "$WORK/renders" | tr -d ' ')" 1
toggle
settled
: > "$WORK/renders"
toggle
wait_for '[ -z "$(sidebars)" ]'
sleep 0.5
expect "the key closes it without a render" "$(wc -l < "$WORK/renders" | tr -d ' ')" 0

section "sidebar keys"
highlighted() { T capture-pane -e -p -t "$1" | grep -a "${2:-$HL}" | grep -ao 'w[0-9]' | tr '\n' ' ' | sed 's/ $//'; }
setup
notify a:1 process 0 12 one
notify a:2 process 0 12 two
notify a:3 process 0 12 three
toggle
wait_for '[ -n "$(sidebar_in a:0)" ] && [ "$(drawn "$(sidebar_in a:0)")" = 3 ]'
sb="$(sidebar_in a:0)"
expect "opening the sidebar focuses it" "$(T display -p -t a:0 '#{pane_id}')" "$sb"
wait_for '[ "$(highlighted "$sb")" = w3 ]'
expect "and highlights the newest entry" "$(eventually 'highlighted "$sb"' w3)" w3
T select-pane -t a:0.0
wait_for '[ -z "$(highlighted "$sb")" ]'
expect "nothing is highlighted while another pane is focused" "$(eventually 'highlighted "$sb"' "")" ""
T select-pane -t "$sb"
wait_for '[ "$(highlighted "$sb")" = w3 ]'
expect "focusing the sidebar highlights the selection again" "$(eventually 'highlighted "$sb"' w3)" w3
T send-keys -t "$sb" Up
sleep 0.3
expect "Up stops at the first entry" "$(eventually 'highlighted "$sb"' w3)" w3
T send-keys -t "$sb" Down
wait_for '[ "$(highlighted "$sb")" = w2 ]'
expect "Down selects the next entry" "$(eventually 'highlighted "$sb"' w2)" w2
T send-keys -t "$sb" Down Down
wait_for '[ "$(highlighted "$sb")" = w1 ]'
sleep 0.3
expect "Down stops at the last entry" "$(eventually 'highlighted "$sb"' w1)" w1
T send-keys -t "$sb" Up
wait_for '[ "$(highlighted "$sb")" = w2 ]'
expect "Up selects the previous entry" "$(eventually 'highlighted "$sb"' w2)" w2
notify a:2 process 0 12 two-again
wait_for '[ "$(T capture-pane -p -t "$sb" | grep -c two-again)" = 1 ]'
expect "the selection stays on a window that notifies again" "$(eventually 'highlighted "$sb"' w2)" w2
T send-keys -t "$sb" x
wait_for '[ "$(count)" = 2 ] && [ "$(drawn "$sb")" = 2 ]'
expect "x removes the selected entry" "$(count)|$(T show -wqv -t a:2 @pane_notify)|$(client_window)" "2||main"
wait_for '[ "$(highlighted "$sb")" = w3 ]'
expect "and selects the entry below it" "$(eventually 'highlighted "$sb"' w3)" w3
T select-pane -t a:0.0
wait_for '[ -z "$(highlighted "$sb")" ]'
expect "leaving the sidebar hides the highlight" "$(eventually 'highlighted "$sb"' "")" ""
T select-pane -t "$sb"
wait_for '[ "$(highlighted "$sb")" = w3 ]'
expect "and coming back keeps the selection" "$(eventually 'highlighted "$sb"' w3)" w3
T send-keys -t "$sb" Enter
wait_for '[ "$(client_window)" = w3 ]'
expect "Enter opens the selected entry's window" "$(client_window)" w3
wait_for '[ "$(count)" = 1 ]'
expect "and removes the entry" "$(count)" 1
expect "and leaves the sidebar unfocused in the old window" "$(T display -p -t a:0.0 '#{pane_active}')" 1

if [ "$TMUX_VERSION" -ge 304 ]; then
  expect "the highlight is a shade of the terminal's background" "$(T show -gqv @pane_notify_selected_bg)" '#484b51'
else
  skipped "the highlight is a shade of the terminal's background" "tmux < 3.4 does not report it"
fi

setup
notify a:1 process 0 12 one
notify a:2 process 0 12 two
notify a:3 process 0 12 three
toggle
wait_for '[ "$(highlighted "$(sidebar_in a:0)")" = w3 ]'
T send-keys -t "$(sidebar_in a:0)" x x
wait_for '[ "$(count)" = 1 ]'
sleep 0.5
expect "x pressed twice in a row removes two entries" "$(count)|$(T show -wqv -t a:1 @pane_notify)" "1|done"
setup "@pane-notify-sidebar-selected '#405060'"
notify a:1 process 0 12 one
toggle
wait_for '[ "$(highlighted "$(sidebar_in a:0)" "48;2;64;80;96m")" = w1 ]'
expect "the highlight colour is an option" "$(eventually 'highlighted "$(sidebar_in a:0)" "48;2;64;80;96m"' w1)" w1

setup "@pane-notify-sidebar-selected '#abc'"
notify a:1 process 0 12 one
toggle
expect "an unreadable highlight colour falls back to reverse video" \
  "$(eventually 'highlighted "$(sidebar_in a:0)" "$REVERSE"' w1)" w1

OUTER_BG=""
setup
notify a:1 process 0 12 one
toggle
wait_for '[ "$(highlighted "$(sidebar_in a:0)" "$REVERSE")" = w1 ]'
expect "without a known background it uses reverse video" "$(eventually 'highlighted "$(sidebar_in a:0)" "$REVERSE"' w1)" w1
toggle
wait_for '[ -z "$(sidebars)" ]'
T set -g window-style 'bg=#123456'
toggle
wait_for '[ "$(highlighted "$(sidebar_in a:0)" "48;2;60;88;116m")" = w1 ]'
expect "a pane style's background is shaded" "$(T show -gqv @pane_notify_selected_bg)" '#3c5874'
toggle
wait_for '[ -z "$(sidebars)" ]'
T set -gu window-style
toggle
wait_for '[ "$(highlighted "$(sidebar_in a:0)" "$REVERSE")" = w1 ]'
expect "and once nothing reports one, reverse video comes back" \
  "$(highlighted "$(sidebar_in a:0)" "$REVERSE")|$(T show -gqv @pane_notify_selected_bg)" "w1|"
OUTER_BG='#20242c'

section "pane widths after the sidebar closes"
widths() { T list-panes -t a:0 -F '#{pane_width}' | tr '\n' ' ' | sed 's/ $//'; }
open_and_close() {
  toggle
  wait_for '[ -n "$(sidebar_in a:0)" ]'
  [ -z "${1:-}" ] || eval "$1"
  toggle
  wait_for '[ -z "$(sidebars)" ]'
}
setup
notify a:1 process 0 12 one
T split-window -h -t a:0.0 \; select-layout -t a:0 even-horizontal
before="$(widths)"
open_and_close
expect "two columns get their widths back" "$(widths)" "$before"
T split-window -h -t a:0.0 \; select-layout -t a:0 even-horizontal \; resize-pane -t a:0.0 -x 25
before="$(widths)"
open_and_close
expect "three uneven columns get their widths back" "$(widths)" "$before"
if [ "$(T show -gqv @pane_notify_floating)" = 1 ]; then
  before="$(widths)"
  open_and_close 'settle_kind 10; T resize-pane -Z -t a:0.0; settle_kind 11; T resize-pane -Z -t a:0.0; settle_kind 10'
  expect "and after a zoom and unzoom while open" "$(widths)" "$before"
fi

section "sidebar and zoom"
setup
notify a:1 process 0 12 one
toggle
wait_for '[ -n "$(sidebar_in a:0)" ]'
if [ "$(T show -gqv @pane_notify_floating)" = 1 ]; then
  settle_kind 10
  T resize-pane -Z -t a:0.0
  settle_kind 11
  expect "zooming the only real pane keeps the zoom" "$(T display -p -t a:0 '#{window_zoomed_flag}')" 1
  expect "and floats the sidebar" "$(sidebar_kind 11)" 1
  T resize-pane -Z -t a:0.0
  settle_kind 10
  expect "unzooming brings the split back" "$(sidebar_kind 10)" 1
else
  skipped "floating sidebar in zoomed windows" "tmux $(tmux -V | cut -d' ' -f2) < 3.8"
fi
: > "$WORK/renders"
T kill-pane -t a:0.0
wait_for '[ "$(T list-windows -t a -F "#{window_name}" | grep -c main)" = 0 ]'
expect "a window left with only its sidebar closes" "$(T list-windows -t a -F '#{window_name}' | grep -c main)" 0
expect "busy flag never left set" "$(T show -gqv @pane_notify_busy)" ""
if [ "$(T show -gqv @pane_notify_floating)" = 1 ]; then
  setup
  notify a:1 process 0 12 one
  T split-window -d -h -t a:0 \; resize-pane -Z -t a:0.0
  toggle
  settle_kind 11
  expect "opening it in a zoomed window keeps the zoom" "$(T display -p -t a:0 '#{window_zoomed_flag}')" 1
  expect "and focuses the floating sidebar" "$(T display -p -t a:0 '#{pane_id}')" "$(sidebar_in a:0)"
fi

section "Claude Code hooks"
if command -v jq >/dev/null; then
  setup
  echo '{"hook_event_name":"Stop"}' | notify a:2 claude
  expect "Stop adds a waiting entry" "$(T show -wqv -t a:2 @pane_notify) $(count)" "waiting 1"
  echo '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}' | notify a:3 claude
  expect "Notification uses its message" "$(T show -gv @pane_notify_entry_2 | field 3)" \
    "Claude needs your permission to use Bash"
  echo '{"hook_event_name":"UserPromptSubmit"}' | notify a:2 claude
  expect "UserPromptSubmit clears the window" "$(T show -wqv -t a:2 @pane_notify) $(count)" " 1"
else
  skipped "Claude Code hooks" "jq not installed"
fi

section "Codex CLI hooks"
if command -v jq >/dev/null; then
  setup
  echo '{"hook_event_name":"Stop","last_assistant_message":"done"}' | notify a:2 codex
  expect "Stop adds a waiting entry" "$(T show -wqv -t a:2 @pane_notify) $(count)" "waiting 1"
  expect "Stop names Codex" "$(T show -gv @pane_notify_entry_1 | field 3)" "Codex is waiting for input"
  echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"Remove the build directory"}}' \
    | notify a:3 codex
  expect "PermissionRequest asks for approval" "$(T show -gv @pane_notify_entry_2 | field 3)" "Codex needs your approval"
  expect "PermissionRequest shows the tool description" "$(T show -gv @pane_notify_entry_2 | field 4)" \
    "Remove the build directory"
  echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}' | notify a:4 codex
  expect "PermissionRequest falls back to the tool name" "$(T show -gv @pane_notify_entry_3 | field 4)" "Bash"
  echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":"ls"}' | notify a:4 codex
  expect "and when tool_input is not an object" "$(T show -gv @pane_notify_entry_4 | field 4)" "Bash"
  echo '{"hook_event_name":"UserPromptSubmit","prompt":"next"}' | notify a:2 codex
  expect "UserPromptSubmit clears the window" "$(T show -wqv -t a:2 @pane_notify) $(count)" " 2"
  expect "hooks print nothing" "$(echo '{"hook_event_name":"Stop"}' | notify a:2 codex)" ""
  setup
  echo '{"hook_event_name":"Stop"}' | notify a:2 nope
  expect "an unknown agent is ignored" "$(entries)" 0
else
  skipped "Codex CLI hooks" "jq not installed"
fi

section "opencode plugin"
if ! command -v jq >/dev/null; then
  skipped "opencode plugin" "jq not installed"
elif ! command -v node >/dev/null; then
  skipped "opencode plugin" "node not installed"
else
  setup
  opencode_plugin a:2 "await status('s1', 'busy'); await status('s1', 'idle');"
  expect "a finished turn adds a waiting entry" "$(T show -wqv -t a:2 @pane_notify) $(count)" "waiting 1"
  expect "and names opencode" "$(T show -gv @pane_notify_entry_1 | field 3)" "opencode is waiting for input"
  opencode_plugin a:3 "await status('s1', 'idle');"
  expect "idle without a turn is ignored" "$(entries)" 1
  opencode_plugin a:3 "await status('s1', 'busy'); await status('s1', 'idle'); await status('s1', 'idle');"
  expect "idle twice after one turn notifies once" "$(T show -gqv @pane_notify_seq)" 2
  opencode_plugin a:4 "await hooks.event({ event: { type: 'permission.asked', properties: {
    sessionID: 's1', permission: 'bash', patterns: ['git push'] } } });"
  expect "permission.asked asks for approval" "$(T show -gv @pane_notify_entry_3 | field 3)" "opencode needs your approval"
  expect "permission.asked shows the patterns" "$(T show -gv @pane_notify_entry_3 | field 4)" "git push"
  opencode_plugin a:4 "await hooks.event({ event: { type: 'permission.updated', properties: {
    sessionID: 's1', type: 'bash', title: 'Run git push' } } });"
  expect "permission.updated shows the title" "$(T show -gv @pane_notify_entry_4 | field 4)" "Run git push"
  opencode_plugin a:3 "await hooks.event({ event: { type: 'question.asked', properties: {
    sessionID: 's1', questions: [{ question: 'Which database?', header: 'Database', options: [] }] } } });"
  expect "question.asked shows the question" "$(T show -gv @pane_notify_entry_5 | field 3)" "Which database?"
  opencode_plugin a:2 "await hooks['chat.message']({ sessionID: 's1' }, {});"
  expect "chat.message clears the window" "$(T show -wqv -t a:2 @pane_notify) $(count)" " 2"
  opencode_plugin a:3 "await hooks['chat.message']({ sessionID: 'child' }, {});"
  expect "a subagent's prompt does not clear it" "$(T show -wqv -t a:3 @pane_notify) $(count)" "waiting 2"
  setup
  opencode_plugin a:2 "await status('child', 'busy'); await status('child', 'idle');"
  expect "a subagent finishing is ignored" "$(entries)" 0
  opencode_plugin "" "await status('s1', 'busy'); await status('s1', 'idle');"
  expect "outside tmux it does nothing" "$? $(entries)" "0 0"
  opencode_plugin a:2 "await status('broken', 'busy'); await status('broken', 'idle');"
  expect "a failed session lookup still notifies" "$(entries)" 1
  opencode_plugin a:3 "await status('missing', 'busy'); await status('missing', 'idle');"
  expect "a lookup returning an error still notifies" "$(entries)" 2
fi

section "lock"
setup
(
  TMUX="$(sock),1,0"
  export TMUX
  source "$N"
  lock="${TMPDIR:-/tmp}/pane-notify-$(id -u)-$(tmux display-message -p '#{pid}').lock"
  ( with_lock sleep 7 ) &
  sleep 0.3
  ( with_lock bash -c "cat '$lock/owner' > '$WORK/b-owner'; sleep 6" ) &
  wait_for '[ -s "$WORK/b-owner" ]' 7
  sleep 3.5
  expect "a stalled holder does not remove its successor's lock" \
    "$([ -d "$lock" ] && cat "$lock/owner")" "$(cat "$WORK/b-owner" 2>/dev/null)"
  wait
  expect "the lock is gone once both finish" "$([ -d "$lock" ] && echo held)" ""
  work() { local i; for ((i = 0; i < 100; i++)); do tmux display -p x >/dev/null; sleep 0.05; done; }
  ( with_lock work ) &
  holder=$!
  wait_for '[ -d "$lock" ]'
  kill -TERM "$holder"
  wait_for '[ ! -d "$lock" ]' 2
  expect "TERM releases the lock" "$([ -d "$lock" ] && echo held)" ""
)

prompts() { T capture-pane -p -S - -t a:5 | grep -c '^__prompt__'; }
shell_case() {
  local desc=$1 cmd=$2 want=$3 seq_before prompts_before
  seq_before="$(T show -gqv @pane_notify_seq)"
  prompts_before="$(prompts)"
  T send-keys -t a:5 "$cmd" Enter
  wait_for "[ \"\$(prompts)\" -gt $prompts_before ]" 8
  sleep 0.8
  expect "$desc" "$([ "$(T show -gqv @pane_notify_seq)" != "$seq_before" ] && echo notified || echo silent)" "$want"
}

newest_field() { T show -gv "@pane_notify_entry_$(T show -gv @pane_notify_seq)" | field "$1"; }

section "bash hook: existing DEBUG trap"
expect "an existing DEBUG trap is kept, after ours" \
  "$(TMUX=x TMUX_PANE=%0 bash --norc --noprofile -c "trap 'seen=\"a b\"' DEBUG; source '$ROOT/pane-notify.bash'; eval \"\$PROMPT_COMMAND\"; trap -p DEBUG" 2>/dev/null | tail -1)" \
  "trap -- '_pane_notify_debug; seen=\"a b\"' DEBUG"

for sh in zsh bash; do
  section "$sh hook"
  if ! command -v "$sh" >/dev/null; then skipped "$sh hook" "$sh not installed"; continue; fi
  setup
  T kill-window -t a:5
  if [ "$sh" = zsh ]; then
    T new-window -d -t a:5 -n w5 "env PANE_NOTIFY_MIN_SECONDS=2 zsh -f -i"
    T send-keys -t a:5 "PROMPT='__prompt__ '; PANE_NOTIFY_IGNORE=(vim sleep); source '$ROOT/pane-notify.zsh'" Enter
  else
    T new-window -d -t a:5 -n w5 "env HISTFILE='$WORK/history' PANE_NOTIFY_MIN_SECONDS=2 bash --norc --noprofile -i"
    T send-keys -t a:5 "PS1='__prompt__ '; PANE_NOTIFY_IGNORE=(vim sleep); source '$ROOT/pane-notify.bash'" Enter
  fi
  wait_for '[ "$(prompts)" -gt 0 ]'
  shell_case "a long command notifies" "sh -c 'sleep 2.5'" notified
  expect "with the command line" "$(newest_field 4)" "sh -c 'sleep 2.5'"
  shell_case "a failing command notifies" "sh -c 'sleep 2.5; exit 3'" notified
  expect "with its exit status" "$(newest_field 3 | sed 's/ after.*//')" "failed (3)"
  shell_case "a short command is silent" "true" silent
  shell_case "an ignored program is silent" "sleep 2.5" silent
  shell_case "ignored behind env and assignments" "X=1 env Y=2 sleep 2.5" silent
  shell_case "ignored behind options with values" "env -u HOME sleep 2.5" silent
done

pass="$(grep -c pass "$RESULTS")" fail="$(grep -c fail "$RESULTS")" skip="$(grep -c skip "$RESULTS")"
printf '\n%d passed, %d failed, %d skipped (tmux %s, bash %s)\n' "$pass" "$fail" "$skip" \
  "$(tmux -V | cut -d' ' -f2)" "${BASH_VERSION%%(*}"
[ "$fail" -eq 0 ]
