# shellcheck shell=bash
set -uo pipefail

resolver_entry_source=${BASH_SOURCE[0]}
case "$resolver_entry_source" in
  /*) ;;
  *) printf '%s\n' 'E_RUNTIME binding' >&2; exit 1 ;;
esac
resolver_entry_dir=${resolver_entry_source%/*}
resolver_entry_repo=${resolver_entry_dir%/resolver/v1}
if [ "$resolver_entry_dir" = "$resolver_entry_source" ] ||
   [ ! -f "$resolver_entry_repo/scripts/lib/profile-resolution.sh" ] ||
   [ -L "$resolver_entry_repo/scripts/lib/profile-resolution.sh" ]; then
  printf '%s\n' 'E_RUNTIME binding' >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$resolver_entry_repo/scripts/lib/profile-resolution.sh" || {
  printf '%s\n' 'E_RUNTIME binding' >&2
  exit 1
}
profile_resolution_main "$@"
