# bash 补全：source 本文件，或放进 /etc/bash_completion.d/
_moonmux() {
  local cur
  cur="${COMP_WORDS[COMP_CWORD]}"
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "info demux mux cat split extract dump tags tag seek verify to-wav chop version help" -- "$cur") )
  else
    COMPREPLY=( $(compgen -f -- "$cur") )
  fi
}
complete -F _moonmux moonmux
