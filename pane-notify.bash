# shellcheck shell=bash
# pane-notify: tell tmux when a long-running command finishes (bash 3.2+).
#
#   PANE_NOTIFY_MIN_SECONDS  only commands at least this long (default 10)
#   PANE_NOTIFY_IGNORE       first words that never notify (interactive tools)
#
# Uses bash-preexec when it is loaded; otherwise a DEBUG trap (chained after
# any existing one) and PROMPT_COMMAND.

[[ -n $TMUX && -n $TMUX_PANE ]] || return 0

_pane_notify_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/notify.sh"
_pane_notify_cmd="" _pane_notify_start="" _pane_notify_armed=""
: "${PANE_NOTIFY_MIN_SECONDS:=10}"
[[ ${PANE_NOTIFY_IGNORE+set} ]] || PANE_NOTIFY_IGNORE=(
  vi vim nvim less more man ssh mosh tmux top htop btop claude fzf lazygit tig watch tail
)

_pane_notify_now() {
  if [[ -n ${EPOCHSECONDS:-} ]]; then printf '%s' "$EPOCHSECONDS"; else date +%s; fi
}

_pane_notify_preexec() {
  _pane_notify_cmd=$1
  _pane_notify_start="$(_pane_notify_now)"
}

# Skip assignments, wrappers and their options: sudo -u deploy vim,
# env X=1 nvim.
_pane_notify_ignored() {
  local word wrapper="" skip=0 first="" ignored
  local -a words=()
  read -ra words <<<"$1"
  for word in "${words[@]}"; do
    if (( skip )); then skip=0; continue; fi
    case $word in
      sudo|env|command|builtin|exec|nohup|time) wrapper=$word ;;
      [A-Za-z_]*=*) ;;
      -*)
        case $wrapper:$word in
          sudo:-[CDghpRrTUu]|sudo:--chdir|sudo:--close-from|sudo:--command-timeout|sudo:--group|sudo:--host|\
          sudo:--other-user|sudo:--prompt|sudo:--role|sudo:--type|sudo:--user|\
          env:-[CPSu]|env:--chdir|env:--split-string|env:--unset|exec:-a) skip=1 ;;
        esac
        ;;
      *) first=$word; break ;;
    esac
  done
  for ignored in "${PANE_NOTIFY_IGNORE[@]}"; do
    [[ $first == "$ignored" ]] && return 0
  done
  return 1
}

_pane_notify_precmd() {
  local exit_status=$? elapsed cmd
  [[ -n $_pane_notify_start ]] || return 0
  elapsed=$(( $(_pane_notify_now) - _pane_notify_start ))
  cmd=$_pane_notify_cmd
  _pane_notify_start=""

  (( elapsed >= PANE_NOTIFY_MIN_SECONDS )) || return 0
  # Ctrl-C / Ctrl-Z: the user is already at the pane.
  (( exit_status == 130 || exit_status == 148 )) && return 0
  _pane_notify_ignored "$cmd" && return 0

  ( "$_pane_notify_bin" process "$exit_status" "$elapsed" "$cmd" >/dev/null 2>&1 & )
}

if declare -F __bp_preexec_invoke_exec >/dev/null; then
  # shellcheck disable=SC2034 # read by bash-preexec
  preexec_functions+=(_pane_notify_preexec)
  precmd_functions=(_pane_notify_precmd "${precmd_functions[@]}")
else
  # The DEBUG trap fires for every simple command, including those run by
  # PROMPT_COMMAND; only the first one after the prompt is the user's.
  _pane_notify_debug() {
    [[ -n $_pane_notify_armed ]] || return 0
    case $BASH_COMMAND in _pane_notify_*) return 0 ;; esac
    _pane_notify_armed=""
    local line
    line="$(HISTTIMEFORMAT='' builtin history 1 2>/dev/null)"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#*[[:space:]]}"
    line="${line#"${line%%[![:space:]]*}"}"
    _pane_notify_preexec "${line:-$BASH_COMMAND}"
  }
  _pane_notify_arm() { _pane_notify_armed=1; }

  # trap -p prints "trap -- '<command>' DEBUG", quoted for reuse.
  _pane_notify_chain_trap() {
    eval "set -- $(trap -p DEBUG)"
    # shellcheck disable=SC2064 # the existing command, expanded now
    case ${3:-} in
      *_pane_notify_debug*) ;;
      "") trap '_pane_notify_debug' DEBUG ;;
      *) trap "_pane_notify_debug; $3" DEBUG ;;
    esac
  }
  _pane_notify_chain_trap

  # First, so $? is still the command's exit status; arming last, so the rest
  # of PROMPT_COMMAND is not taken for the user's command. bash 5.1+ allows an
  # array.
  if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
    [[ " ${PROMPT_COMMAND[*]} " == *" _pane_notify_precmd "* ]] ||
      PROMPT_COMMAND=(_pane_notify_precmd "${PROMPT_COMMAND[@]}" _pane_notify_arm)
  else
    case ${PROMPT_COMMAND:-} in
      *_pane_notify_precmd*) ;;
      *) PROMPT_COMMAND="_pane_notify_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}; _pane_notify_arm" ;;
    esac
  fi
fi
