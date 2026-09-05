#!/bin/bash

entrypoint=${BASH_SOURCE[0]}
case "$entrypoint" in
  /*) ;;
  *) entrypoint="$PWD/$entrypoint" ;;
esac
launcher="${entrypoint%/*}/evals-launcher.sh"
requested_tmp=${TMPDIR:-/tmp}
/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin TMPDIR="$requested_tmp" \
  /bin/bash "$launcher" "$@"
