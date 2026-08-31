#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
[ "$#" -eq 2 ] || exit 64
[ -z "${GH_TOKEN-}${GITHUB_TOKEN-}${AWS_SECRET_ACCESS_KEY-}${SSH_AUTH_SOCK-}" ] || exit 70
request=$1
jq_bin=$2
"$jq_bin" -e '
  type == "object" and
  (keys | sort) == ["artifact","candidate_root","case_id","phase","protocol"] and
  .protocol == "ystack.fake-adapter.v1" and .phase == "forge" and
  (.case_id | test("\\Amatrix-(aa|ab|ba|bb)\\z")) and
  (.candidate_root | type == "string" and startswith("/")) and
  (.artifact | type == "object" and
    (keys | sort) == ["content","sha256"] and
    (.content | type == "string") and
    (.sha256 | test("\\A[0-9a-f]{64}\\z")))
' "$request" >/dev/null
candidate_root=$("$jq_bin" -r '.candidate_root' "$request")
content=$("$jq_bin" -r '.artifact.content' "$request")
digest=$(/usr/bin/printf '%s' "$content" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
[ "$digest" = "$("$jq_bin" -r '.artifact.sha256' "$request")" ]
/bin/mkdir -m 700 "$candidate_root"
/usr/bin/git init -q "$candidate_root"
/usr/bin/printf '%s' "$content" > "$candidate_root/result.txt"
/usr/bin/git -C "$candidate_root" add result.txt
/usr/bin/git -C "$candidate_root" commit -q -m candidate
commit_id=$(/usr/bin/git -C "$candidate_root" rev-parse HEAD)
tree_id=$(/usr/bin/git -C "$candidate_root" rev-parse 'HEAD^{tree}')
object_id=$(/usr/bin/git -C "$candidate_root" rev-parse HEAD:result.txt)
"$jq_bin" -S -c -n --arg commit "$commit_id" --arg tree "$tree_id" --arg object "$object_id" '
  {commit_id:$commit,file_object_id:$object,package_id:"fake.forge.a",phase:"forge",
   protocol:"ystack.fake-adapter.v1",status:"ok",tree_id:$tree}'
