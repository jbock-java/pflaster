#!/bin/bash

list_prefix() {
  local prefix result
  prefix="$1"
  if (( ${#prefix} <= 2 )); then
    result=$(timedatectl list-timezones | sed -E 's@^(...).*@\1@' | sort -u | tr '\n' ' ')
    result=${result% }
    echo "$result"
  else
    result=$(timedatectl list-timezones | grep -i "^$prefix" | tr '\n' ' ')
    result=${result% }
    if [[ $result ]]; then
      echo "$result"
    else
      echo "-- no match --"
    fi
  fi
}

return 2> /dev/null || {
  list_prefix $1
}
