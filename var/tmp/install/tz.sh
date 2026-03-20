#!/bin/bash

list_prefix() {
  local prefix result
  prefix="$1"
  if (( ${#prefix} == 0 )); then
    result=$(timedatectl list-timezones | sed -E 's@^(...).*@\1@' | sort -u | tr '\n' ' ')
    result=${result% }
  elif (( ${#prefix} <= 2 )); then
    result=$(timedatectl list-timezones | sed -E 's@^(...).*@\1@' | grep -i "^$prefix" | sort -u | tr '\n' ' ')
    result=${result% }
    if (( ${#result} < 74 )) then
      result=$(timedatectl list-timezones | grep -i "^$prefix" | tr '\n' ' ')
      result=${result% }
    fi
  else
    result=$(timedatectl list-timezones | grep -i "^$prefix" | tr '\n' ' ')
    result=${result% }
  fi
  if [[ $result ]]; then
    echo "$result"
  fi
}

return 2> /dev/null || {
  list_prefix $1
}
