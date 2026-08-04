#!/usr/bin/env bash
set -u

reject() {
  printf 'launchctl-readonly: unsupported command or arguments\n' >&2
  exit 64
}

subcommand=${1:-}
case "$subcommand" in
  list|managerpid|manageruid|managername|variant|version)
    [ "$#" -eq 1 ] || reject
    ;;
  print-disabled)
    [ "$#" -eq 2 ] || reject
    [[ "$2" =~ ^(system|user/[0-9]+|gui/[0-9]+|session/[0-9]+|pid/[0-9]+)$ ]] || reject
    ;;
  error)
    if [ "$#" -eq 2 ]; then
      [[ "$2" =~ ^-?[0-9]+$ ]] || reject
    elif [ "$#" -eq 3 ]; then
      [[ "$2" =~ ^(posix|mach|bootstrap)$ && "$3" =~ ^-?[0-9]+$ ]] || reject
    else
      reject
    fi
    ;;
  help)
    [ "$#" -le 2 ] || reject
    ;;
  *)
    reject
    ;;
esac

[ -x /bin/launchctl ] || {
  printf 'launchctl-readonly: /bin/launchctl unavailable\n' >&2
  exit 69
}
exec /bin/launchctl "$@"
