type git &> /dev/null && [[ -e /opt/script/git-prompt.sh ]] && {
  . /opt/script/git-prompt.sh
  PROMPT_COMMAND='__git_ps1 "\u@\h:\W" "\\\$ "'
}
