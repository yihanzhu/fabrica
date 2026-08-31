#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
[ "$#" -eq 2 ] || exit 64
[ -z "${GH_TOKEN-}${GITHUB_TOKEN-}${AWS_SECRET_ACCESS_KEY-}${SSH_AUTH_SOCK-}" ] || exit 70
request=$1
jq_bin=$2
"$jq_bin" -e '
  type == "object" and
  (keys | sort) == ["case_id","phase","protocol","source_sha256"] and
  .protocol == "ystack.fake-adapter.v1" and .phase == "producer" and
  (.case_id | test("\\Amatrix-(aa|ab|ba|bb)\\z")) and
  (.source_sha256 | test("\\A[0-9a-f]{64}\\z"))
' "$request" >/dev/null
content='portable candidate'
digest=$(/usr/bin/printf '%s' "$content" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
"$jq_bin" -S -c -n --arg content "$content" --arg digest "$digest" '
  {artifact:{content:$content,sha256:$digest},package_id:"fake.producer.a",
   phase:"producer",protocol:"ystack.fake-adapter.v1",status:"ok"}'
