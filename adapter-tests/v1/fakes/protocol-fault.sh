#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
[ "$#" -eq 3 ] || exit 64
[ -z "${GH_TOKEN-}${GITHUB_TOKEN-}${AWS_SECRET_ACCESS_KEY-}${SSH_AUTH_SOCK-}" ] || exit 70
mode=$1
jq_bin=$3
case "$mode" in
  empty) ;;
  malformed) /usr/bin/printf '{\n' ;;
  partial) /usr/bin/printf '%s\n' '{"package_id":"fake.protocol-fault","phase":"producer","protocol":"ystack.fake-adapter.v1","status":"ok"}' ;;
  degraded) /usr/bin/printf '%s\n' '{"package_id":"fake.protocol-fault","phase":"producer","protocol":"ystack.fake-adapter.v1","status":"degraded"}' ;;
  relabelled)
    "$jq_bin" -S -c -n '{artifact:{content:"portable candidate",sha256:("0"*64)},
      package_id:"fake.producer.a",phase:"forge",protocol:"ystack.fake-adapter.v1",status:"ok"}'
    ;;
  timeout) /bin/sleep 5 ;;
  transport) exit 9 ;;
  *) exit 64 ;;
esac
