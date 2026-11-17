# pane-notify: tell tmux when a long-running command finishes.
#
#   PANE_NOTIFY_MIN_SECONDS  only commands at least this long (default 10)
#   PANE_NOTIFY_IGNORE       first words that never notify (interactive tools)

[[ -n $TMUX && -n $TMUX_PANE ]] || return 0

zmodload zsh/datetime
typeset -g _pane_notify_bin="${${(%):-%x}:A:h}/scripts/notify.sh"
typeset -g _pane_notify_cmd="" _pane_notify_start=""
: ${PANE_NOTIFY_MIN_SECONDS:=10}
(( ${+PANE_NOTIFY_IGNORE} )) || typeset -ga PANE_NOTIFY_IGNORE=(
  vi vim nvim less more man ssh mosh tmux top htop btop claude fzf lazygit tig watch tail theme
)

_pane_notify_preexec() {
  _pane_notify_cmd=$1
  _pane_notify_start=$EPOCHREALTIME
}

_pane_notify_precmd() {
  local exit_status=$?
  [[ -n $_pane_notify_start ]] || return 0
  local elapsed=$(( EPOCHREALTIME - _pane_notify_start ))
  local cmd=$_pane_notify_cmd
  _pane_notify_start=""

  (( elapsed >= PANE_NOTIFY_MIN_SECONDS )) || return 0
  (( exit_status == 130 || exit_status == 148 )) && return 0
  local word first="" wrapper="" skip=0
  for word in ${(z)cmd}; do
    if (( skip )); then skip=0; continue; fi
    case $word in
      sudo|env|command|builtin|exec|nocorrect|noglob|nohup|time) wrapper=$word ;;
      [A-Za-z_]*=*) ;;
      -*)
        case $wrapper:$word in
          sudo:-[CDghpRrTUu]|sudo:--(chdir|close-from|command-timeout|group|host|other-user|prompt|role|type|user)) skip=1 ;;
          env:-[CPSu]|env:--(chdir|split-string|unset)|exec:-a) skip=1 ;;
        esac
        ;;
      *) first=$word; break ;;
    esac
  done
  (( ${PANE_NOTIFY_IGNORE[(Ie)$first]} )) && return 0

  "$_pane_notify_bin" process "$exit_status" "${elapsed%.*}" "$cmd" &!
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _pane_notify_preexec
precmd_functions=(_pane_notify_precmd ${precmd_functions:#_pane_notify_precmd})
