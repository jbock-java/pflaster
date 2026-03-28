[[ -v installbase ]] || source /var/tmp/install/common.sh

kb_tree() {
  local kb len=${#1}
  if (( len == 0 )); then
    return 1
  else
    kb=$(ls -1 /usr/lib/kbd/keymaps/xkb | sed 's/\.map\.gz$//' | grep -i "^$1")
    [[ $kb ]] || return
    sed -n -E "s/^.{$len}(.).*/\\1/p" <<< "${kb,,}" | sort -u | tr -d '\n'
    grep -q ^$1$ <<< "${kb,,}"
  fi
}

kb_user_read() {
  local result mychar buf
  rm -f /tmp/uiresult.txt
  while :; do
    read -s -N1 mychar
    mychar=${mychar,,}
    if [[ $mychar = $'\177' ]]; then
      if [[ $buf ]]; then
        buf=${buf:0:$(( ${#buf} - 1 ))}
      fi
      if result=$(kb_tree "$buf"); then
        printf "\r\033[K$buf -> [$result]"
      elif [[ $buf ]]; then
        printf "\r\033[K$buf [$result]"
      else
        printf "\r\033[K"
      fi
    elif [[ $mychar = $'\33' ]]; then
      echo us > /tmp/uiresult.txt
      printf "\r\033[Kus\n"
      break
    elif [[ $mychar = $'\12' ]]; then
      if kb_tree "$buf" > /dev/null; then
        echo $buf > /tmp/uiresult.txt
        printf "\r\033[K$buf\n"
        break
      fi
    elif [[ $mychar =~ [a-z0-9_-] ]]; then
      if result=$(kb_tree "$buf$mychar"); then
        buf=$buf$mychar
        printf "\r\033[K$buf -> [$result]"
        continue
      elif [[ -z $result ]]; then
        continue
      elif (( ${#result} != 1 )); then
        buf=$buf$mychar
        printf "\r\033[K$buf [$result]"
        continue
      fi
      buf=$buf$mychar$result
      while :; do
        if result=$(kb_tree "$buf"); then
          printf "\r\033[K$buf -> [$result]"
          break
        elif (( ${#result} == 1 )); then
          buf=$buf$result
        else
          printf "\r\033[K$buf [$result]"
          break
        fi
      done
    fi
  done
}

locale_tree() {
  local loc len=${#1}
  if (( len == 0 )); then
    return 1
  else
    loc=$(localectl list-locales | tr '[:upper:]' '[:lower:]' | grep "^$1")
    [[ $loc ]] || return
    sed -n -E "s/^.{$len}(.).*/\\1/p" <<< "$loc" | sort -u | tr -d '\n'
    grep -q ^$1$ <<< "$loc"
  fi
}

locale_user_read() {
  local result mychar buf
  rm -f /tmp/uiresult.txt
  while :; do
    read -s -N1 mychar
    mychar=${mychar,,}
    if [[ $mychar = $'\177' ]]; then
      if [[ $buf ]]; then
        buf=${buf:0:$(( ${#buf} - 1 ))}
      fi
      if result=$(locale_tree "$buf"); then
        printf "\r\033[K$buf -> [$result]"
      elif [[ $buf ]]; then
        printf "\r\033[K$buf [$result]"
      else
        printf "\r\033[K"
      fi
    elif [[ $mychar = $'\33' ]]; then
      echo C.UTF-8 > /tmp/uiresult.txt
      printf "\r\033[KC.UTF-8\n"
      break
    elif [[ $mychar = $'\12' ]]; then
      if locale_tree "$buf" > /dev/null; then
        result=$(localectl list-locales | grep -i "^$buf$")
        echo $result > /tmp/uiresult.txt
        printf "\r\033[K$result\n"
        break
      fi
    elif [[ $mychar =~ [a-z0-9._@+-] ]]; then
      if result=$(locale_tree "$buf$mychar"); then
        buf=$buf$mychar
        printf "\r\033[K$buf -> [$result]"
        continue
      elif [[ -z $result ]]; then
        continue
      elif (( ${#result} != 1 )); then
        buf=$buf$mychar
        printf "\r\033[K$buf [$result]"
        continue
      fi
      buf=$buf$mychar$result
      while :; do
        if result=$(locale_tree "$buf"); then
          printf "\r\033[K$buf -> [$result]"
          break
        elif (( ${#result} == 1 )); then
          buf=$buf$result
        else
          printf "\r\033[K$buf [$result]"
          break
        fi
      done
    fi
  done
}

tz_tree() {
  local tz len=${#1}
  if (( len == 0 )); then
    return 1
  else
    tz=$(timedatectl list-timezones | grep -i "^$1")
    [[ $tz ]] || return
    sed -n -E "s/^.{$len}(.).*/\\1/p" <<< "${tz,,}" | sort -u | tr -d '\n'
    grep -q ^$1$ <<< "${tz,,}"
  fi
}

tz_user_read() {
  local result mychar buf
  rm -f /tmp/uiresult.txt
  while :; do
    read -s -N1 mychar
    mychar=${mychar,,}
    if [[ $mychar = $'\177' ]]; then
      if [[ $buf ]]; then
        buf=${buf:0:$(( ${#buf} - 1 ))}
      fi
      if result=$(tz_tree "$buf"); then
        printf "\r\033[K$buf -> [$result]"
      elif [[ $buf ]]; then
        printf "\r\033[K$buf [$result]"
      else
        printf "\r\033[K"
      fi
    elif [[ $mychar = $'\33' ]]; then
      echo UTC > /tmp/uiresult.txt
      printf "\r\033[KUTC\n"
      break
    elif [[ $mychar = $'\12' ]]; then
      if tz_tree "$buf" > /dev/null; then
        result=$(timedatectl list-timezones | grep -i "^$buf$")
        echo $result > /tmp/uiresult.txt
        printf "\r\033[K$result\n"
        break
      fi
    elif [[ $mychar =~ [a-z0-9/_+-] ]]; then
      if result=$(tz_tree "$buf$mychar"); then
        buf=$buf$mychar
        printf "\r\033[K$buf -> [$result]"
        continue
      elif [[ -z $result ]]; then
        continue
      elif (( ${#result} != 1 )); then
        buf=$buf$mychar
        printf "\r\033[K$buf [$result]"
        continue
      fi
      buf=$buf$mychar$result
      while :; do
        if result=$(tz_tree "$buf"); then
          printf "\r\033[K$buf -> [$result]"
          break
        elif (( ${#result} == 1 )); then
          buf=$buf$result
        else
          printf "\r\033[K$buf [$result]"
          break
        fi
      done
    fi
  done
}

# $1: options
# $2: buf
generic_tree() {
  local matches len=${#2}
  if (( len == 0 )); then
    return 1
  else
    matches=$(grep -i "^$2" <<< "$1")
    [[ $matches ]] || return
    sed -n -E "s/^.{$len}(.).*/\\1/p" <<< "$matches" | sort -u | tr -d '\n'
    grep -q "^$2$" <<< "$matches"
  fi
}

select_from() {
  local result mychar buf
  rm -f /tmp/uiresult.txt
  while :; do
    read -s -N1 mychar
    mychar=${mychar,,}
    if [[ $mychar = $'\177' ]]; then
      if [[ $buf ]]; then
        buf=${buf:0:$(( ${#buf} - 1 ))}
      fi
      if result=$(generic_tree "$1" "$buf"); then
        printf "\r\033[K$buf -> [$result]"
      elif [[ $buf ]]; then
        printf "\r\033[K$buf [$result]"
      else
        printf "\r\033[K"
      fi
    elif [[ $mychar = $'\33' ]]; then
      echo us > /tmp/uiresult.txt
      printf "\r\033[Kus\n"
      break
    elif [[ $mychar = $'\12' ]]; then
      if generic_tree "$1" "$buf" > /dev/null; then
        echo $buf > /tmp/uiresult.txt
        printf "\r\033[K$buf\n"
        break
      fi
    elif [[ $mychar =~ [a-z0-9_-] ]]; then
      if result=$(generic_tree "$1" "$buf$mychar"); then
        buf=$buf$mychar
        printf "\r\033[K$buf -> [$result]"
        continue
      elif [[ -z $result ]]; then
        continue
      elif (( ${#result} != 1 )); then
        buf=$buf$mychar
        printf "\r\033[K$buf [$result]"
        continue
      fi
      buf=$buf$mychar$result
      while :; do
        if result=$(generic_tree "$1" "$buf"); then
          printf "\r\033[K$buf -> [$result]"
          break
        elif (( ${#result} == 1 )); then
          buf=$buf$result
        else
          printf "\r\033[K$buf [$result]"
          break
        fi
      done
    fi
  done
}

choose() {
  local what="$1" REPLY choice options=() options_nl
  [[ $what ]] || return
  choice=$(getarg pf.$what)
  if [[ $choice ]]; then
    jqi ".$what = \"$choice\""
    echo "$what=$choice specified via command line"
    return
  elif [[ -f $installbase/profile.json ]] && jq -e "has(\"$what\")" $installbase/profile.json > /dev/null; then
    choice=$(jq -r ".$what" $installbase/profile.json)
    read -rp "$what $choice is configured. Keep it? [Y/n] "
    [[ -z $REPLY || $REPLY =~ [yY] ]] && return
  fi
  for choice in $(jq -r ".$what | keys[]" $installbase/config.json); do
    options+=($choice)
  done
  case ${#options[@]} in
    0)
      echo "ERROR: Got nothing to choose from."
      return 1
      ;;
    1)
      jqi ".$what = \"${options[@]}\""
      echo "$what=${options[@]} is the only option"
      return
      ;;
    *)
      local col=0
      for choice in "${options[@]}"; do
        (( col < ${#choice} && ( col = ${#choice} ) ))
      done
      echo "$what:"
      for choice in "${options[@]}"; do
        printf "  %-$((col))s - %s\n" $choice "$(jq -r .$what.$choice.banner $installbase/config.json)"
      done
      echo "Starting $what selection. You can accept with Return when an arrow appears."
      select_from "$(tr ' ' '\n' <<< ${options[@]})" || return
      [[ -f /tmp/uiresult.txt ]] || return
      jqi ".$what = \"$(< /tmp/uiresult.txt)\""
      ;;
  esac
}
