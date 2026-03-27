[[ -v installbase ]] || source /var/tmp/install/common.sh

kb_tree() {
  local kb len=${#1}
  if (( len == 0 )); then
    return 1
  else
    kb=$(ls -1 /usr/lib/kbd/keymaps/xkb | sed 's/\.map\.gz$//' | grep -i "^$1")
    sed -n -E "s/^.{$len}(.).*/\\1/p" <<< "${kb,,}" | sort -u | tr -d '\n'
    grep -q ^$1$ <<< "${kb,,}"
  fi
}

kb_user_read() {
  local result mychar buf
  rm -f /tmp/kbtree.txt
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
      echo us > /tmp/kbtree.txt
      printf "\r\033[Kus\n"
      break
    elif [[ $mychar = $'\12' ]]; then
      if kb_tree "$buf" > /dev/null; then
        echo $buf > /tmp/kbtree.txt
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
    sed -n -E "s/^.{$len}(.).*/\\1/p" <<< "$loc" | sort -u | tr -d '\n'
    grep -q ^$1$ <<< "$loc"
  fi
}

locale_user_read() {
  local result mychar buf
  rm -f /tmp/localetree.txt
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
      echo C.UTF-8 > /tmp/localetree.txt
      printf "\r\033[KC.UTF-8\n"
      break
    elif [[ $mychar = $'\12' ]]; then
      if locale_tree "$buf" > /dev/null; then
        result=$(localectl list-locales | grep -i "^$buf$")
        echo $result > /tmp/localetree.txt
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
    sed -n -E "s/^.{$len}(.).*/\\1/p" <<< "${tz,,}" | sort -u | tr -d '\n'
    grep -q ^$1$ <<< "${tz,,}"
  fi
}

tz_user_read() {
  local result mychar buf
  rm -f /tmp/tztree.txt
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
      echo UTC > /tmp/tztree.txt
      printf "\r\033[KUTC\n"
      break
    elif [[ $mychar = $'\12' ]]; then
      if tz_tree "$buf" > /dev/null; then
        result=$(timedatectl list-timezones | grep -i "^$buf$")
        echo $result > /tmp/tztree.txt
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
