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
IN="pn-test-$$" OUT="pn-outer-$$"
VERBOSE=${1:-}
RESULTS="$WORK/results"

T() { tmux -L "$IN" "$@"; }
O() { tmux -L "$OUT" "$@"; }

cleanup() {
  T kill-server 2>/dev/null
  O kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# Results go to a file so checks inside subshells count too.
ok()      { echo pass >> "$RESULTS"; printf '  ok    %s\n' "$1"; }
bad()     { echo fail >> "$RESULTS"; printf '  FAIL  %s\n        %s\n' "$1" "$2"; }
skipped() { echo skip >> "$RESULTS"; printf '  skip  %s (%s)\n' "$1" "$2"; }

# expect <description> <actual> <expected>
expect() {
  if [ "$2" = "$3" ]; then ok "$1"; [ -z "$VERBOSE" ] || printf '        = %s\n' "$2"
  else bad "$1" "expected [$3], got [$2]"
  fi
}

# Polls a shell condition for up to $2 seconds (default 5).
wait_for() {
  local i
  for ((i = 0; i < ${2:-5} * 10; i++)); do
    eval "$1" && return 0
    sleep 0.1
  done
  return 1
}

section() { printf '\n%s\n' "$1"; }

sock() { T display -p '#{socket_path}'; }
pane_of() { T display -p -t "$1" '#{pane_id}'; }
notify() { TMUX="$(sock),1,0" TMUX_PANE="$(pane_of "$1")" bash "$N" "${@:2}"; }
toggle() { T run-shell "'$N' sidebar-toggle"; }
count() { T show -gqv @pane_notify_count; }
entries() { T show -g | grep -ac '^@pane_notify_entry_'; }
sidebars() { T list-panes -a -F '#{pane_id} #{@pane_notify_sidebar}' | awk '$2 == 1 { print $1 }' | tr '\n' ' ' | sed 's/ $//'; }
sidebar_in() { T list-panes -t "$1" -F '#{pane_id} #{@pane_notify_sidebar}' | awk '$2 == 1 { print $1 }'; }
drawn() { T capture-pane -p -t "$1" | grep -ac '●'; }
client_window() { T list-clients -F '#{window_name}'; }
# Sidebars in window main that are floating (11) or split (10).
sidebar_kind() { T list-panes -t a:0 -F '#{@pane_notify_sidebar}#{?pane_floating_flag,1,0}' | grep -c "^$1\$"; }

# Inner server: session "a" with windows main (viewed) and w1..w5; an outer
# server whose pane runs the inner client, so the client has a real terminal
# (focus, mouse) and everything it writes can be recorded.
setup() {
  T kill-server 2>/dev/null
  O kill-server 2>/dev/null
  : > "$WORK/out.raw"
  T -f /dev/null new-session -d -s a -n main -x 120 -y 30
  T set -g focus-events on \; set -g mouse on \; set -g base-index 0 \
    \; set -g @pane-notify-desktop off \; set-environment -g PANE_NOTIFY_TRACE "$WORK/renders"
  local o
  for o in "$@"; do eval "T set -g $o"; done
  T run-shell "'$ROOT/pane-notify.tmux'"
  local i
  for i in 1 2 3 4 5; do T new-window -d -t "a:$i" -n "w$i"; done
  O -f /dev/null new-session -d -s o -x 120 -y 32 "TMUX= tmux -L $IN attach -t a:0"
  O set -g status off
  O pipe-pane -O -t o "cat >> '$WORK/out.raw'"
  wait_for '[ -n "$(T list-clients)" ]' || { echo "inner client did not attach"; exit 1; }
}

# --- pure functions (sourced) -----------------------------------------------------

section "functions"
(
  # shellcheck source=../scripts/notify.sh
  source "$N"
  LC_ALL="$(utf8_locale)"
  export LC_ALL
  expect "utf8_locale finds a UTF-8 locale" "$([ -n "$LC_ALL" ] && echo yes)" yes
  expect "clean turns control characters into spaces" "$(clean $'a\nb\x07c\x1b]2;x')" "a b c ]2;x"
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
)

# --- plugin load ------------------------------------------------------------------

section "plugin load"
setup
expect "key binding" "$(T list-keys -T prefix a | grep -c sidebar-toggle)" 1
expect "status-right gets the bell" "$(T show -gv status-right | grep -c '@pane-notify-status')" 1
expect "window format gets the badge" "$(T show -gwv window-status-format | grep -c '@pane-notify-badge')" 1
T run-shell "'$ROOT/pane-notify.tmux'"
expect "reload does not add the badge twice" \
  "$(T show -gwv window-status-current-format | grep -o '@pane-notify-badge' | wc -l | tr -d ' ')" 1
expect "follow hooks installed" "$(T show-hooks -g | grep -c 'bar-refresh')" 6

setup "@pane-notify-auto-format off" "@pane-notify-key off"
expect "auto-format off leaves status-right alone" "$(T show -gv status-right | grep -c '@pane-notify-status')" 0
expect "key off binds nothing" "$(T list-keys -T prefix a 2>/dev/null | grep -c sidebar-toggle)" 0

# --- entries ------------------------------------------------------------------------

section "entries"
setup
notify a:0 process 0 12 visible
expect "a window being looked at gets no entry" "$(entries)" 0
notify a:3 process 0 12 $'for i in 1 2\ndo sleep 1; done'
expect "multi-line command keeps its entry" "$(count)" 1
expect "newlines stored as spaces" "$(T show -gv @pane_notify_entry_1 | tr '\037' '|')" \
  "done|w3|finished in 12s|for i in 1 2 do sleep 1; done|$(T display -p -t a:3 '#{window_id}')"
expect "badge set on the window" "$(T show -wv -t a:3 @pane_notify)" done
notify a:2 process 1 75 make
notify a:3 process 0 12 again
expect "newer entry from the same window replaces the old" "$(entries)" 2
expect "newest has the highest sequence" "$(T show -gv @pane_notify_entry_3 | cut -d$'\037' -f4)" again
T select-window -t a:3
wait_for '[ "$(count)" = 1 ]'
expect "opening a window drops its entry" "$(count)" 1
expect "and clears its badge" "$(T show -wqv -t a:3 @pane_notify)" ""
T select-window -t a:2
wait_for '[ -z "$(count)" ]'
expect "bell clears when every entry is seen" "$(count)" ""

# --- desktop notifications ----------------------------------------------------------

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

# --- sidebar ------------------------------------------------------------------------

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
expect "lists both entries" "$(drawn "$sb")" 2
T send-keys -t "$sb" Up
notify a:3 process 0 12 three
wait_for '[ "$(drawn "$sb")" = 3 ]'
expect "redraws after an arrow key" "$(drawn "$sb")" 3
T send-keys -t "$sb" Escape
notify a:4 process 0 12 four
wait_for '[ "$(drawn "$sb")" = 4 ]'
expect "redraws after a lone Esc" "$(drawn "$sb")" 4
O send-keys -t o -l $'\e[<0;95;2M'
wait_for '[ "$(client_window)" = w4 ]'
expect "clicking an entry opens its window" "$(client_window)" w4
wait_for '[ "$(count)" = 3 ]'
expect "and removes the entry" "$(count)" 3
wait_for '[ -n "$(sidebar_in a:4)" ]'
expect "the sidebar follows to the new window" "$([ -n "$(sidebar_in a:4)" ] && [ -z "$(sidebar_in a:0)" ] && echo yes)" yes

# Waits until a sidebar has drawn (its key handlers are then installed) and
# no render is still running.
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
  open_and_close 'T resize-pane -Z -t a:0.0; wait_for "[ \"\$(sidebar_kind 11)\" = 1 ]"; T resize-pane -Z -t a:0.0; wait_for "[ \"\$(sidebar_kind 10)\" = 1 ]"'
  expect "and after a zoom and unzoom while open" "$(widths)" "$before"
fi

section "sidebar and zoom"
setup
notify a:1 process 0 12 one
toggle
wait_for '[ -n "$(sidebar_in a:0)" ]'
if [ "$(T show -gqv @pane_notify_floating)" = 1 ]; then
  T resize-pane -Z -t a:0.0
  wait_for '[ "$(sidebar_kind 11)" = 1 ]'
  expect "zooming the only real pane keeps the zoom" "$(T display -p -t a:0 '#{window_zoomed_flag}')" 1
  expect "and floats the sidebar" "$(sidebar_kind 11)" 1
  T resize-pane -Z -t a:0.0
  wait_for '[ "$(sidebar_kind 10)" = 1 ]'
  expect "unzooming brings the split back" "$(sidebar_kind 10)" 1
else
  skipped "floating sidebar in zoomed windows" "tmux $(tmux -V | cut -d' ' -f2) < 3.8"
fi
: > "$WORK/renders"
T kill-pane -t a:0.0
wait_for '[ "$(T list-windows -t a -F "#{window_name}" | grep -c main)" = 0 ]'
expect "a window left with only its sidebar closes" "$(T list-windows -t a -F '#{window_name}' | grep -c main)" 0
expect "busy flag never left set" "$(T show -gqv @pane_notify_busy)" ""

# --- Claude Code hooks --------------------------------------------------------------

section "Claude Code hooks"
if command -v jq >/dev/null; then
  setup
  echo '{"hook_event_name":"Stop"}' | notify a:2 claude
  expect "Stop adds a waiting entry" "$(T show -wqv -t a:2 @pane_notify) $(count)" "waiting 1"
  echo '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}' | notify a:3 claude
  expect "Notification uses its message" "$(T show -gv @pane_notify_entry_2 | cut -d$'\037' -f3)" \
    "Claude needs your permission to use Bash"
  echo '{"hook_event_name":"UserPromptSubmit"}' | notify a:2 claude
  expect "UserPromptSubmit clears the window" "$(T show -wqv -t a:2 @pane_notify) $(count)" " 1"
else
  skipped "Claude Code hooks" "jq not installed"
fi

# --- lock ---------------------------------------------------------------------------

section "lock"
setup
(
  TMUX="$(sock),1,0"
  export TMUX
  # shellcheck source=../scripts/notify.sh
  source "$N"
  lock="${TMPDIR:-/tmp}/pane-notify-$(id -u)-$(tmux display-message -p '#{pid}').lock"
  # A holds the lock for 7s; B takes it over after ~4s and holds it for 6s.
  ( with_lock sleep 7 ) &
  sleep 0.3
  ( with_lock bash -c "cat '$lock/owner' > '$WORK/b-owner'; sleep 6" ) &
  wait_for '[ -s "$WORK/b-owner" ]' 7
  sleep 3.5
  expect "a stalled holder does not remove its successor's lock" \
    "$([ -d "$lock" ] && cat "$lock/owner")" "$(cat "$WORK/b-owner" 2>/dev/null)"
  wait
  expect "the lock is gone once both finish" "$([ -d "$lock" ] && echo held)" ""
  # Short tmux calls, like a render: bash runs the TERM trap between them.
  work() { local i; for ((i = 0; i < 100; i++)); do tmux display -p x >/dev/null; sleep 0.05; done; }
  ( with_lock work ) &
  holder=$!
  wait_for '[ -d "$lock" ]'
  kill -TERM "$holder"
  wait_for '[ ! -d "$lock" ]' 2
  expect "TERM releases the lock" "$([ -d "$lock" ] && echo held)" ""
)

# --- shell hooks --------------------------------------------------------------------

# Types a command into the shell in window w5 (not viewed), waits for a new
# prompt (the shells print "__prompt__"), then checks whether a notification
# was recorded.
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

newest_field() { T show -gv "@pane_notify_entry_$(T show -gv @pane_notify_seq)" | cut -d$'\037' -f"$1"; }

# A 2s threshold and 2.5s commands: bash before 5.0 measures whole seconds.
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

# --- summary ------------------------------------------------------------------------

pass="$(grep -c pass "$RESULTS")" fail="$(grep -c fail "$RESULTS")" skip="$(grep -c skip "$RESULTS")"
printf '\n%d passed, %d failed, %d skipped (tmux %s, bash %s)\n' "$pass" "$fail" "$skip" \
  "$(tmux -V | cut -d' ' -f2)" "${BASH_VERSION%%(*}"
[ "$fail" -eq 0 ]
