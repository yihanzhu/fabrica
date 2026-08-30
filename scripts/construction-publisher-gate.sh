#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C
unset GH_REPO
unset GH_HOST

readonly CPG_REPOSITORY='yihanzhu/ystack'
readonly CPG_REPOSITORY_ID=1270665750
readonly CPG_DEFAULT_BRANCH='main'
readonly CPG_MODE_BLOB='4f35b0ec232e584973071a8d2e90ee5971af6e79'
readonly CPG_ROADMAP_BLOB='4bb0fff1ee11c20441cc16182337f762300ac0f2'
readonly CPG_NORTH_STAR_BLOB='d2bbe82a8b2a1bb14fde1c50995f7ecec9b58013'
readonly CPG_RULESET_ID=21500323
readonly CPG_CI_NAME='ci'
readonly CPG_CI_APP_ID=15368
readonly CPG_CONNECTOR_TOOL='github_merge_pull_request'
readonly CPG_CONNECTOR_LOGIN='yihanzhu'
readonly CPG_CONNECTOR_ID=48186361
readonly CPG_CONNECTOR_IDENTITY_TOOL='github_get_user_login'
readonly CPG_REVIEW_HEADER='## Codex reviewer (cross-vendor, read-only)'
readonly CPG_PROTECTED_GATE='scripts/construction-publisher-gate.sh'
readonly CPG_PROTECTED_TEST='scripts/test/construction-publisher-gate.test.sh'
readonly CPG_SESSION_PUBLISHER='current-operator-authorized-codex-construction-session'

cpg_usage() {
  cat >&2 <<'EOF'
usage:
  construction-publisher-gate.sh preflight <request.json>
  construction-publisher-gate.sh postflight <request.json> <preflight.json> <merge-result.json>

preflight is read-only. It validates one active yihanzhu/ystack construction
candidate and prints the exact, single GitHub connector call that is eligible.
Run the installed script by absolute path from a dedicated trusted main worktree
whose HEAD is the request's expected_base. Never run a candidate-branch copy.
The active construction session must have read the complete independent review
and must supply its exact comment ID and body digest in request.json. Before
preflight, that session must call the purpose-built github_get_user_login tool
and attest its yihanzhu/48186361 result in the same request.
The review body has no machine verdict. The session's explicit semantic decision
is the authority for zero unresolved Important findings; the script only binds
that decision to the exact immutable comment bytes and rejects known P0-P2 marks.

The only permitted write is a separate, purpose-built connector call using the
printed arguments. If that connector is unavailable or refused, stop. Never
fall back to gh, REST, GraphQL, auto-merge, update-ref, or another write path.

Save the connector's normalized {merged,sha,message} result. If the response is
lost after dispatch, save {"outcome":"uncertain"}; postflight reconciles from
GitHub and never retries the write. postflight then
checks the GitHub PR, squash parent, tree, and main ref and prints a canonical
receipt. Keep that stdout in the durable construction task record. Neither
command performs a GitHub write.
EOF
}

cpg_die() {
  printf 'construction-publisher-gate: %s\n' "$1" >&2
  exit 1
}

cpg_need_tools() {
  local tool
  for tool in gh git jq mktemp grep awk cat cmp dirname mv pwd rm; do
    command -v "$tool" >/dev/null 2>&1 || cpg_die "missing required command: $tool"
  done
  if ! command -v sha256sum >/dev/null 2>&1 &&
     ! command -v shasum >/dev/null 2>&1; then
    cpg_die 'missing required SHA-256 command'
  fi
}

cpg_validate_trusted_source() {
  local expected_base="$1"
  local source_path="${BASH_SOURCE[0]}"
  local source_dir
  local repo_root
  local local_head
  local gate_blob
  local test_blob

  case "$source_path" in
    /*) ;;
    *) source_path="$PWD/$source_path" ;;
  esac
  [ -f "$source_path" ] && [ ! -L "$source_path" ] ||
    cpg_die 'publisher gate source must be a regular non-symlink file'
  source_dir="$(CDPATH='' cd -P -- "$(dirname -- "$source_path")" && pwd -P)" ||
    cpg_die 'could not resolve publisher gate source'
  repo_root="$(git -C "$source_dir" rev-parse --show-toplevel 2>/dev/null)" ||
    cpg_die 'publisher gate is not running from a Git worktree'
  [ "$source_dir/construction-publisher-gate.sh" = "$repo_root/$CPG_PROTECTED_GATE" ] ||
    cpg_die 'publisher gate is not running from its installed repository path'
  local_head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)" ||
    cpg_die 'could not read trusted publisher HEAD'
  [ "$local_head" = "$expected_base" ] ||
    cpg_die 'publisher gate must run from the exact reviewed base commit'
  gate_blob="$(git -C "$repo_root" rev-parse "HEAD:$CPG_PROTECTED_GATE" 2>/dev/null)" ||
    cpg_die 'installed publisher gate is absent from the reviewed base'
  test_blob="$(git -C "$repo_root" rev-parse "HEAD:$CPG_PROTECTED_TEST" 2>/dev/null)" ||
    cpg_die 'installed publisher test is absent from the reviewed base'
  [ "$(git -C "$repo_root" hash-object "$repo_root/$CPG_PROTECTED_GATE")" = "$gate_blob" ] ||
    cpg_die 'running publisher gate differs from the trusted base blob'
  CPG_LOCAL_GATE_BLOB="$gate_blob"
  CPG_LOCAL_TEST_BLOB="$test_blob"
  readonly CPG_LOCAL_GATE_BLOB CPG_LOCAL_TEST_BLOB
}

cpg_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

cpg_api() {
  gh api \
    --hostname github.com \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$1"
}

cpg_api_pages() {
  gh api \
    --hostname github.com \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    --paginate --slurp "$1"
}

cpg_get() {
  local endpoint="$1"
  local output="$2"
  cpg_api "$endpoint" > "$output" || cpg_die 'GitHub read failed'
  jq -e . "$output" >/dev/null 2>&1 || cpg_die 'GitHub returned invalid JSON'
}

cpg_get_pages() {
  local endpoint="$1"
  local output="$2"
  cpg_api_pages "$endpoint" > "$output" || cpg_die 'paginated GitHub read failed'
  jq -e . "$output" >/dev/null 2>&1 || cpg_die 'GitHub returned invalid paginated JSON'
}

cpg_decode_content() {
  local response="$1"
  local output="$2"
  jq -e '.type == "file" and .encoding == "base64" and
         (.sha | type == "string") and (.content | type == "string")' \
    "$response" >/dev/null 2>&1 || cpg_die 'GitHub content response is malformed'
  jq -j '.content | gsub("[\\t\\n\\r ]"; "") | @base64d' "$response" > "$output" ||
    cpg_die 'GitHub content is not valid base64'
}

cpg_validate_request() {
  local request="$1"
  jq -e \
    --arg repository "$CPG_REPOSITORY" \
    --argjson repository_id "$CPG_REPOSITORY_ID" \
    --arg connector_tool "$CPG_CONNECTOR_TOOL" \
    --arg connector_login "$CPG_CONNECTOR_LOGIN" \
    --arg identity_tool "$CPG_CONNECTOR_IDENTITY_TOOL" '
      type == "object" and
      keys == ["allowed_paths","connector","expected_base","expected_head",
               "pull_request","repository","repository_id","review","schema_version"] and
      .schema_version == 1 and
      .repository == $repository and
      .repository_id == $repository_id and
      (.pull_request | type == "number" and . > 0 and floor == .) and
      (.expected_head | type == "string" and test("\\A[0-9a-f]{40}\\z")) and
      (.expected_base | type == "string" and test("\\A[0-9a-f]{40}\\z")) and
      .expected_head != .expected_base and
      (.allowed_paths | type == "array" and length > 0 and length <= 64) and
      all(.allowed_paths[];
        type == "string" and length > 0 and length <= 240 and
        test("\\A[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\\z") and
        (split("/") | all(. != "." and . != ".." and . != ".git"))) and
      (.allowed_paths | length) == (.allowed_paths | unique | length) and
      (.connector | type == "object" and
        keys == ["id","identity_attested_by","identity_observation_tool",
                 "identity_observed","login","tool"] and
        .id == 48186361 and .tool == $connector_tool and .login == $connector_login and
        .identity_observation_tool == $identity_tool and .identity_observed == true and
        (.identity_attested_by | type == "string" and length > 0)) and
      (.review | type == "object" and
        keys == ["attested_by","body_sha256","comment_id","complete_review_read",
                 "independent_review_run","machine_verdict_available",
                 "semantic_decision","semantic_decision_source",
                 "unresolved_important_findings"] and
        (.comment_id | type == "number" and . > 0 and floor == .) and
        (.body_sha256 | type == "string" and test("\\A[0-9a-f]{64}\\z")) and
        .independent_review_run == true and
        .complete_review_read == true and
        .machine_verdict_available == false and
        .semantic_decision == "no_unresolved_important" and
        .semantic_decision_source == "current-session-read-complete-review" and
        .unresolved_important_findings == 0 and
        (.attested_by | type == "string" and length > 0)) and
      .connector.identity_attested_by == .review.attested_by
    ' "$request" >/dev/null 2>&1 || cpg_die 'request schema or construction attestation is invalid'
}

cpg_validate_repo() {
  local repo_json="$1"
  jq -e \
    --arg name "$CPG_REPOSITORY" \
    --arg branch "$CPG_DEFAULT_BRANCH" \
    --argjson id "$CPG_REPOSITORY_ID" '
      .full_name == $name and .id == $id and .default_branch == $branch and
      .archived == false and .allow_squash_merge == true and
      .allow_merge_commit == false and .allow_rebase_merge == false and
      .allow_auto_merge == false
    ' "$repo_json" >/dev/null 2>&1 || cpg_die 'repository identity or squash-only settings mismatch'
}

cpg_validate_mode() {
  local mode="$1"
  local attested_by="$2"
  jq -e \
    --arg repository "$CPG_REPOSITORY" \
    --argjson repository_id "$CPG_REPOSITORY_ID" \
    --arg branch "$CPG_DEFAULT_BRANCH" \
    --arg attested_by "$attested_by" \
    --argjson ruleset_id "$CPG_RULESET_ID" \
    --arg ci_name "$CPG_CI_NAME" \
    --argjson ci_app_id "$CPG_CI_APP_ID" \
    --arg connector_login "$CPG_CONNECTOR_LOGIN" '
      .schema_version == 1 and .status == "active" and
      .repository == $repository and .repository_id == $repository_id and
      .default_branch == $branch and .ruleset_id == $ruleset_id and
      .scope == "full-roadmap" and .effects == "inactive-repo-only" and
      .merge_method == "squash" and .publisher == $attested_by and
      .required_ci_name == $ci_name and .required_ci_app_id == $ci_app_id and
      .completion == "implementation-complete" and
      .allowed_live_writes == "same-repository-delivery-only" and
      .real_target_use == "disabled" and
      .real_target_and_production_credentials == "disabled" and
      .delivery_credential == ("current-gh-operator-" + $connector_login) and
      .release_install_activation == "disabled" and
      .operating_transition_required == true and
      .manifest_policy == "required-entry-set-is-immutable; additions-allowed" and
      (.roadmap_blob | test("\\A[0-9a-f]{40}\\z")) and
      (.north_star_blob | test("\\A[0-9a-f]{40}\\z")) and
      (.forbidden_paths | type == "array" and length > 0) and
      (.forbidden_prefixes | type == "array" and
        index(".github/") != null and index("website/") != null) and
      (.required_manifest_entries | type == "array" and length > 0) and
      .frozen_pr_183_state == "OPEN" and
      (.frozen_pr_183_head | test("\\A[0-9a-f]{40}\\z")) and
      (.frozen_pr_183_base | test("\\A[0-9a-f]{40}\\z")) and
      (.frozen_pr_183_labels | sort) == ["needs-human","round-3"] and
      .post_transition_ruleset == {
        target:"default-branch", enforcement:"active",
        pull_request_required:true, required_approving_review_count:0,
        dismiss_stale_reviews_on_push:false, require_last_push_approval:false,
        require_extra_approval_for_unattributed_changes:false,
        strict_required_status_checks_policy:true,
        required_status_check:$ci_name,
        required_status_check_app_id:$ci_app_id,
        deletion_protection:true, non_fast_forward_protection:true,
        bypass_actors:[]
      }
    ' "$mode" >/dev/null 2>&1 || cpg_die 'construction mode is inactive, mismatched, or unsafe'
}

cpg_validate_ruleset() {
  local ruleset="$1"
  jq -e \
    --arg repository "$CPG_REPOSITORY" \
    --argjson ruleset_id "$CPG_RULESET_ID" \
    --arg ci_name "$CPG_CI_NAME" \
    --argjson ci_app_id "$CPG_CI_APP_ID" '
      .id == $ruleset_id and .name == "ystack-main-gate" and
      .target == "branch" and .source_type == "Repository" and
      .source == $repository and .enforcement == "active" and
      .conditions.ref_name == {exclude:[],include:["~DEFAULT_BRANCH"]} and
      .bypass_actors == [] and .current_user_can_bypass == "never" and
      (.rules | length) == 4 and
      ([.rules[].type] | sort) ==
        ["deletion","non_fast_forward","pull_request","required_status_checks"] and
      ([.rules[] | select(.type == "deletion")] | length) == 1 and
      ([.rules[] | select(.type == "non_fast_forward")] | length) == 1 and
      ([.rules[] | select(.type == "pull_request") | .parameters] | .[0]) == {
        required_approving_review_count:0,
        dismiss_stale_reviews_on_push:false,
        required_reviewers:[], require_code_owner_review:false,
        require_last_push_approval:false,
        required_review_thread_resolution:false,
        require_extra_approval_for_unattributed_changes:false,
        allowed_merge_methods:["squash"]
      } and
      ([.rules[] | select(.type == "required_status_checks") | .parameters] | .[0]) == {
        strict_required_status_checks_policy:true,
        do_not_enforce_on_create:false,
        required_status_checks:[{context:$ci_name,integration_id:$ci_app_id}]
      }
    ' "$ruleset" >/dev/null 2>&1 || cpg_die 'ruleset is not the exact strict construction gate'
}

cpg_validate_pr() {
  local pr_json="$1"
  local pr_number="$2"
  local head="$3"
  local base="$4"
  jq -e \
    --argjson number "$pr_number" \
    --arg repository "$CPG_REPOSITORY" \
    --argjson repository_id "$CPG_REPOSITORY_ID" \
    --arg branch "$CPG_DEFAULT_BRANCH" \
    --arg head "$head" \
    --arg base "$base" '
      .number == $number and $number != 183 and
      .state == "open" and .merged == false and .draft == false and
      .base.ref == $branch and .base.sha == $base and
      .head.sha == $head and .head.repo.id == $repository_id and
      .head.repo.full_name == $repository and
      .mergeable == true and .mergeable_state == "clean"
    ' "$pr_json" >/dev/null 2>&1 || cpg_die 'pull request is not the exact open, clean candidate'
}

cpg_validate_review() {
  local comments="$1"
  local selected="$2"
  local operator="$3"
  local comment_id="$4"
  local head="$5"
  local base="$6"
  local body_digest="$7"
  local body_file="$8"

  jq -e 'type == "array" and all(.[]; type == "array")' \
    "$comments" >/dev/null 2>&1 || cpg_die 'review comment list is malformed'
  jq -e --arg operator "$operator" --arg header "$CPG_REVIEW_HEADER" '
    [.[][] |
      select(.user.login == $operator) |
      select((.body | type) == "string") |
      select((.body | split("\n") | index($header)) != null)] |
    sort_by(.created_at, .id) |
    if length > 0 then .[-1] else error("no review") end
  ' "$comments" > "$selected" 2>/dev/null || cpg_die 'no authenticated independent review comment found'

  jq -e \
    --argjson comment_id "$comment_id" \
    --arg operator "$operator" \
    --arg header "$CPG_REVIEW_HEADER" \
    --arg head "$head" \
    --arg base "$base" '
      .id == $comment_id and .user.login == $operator and
      (.body | length) >= 200 and
      (.body | split("\n")) as $lines |
      ([$lines[] | select(. == $header)] | length) == 1 and
      ([$lines[] | select(. == ("Reviewed-head: " + $head))] | length) == 1 and
      ([$lines[] | select(. == ("Reviewed-base: " + $base))] | length) == 1 and
      ([$lines[] | select(test("\\Areviewer: [^\\n]+ @ high\\z"))] | length) == 1 and
      (.body | contains("DEGRADED") | not) and
      (.body | contains("Attempted-head:") | not) and
      (.body | contains("Attempted-base:") | not) and
      (.body | contains("warning: target override tried to set gate effort") | not) and
      (.body | test("(?m)^- \\[P[012]\\]") | not)
    ' "$selected" >/dev/null 2>&1 || cpg_die 'review is stale, malformed, degraded, or contains an Important marker'

  jq -j '.body' "$selected" > "$body_file"
  [ "$(cpg_sha256_file "$body_file")" = "$body_digest" ] ||
    cpg_die 'review body digest mismatch'
}

cpg_validate_changed_paths() {
  local files_json="$1"
  local request_json="$2"
  local mode_json="$3"
  local changed_paths="$4"
  local allowed_paths="$5"
  local path

  jq -e '
    type == "array" and length > 0 and all(.[]; type == "array") and
    ([.[][]] | length) > 0 and
    all(.[][];
      (.filename | type == "string" and length > 0) and
      ((has("previous_filename") | not) or (.previous_filename | type == "string")))
  ' "$files_json" >/dev/null 2>&1 || cpg_die 'changed-file list is missing or malformed'

  jq -S -c '[.[][] | .filename, (.previous_filename? // empty)] | unique | sort' \
    "$files_json" > "$changed_paths"
  jq -S -c '.allowed_paths | unique | sort' "$request_json" > "$allowed_paths"
  cmp -s "$changed_paths" "$allowed_paths" || cpg_die 'changed paths do not exactly match the construction brief'

  while IFS= read -r path; do
    [ "$path" != "$CPG_PROTECTED_GATE" ] &&
      [ "$path" != "$CPG_PROTECTED_TEST" ] ||
      cpg_die 'candidate changes the installed construction publisher gate'
    jq -e --arg path "$path" '
      . as $mode |
      ($mode.forbidden_paths | index($path) | not) and
      all($mode.forbidden_prefixes[];
        . as $prefix | ($path | startswith($prefix) | not))
    ' "$mode_json" >/dev/null 2>&1 || cpg_die 'candidate touches a construction-forbidden path'
  done < <(jq -r '.[]' "$changed_paths")
}

cpg_validate_manifest() {
  local manifest="$1"
  local mode="$2"
  local base_manifest="$3"
  local entry
  awk '
    /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
    seen[$0]++ { exit 1 }
  ' "$manifest" || cpg_die 'candidate restore manifest contains a duplicate active entry'
  while IFS= read -r entry || [ -n "$entry" ]; do
    case "$entry" in ''|'#'*) continue ;; esac
    [ "$(grep -Fxc -- "$entry" "$manifest" || true)" -eq 1 ] ||
      cpg_die 'candidate removed or duplicated an entry from the reviewed-base manifest'
  done < "$base_manifest"
  while IFS= read -r entry; do
    [ "$(grep -Fxc -- "$entry" "$manifest" || true)" -eq 1 ] ||
      cpg_die 'candidate removed or duplicated a required restore-manifest entry'
  done < <(jq -r '.required_manifest_entries[]' "$mode")
  for entry in "$CPG_PROTECTED_GATE" "$CPG_PROTECTED_TEST"; do
    [ "$(grep -Fxc -- "$entry" "$manifest" || true)" -eq 1 ] ||
      cpg_die 'candidate removed or duplicated a construction publisher manifest entry'
  done
}

cpg_validate_frozen_pr() {
  local frozen_pr="$1"
  local mode="$2"
  jq -e --slurpfile mode "$mode" '
    .number == 183 and .state == ($mode[0].frozen_pr_183_state | ascii_downcase) and
    .head.sha == $mode[0].frozen_pr_183_head and
    .base.sha == $mode[0].frozen_pr_183_base and
    ([.labels[].name] | sort) == ($mode[0].frozen_pr_183_labels | sort)
  ' "$frozen_pr" >/dev/null 2>&1 || cpg_die 'frozen PR #183 moved'
}

cpg_validate_ancestry() {
  local compare="$1"
  local base="$2"
  jq -e --arg base "$base" '
    .status == "ahead" and .behind_by == 0 and .ahead_by > 0 and
    .merge_base_commit.sha == $base
  ' "$compare" >/dev/null 2>&1 || cpg_die 'candidate is not a clean descendant of the reviewed base'
}

cpg_validate_ci() {
  local checks="$1"
  local head="$2"
  jq -e \
    --arg name "$CPG_CI_NAME" \
    --arg head "$head" \
    --argjson app_id "$CPG_CI_APP_ID" '
      .total_count == 1 and (.check_runs | length) == 1 and
      .check_runs[0].name == $name and
      .check_runs[0].app.id == $app_id and
      .check_runs[0].head_sha == $head and
      .check_runs[0].status == "completed" and
      .check_runs[0].conclusion == "success" and
      (.check_runs[0].id | type == "number")
    ' "$checks" >/dev/null 2>&1 || cpg_die 'required ci from GitHub Actions app 15368 is not uniquely green on the exact head'
}

cpg_preflight() {
  local request_path="$1"
  local request_json="$CPG_TMP/request.json"
  local request_digest
  local repository
  local repository_id
  local pr_number
  local head
  local base
  local connector_login
  local attested_by
  local review_comment_id
  local review_body_digest
  local operator
  local mode_blob
  local gate_blob
  local test_blob
  local roadmap_blob
  local north_star_blob
  local head_tree
  local check_run_id
  local check_details_url
  local review_created_at
  local review_updated_at
  local ruleset_updated_at

  [ -f "$request_path" ] && [ ! -L "$request_path" ] || cpg_die 'request must be a regular non-symlink file'
  jq -S -c . "$request_path" > "$request_json" 2>/dev/null || cpg_die 'request is not valid JSON'
  cpg_validate_request "$request_json"
  request_digest="$(cpg_sha256_file "$request_json")"

  repository="$(jq -r '.repository' "$request_json")"
  repository_id="$(jq -r '.repository_id' "$request_json")"
  pr_number="$(jq -r '.pull_request' "$request_json")"
  head="$(jq -r '.expected_head' "$request_json")"
  base="$(jq -r '.expected_base' "$request_json")"
  connector_login="$(jq -r '.connector.login' "$request_json")"
  attested_by="$(jq -r '.review.attested_by' "$request_json")"
  review_comment_id="$(jq -r '.review.comment_id' "$request_json")"
  review_body_digest="$(jq -r '.review.body_sha256' "$request_json")"
  cpg_validate_trusted_source "$base"
  gate_blob="$CPG_LOCAL_GATE_BLOB"
  test_blob="$CPG_LOCAL_TEST_BLOB"

  cpg_get user "$CPG_TMP/user.json"
  operator="$(jq -r '.login // empty' "$CPG_TMP/user.json")"
  [ "$operator" = "$connector_login" ] &&
    [ "$(jq -r '.id // empty' "$CPG_TMP/user.json")" = "$CPG_CONNECTOR_ID" ] ||
    cpg_die 'authenticated gh operator does not match the connector identity'

  cpg_get "repos/$repository" "$CPG_TMP/repo.json"
  cpg_validate_repo "$CPG_TMP/repo.json"

  cpg_get "repos/$repository/contents/config/construction-mode.json?ref=$base" "$CPG_TMP/mode-response.json"
  mode_blob="$(jq -r '.sha' "$CPG_TMP/mode-response.json")"
  [ "$mode_blob" = "$CPG_MODE_BLOB" ] || cpg_die 'construction mode blob is not the installed authorization'
  cpg_decode_content "$CPG_TMP/mode-response.json" "$CPG_TMP/mode.json"
  jq -S -c . "$CPG_TMP/mode.json" > "$CPG_TMP/mode-canonical.json" 2>/dev/null ||
    cpg_die 'construction mode is not valid JSON'
  mv "$CPG_TMP/mode-canonical.json" "$CPG_TMP/mode.json"
  cpg_validate_mode "$CPG_TMP/mode.json" "$attested_by"

  cpg_get "repos/$repository/contents/ROADMAP.md?ref=$base" "$CPG_TMP/roadmap.json"
  cpg_get "repos/$repository/contents/NORTH_STAR.md?ref=$base" "$CPG_TMP/north-star.json"
  roadmap_blob="$(jq -r '.sha // empty' "$CPG_TMP/roadmap.json")"
  north_star_blob="$(jq -r '.sha // empty' "$CPG_TMP/north-star.json")"
  [ "$roadmap_blob" = "$CPG_ROADMAP_BLOB" ] || cpg_die 'ROADMAP is not the installed authorization blob'
  [ "$north_star_blob" = "$CPG_NORTH_STAR_BLOB" ] || cpg_die 'north star is not the installed authorization blob'
  [ "$roadmap_blob" = "$(jq -r '.roadmap_blob' "$CPG_TMP/mode.json")" ] ||
    cpg_die 'ROADMAP blob does not match construction mode'
  [ "$north_star_blob" = "$(jq -r '.north_star_blob' "$CPG_TMP/mode.json")" ] ||
    cpg_die 'north-star blob does not match construction mode'

  cpg_get "repos/$repository/contents/$CPG_PROTECTED_GATE?ref=$base" "$CPG_TMP/gate-source.json"
  cpg_get "repos/$repository/contents/$CPG_PROTECTED_TEST?ref=$base" "$CPG_TMP/gate-test.json"
  [ "$(jq -r '.sha // empty' "$CPG_TMP/gate-source.json")" = "$gate_blob" ] ||
    cpg_die 'trusted local publisher gate does not match the base on GitHub'
  [ "$(jq -r '.sha // empty' "$CPG_TMP/gate-test.json")" = "$test_blob" ] ||
    cpg_die 'trusted local publisher test does not match the base on GitHub'

  cpg_get "repos/$repository/rulesets/$CPG_RULESET_ID" "$CPG_TMP/ruleset.json"
  cpg_validate_ruleset "$CPG_TMP/ruleset.json"
  ruleset_updated_at="$(jq -r '.updated_at // empty' "$CPG_TMP/ruleset.json")"

  cpg_get "repos/$repository/pulls/$pr_number" "$CPG_TMP/pr.json"
  cpg_validate_pr "$CPG_TMP/pr.json" "$pr_number" "$head" "$base"

  cpg_get_pages "repos/$repository/issues/$pr_number/comments?per_page=100" "$CPG_TMP/comments.json"
  cpg_validate_review \
    "$CPG_TMP/comments.json" "$CPG_TMP/review.json" "$operator" \
    "$review_comment_id" "$head" "$base" "$review_body_digest" "$CPG_TMP/review-body"
  review_created_at="$(jq -r '.created_at // empty' "$CPG_TMP/review.json")"
  review_updated_at="$(jq -r '.updated_at // empty' "$CPG_TMP/review.json")"

  cpg_get_pages "repos/$repository/pulls/$pr_number/files?per_page=100" "$CPG_TMP/files.json"
  cpg_validate_changed_paths \
    "$CPG_TMP/files.json" "$request_json" "$CPG_TMP/mode.json" \
    "$CPG_TMP/changed-paths.json" "$CPG_TMP/allowed-paths.json"

  cpg_get "repos/$repository/contents/ci/required-files.txt?ref=$base" "$CPG_TMP/base-manifest-response.json"
  cpg_decode_content "$CPG_TMP/base-manifest-response.json" "$CPG_TMP/base-manifest.txt"
  cpg_get "repos/$repository/contents/ci/required-files.txt?ref=$head" "$CPG_TMP/manifest-response.json"
  cpg_decode_content "$CPG_TMP/manifest-response.json" "$CPG_TMP/manifest.txt"
  cpg_validate_manifest "$CPG_TMP/manifest.txt" "$CPG_TMP/mode.json" "$CPG_TMP/base-manifest.txt"

  cpg_get "repos/$repository/compare/$base...$head" "$CPG_TMP/compare.json"
  cpg_validate_ancestry "$CPG_TMP/compare.json" "$base"

  cpg_get "repos/$repository/git/commits/$head" "$CPG_TMP/head-commit.json"
  head_tree="$(jq -r --arg head "$head" 'select(.sha == $head) | .tree.sha // empty' "$CPG_TMP/head-commit.json")"
  [[ "$head_tree" =~ ^[0-9a-f]{40}$ ]] || cpg_die 'head tree identity is missing or malformed'

  cpg_get "repos/$repository/commits/$head/check-runs?check_name=$CPG_CI_NAME&app_id=$CPG_CI_APP_ID&filter=latest&per_page=100" "$CPG_TMP/checks.json"
  cpg_validate_ci "$CPG_TMP/checks.json" "$head"
  check_run_id="$(jq -r '.check_runs[0].id' "$CPG_TMP/checks.json")"
  check_details_url="$(jq -r '.check_runs[0].details_url // empty' "$CPG_TMP/checks.json")"

  cpg_get "repos/$repository/pulls/183" "$CPG_TMP/frozen-pr.json"
  cpg_validate_frozen_pr "$CPG_TMP/frozen-pr.json" "$CPG_TMP/mode.json"

  cpg_get "repos/$repository/rulesets/$CPG_RULESET_ID" "$CPG_TMP/ruleset-late.json"
  cpg_validate_ruleset "$CPG_TMP/ruleset-late.json"
  cmp -s "$CPG_TMP/ruleset.json" "$CPG_TMP/ruleset-late.json" ||
    cpg_die 'ruleset changed during preflight'

  cpg_get_pages "repos/$repository/issues/$pr_number/comments?per_page=100" "$CPG_TMP/comments-late.json"
  cpg_validate_review \
    "$CPG_TMP/comments-late.json" "$CPG_TMP/review-late.json" "$operator" \
    "$review_comment_id" "$head" "$base" "$review_body_digest" "$CPG_TMP/review-body-late"
  cmp -s "$CPG_TMP/review.json" "$CPG_TMP/review-late.json" ||
    cpg_die 'independent review changed during preflight'

  cpg_get "repos/$repository/commits/$head/check-runs?check_name=$CPG_CI_NAME&app_id=$CPG_CI_APP_ID&filter=latest&per_page=100" "$CPG_TMP/checks-late.json"
  cpg_validate_ci "$CPG_TMP/checks-late.json" "$head"
  cmp -s "$CPG_TMP/checks.json" "$CPG_TMP/checks-late.json" ||
    cpg_die 'required CI changed during preflight'

  cpg_get "repos/$repository/pulls/$pr_number" "$CPG_TMP/pr-late.json"
  cpg_validate_pr "$CPG_TMP/pr-late.json" "$pr_number" "$head" "$base"

  # This is deliberately the final GitHub read. The connector call must be the
  # next external operation. GitHub's strict required-check rule closes a base
  # move after this read; expected_head_sha closes a head move.
  cpg_get "repos/$repository/git/ref/heads/$CPG_DEFAULT_BRANCH" "$CPG_TMP/main.json"
  [ "$(jq -r '.object.sha // empty' "$CPG_TMP/main.json")" = "$base" ] ||
    cpg_die 'main moved after review; fresh CI and review are required'

  jq -S -c -n \
    --arg kind 'construction-github-native-publish-request' \
    --arg status 'eligible_for_external_publish' \
    --arg repository "$repository" \
    --argjson repository_id "$repository_id" \
    --argjson pr "$pr_number" \
    --arg head "$head" \
    --arg base "$base" \
    --arg tree "$head_tree" \
    --arg request_sha256 "$request_digest" \
    --arg mode_blob "$mode_blob" \
    --arg gate_blob "$gate_blob" \
    --arg test_blob "$test_blob" \
    --arg roadmap_blob "$roadmap_blob" \
    --arg north_star_blob "$north_star_blob" \
    --argjson ruleset_id "$CPG_RULESET_ID" \
    --arg ruleset_updated_at "$ruleset_updated_at" \
    --arg ci_name "$CPG_CI_NAME" \
    --argjson ci_app_id "$CPG_CI_APP_ID" \
    --argjson check_run_id "$check_run_id" \
    --arg check_details_url "$check_details_url" \
    --argjson review_comment_id "$review_comment_id" \
    --arg review_body_sha256 "$review_body_digest" \
    --arg review_created_at "$review_created_at" \
    --arg review_updated_at "$review_updated_at" \
    --arg attested_by "$attested_by" \
    --arg connector_tool "$CPG_CONNECTOR_TOOL" \
    --arg connector_login "$connector_login" \
    --argjson connector_id "$CPG_CONNECTOR_ID" \
    --arg identity_tool "$CPG_CONNECTOR_IDENTITY_TOOL" \
    --arg identity_attested_by "$attested_by" \
    --slurpfile allowed_paths "$CPG_TMP/allowed-paths.json" '
      {
        schema_version:1, kind:$kind, status:$status,
        repository:$repository, repository_id:$repository_id, pull_request:$pr,
        exact:{head:$head,base:$base,head_tree:$tree,allowed_paths:$allowed_paths[0]},
        authorization:{
          request_sha256:$request_sha256, mode_record_blob:$mode_blob,
          publisher_gate_blob:$gate_blob,publisher_test_blob:$test_blob,
          roadmap_blob:$roadmap_blob, north_star_blob:$north_star_blob,
          ruleset_id:$ruleset_id, ruleset_updated_at:$ruleset_updated_at,
          ci:{name:$ci_name,app_id:$ci_app_id,check_run_id:$check_run_id,
              details_url:$check_details_url},
          review:{comment_id:$review_comment_id,body_sha256:$review_body_sha256,
                  created_at:$review_created_at,updated_at:$review_updated_at,
                  complete_review_read:true,independent_review_run:true,
                  machine_verdict_available:false,
                  semantic_decision:"no_unresolved_important",
                  semantic_decision_source:"current-session-read-complete-review",
                  unresolved_important_findings:0,attested_by:$attested_by}
        },
        connector:{id:$connector_id,login:$connector_login,tool:$connector_tool,
          identity_observed:true,identity_observation_tool:$identity_tool,
          identity_attested_by:$identity_attested_by,
          arguments:{repository_full_name:$repository,pr_number:$pr,
                     expected_head_sha:$head,merge_method:"squash"}},
        base_guard:{last_read:$base,server_strict_required_checks:true,
                    atomic_base_cas:false}
      }
    '
}

cpg_validate_preflight() {
  local preflight="$1"
  jq -e \
    --arg repository "$CPG_REPOSITORY" \
    --argjson repository_id "$CPG_REPOSITORY_ID" \
    --arg tool "$CPG_CONNECTOR_TOOL" \
    --arg login "$CPG_CONNECTOR_LOGIN" \
    --argjson connector_id "$CPG_CONNECTOR_ID" \
    --arg identity_tool "$CPG_CONNECTOR_IDENTITY_TOOL" \
    --arg session_publisher "$CPG_SESSION_PUBLISHER" \
    --arg mode_blob "$CPG_MODE_BLOB" \
    --arg roadmap_blob "$CPG_ROADMAP_BLOB" \
    --arg north_star_blob "$CPG_NORTH_STAR_BLOB" \
    --argjson ruleset_id "$CPG_RULESET_ID" \
    --arg ci_name "$CPG_CI_NAME" \
    --argjson ci_app_id "$CPG_CI_APP_ID" '
      type == "object" and
      keys == ["authorization","base_guard","connector","exact","kind",
               "pull_request","repository","repository_id","schema_version","status"] and
      .schema_version == 1 and
      .kind == "construction-github-native-publish-request" and
      .status == "eligible_for_external_publish" and
      .repository == $repository and .repository_id == $repository_id and
      (.pull_request | type == "number" and . > 0 and . != 183) and
      (.exact | type == "object" and
        keys == ["allowed_paths","base","head","head_tree"]) and
      (.exact.head | test("\\A[0-9a-f]{40}\\z")) and
      (.exact.base | test("\\A[0-9a-f]{40}\\z")) and
      (.exact.head_tree | test("\\A[0-9a-f]{40}\\z")) and
      .exact.head != .exact.base and
      (.exact.allowed_paths | type == "array" and length > 0 and length <= 64) and
      all(.exact.allowed_paths[];
        type == "string" and length > 0 and length <= 240 and
        test("\\A[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\\z") and
        (split("/") | all(. != "." and . != ".." and . != ".git"))) and
      (.exact.allowed_paths | length) == (.exact.allowed_paths | unique | length) and
      (.authorization | type == "object" and
        keys == ["ci","mode_record_blob","north_star_blob","publisher_gate_blob",
                 "publisher_test_blob","request_sha256","review","roadmap_blob",
                 "ruleset_id","ruleset_updated_at"]) and
      .authorization.mode_record_blob == $mode_blob and
      .authorization.roadmap_blob == $roadmap_blob and
      .authorization.north_star_blob == $north_star_blob and
      (.authorization.publisher_gate_blob | test("\\A[0-9a-f]{40}\\z")) and
      (.authorization.publisher_test_blob | test("\\A[0-9a-f]{40}\\z")) and
      (.authorization.request_sha256 | test("\\A[0-9a-f]{64}\\z")) and
      .authorization.ruleset_id == $ruleset_id and
      (.authorization.ruleset_updated_at |
        test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})\\z")) and
      (.authorization.ci | type == "object" and
        keys == ["app_id","check_run_id","details_url","name"]) and
      .authorization.ci.name == $ci_name and
      .authorization.ci.app_id == $ci_app_id and
      (.authorization.ci.check_run_id | type == "number" and . > 0 and floor == .) and
      (.authorization.ci.details_url |
        test("\\Ahttps://github[.]com/yihanzhu/ystack/actions/runs/[0-9]+/job/[0-9]+\\z")) and
      (.authorization.review | type == "object" and
        keys == ["attested_by","body_sha256","comment_id","complete_review_read",
                 "created_at","independent_review_run","machine_verdict_available",
                 "semantic_decision","semantic_decision_source",
                 "unresolved_important_findings","updated_at"]) and
      (.authorization.review.comment_id | type == "number" and . > 0 and floor == .) and
      (.authorization.review.body_sha256 | test("\\A[0-9a-f]{64}\\z")) and
      (.authorization.review.created_at |
        test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})\\z")) and
      (.authorization.review.updated_at |
        test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})\\z")) and
      .authorization.review.complete_review_read == true and
      .authorization.review.independent_review_run == true and
      .authorization.review.machine_verdict_available == false and
      .authorization.review.semantic_decision == "no_unresolved_important" and
      .authorization.review.semantic_decision_source ==
        "current-session-read-complete-review" and
      .authorization.review.unresolved_important_findings == 0 and
      .authorization.review.attested_by == $session_publisher and
      (.connector | type == "object" and
        keys == ["arguments","id","identity_attested_by","identity_observation_tool",
                 "identity_observed","login","tool"]) and
      .connector.id == $connector_id and
      .connector.login == $login and .connector.tool == $tool and
      .connector.identity_observed == true and
      .connector.identity_observation_tool == $identity_tool and
      .connector.identity_attested_by == $session_publisher and
      (.connector.arguments | type == "object" and
        keys == ["expected_head_sha","merge_method","pr_number","repository_full_name"]) and
      .connector.arguments == {
        repository_full_name:$repository,
        pr_number:.pull_request,
        expected_head_sha:.exact.head,
        merge_method:"squash"
      } and
      (.base_guard | type == "object" and
        keys == ["atomic_base_cas","last_read","server_strict_required_checks"]) and
      .base_guard.last_read == .exact.base and
      .base_guard.server_strict_required_checks == true and
      .base_guard.atomic_base_cas == false
    ' "$preflight" >/dev/null 2>&1 || cpg_die 'preflight receipt is invalid'
}

cpg_try_get() {
  local endpoint="$1"
  local output="$2"
  cpg_api "$endpoint" > "$output" 2>/dev/null && jq -e . "$output" >/dev/null 2>&1
}

cpg_try_get_pages() {
  local endpoint="$1"
  local output="$2"
  cpg_api_pages "$endpoint" > "$output" 2>/dev/null && jq -e . "$output" >/dev/null 2>&1
}

cpg_postflight_revalidate() {
  local request="$1"
  local preflight="$2"
  local repository
  local pr_number
  local head
  local base
  local attested_by
  local review_comment_id
  local review_body_digest
  local operator

  cpg_validate_request "$request"
  [ "$(cpg_sha256_file "$request")" = \
    "$(jq -r '.authorization.request_sha256' "$preflight")" ] ||
    cpg_die 'postflight request digest does not match preflight'
  jq -e --slurpfile preflight "$preflight" '
    . as $request | $preflight[0] as $proof |
    $request.repository == $proof.repository and
    $request.repository_id == $proof.repository_id and
    $request.pull_request == $proof.pull_request and
    $request.expected_head == $proof.exact.head and
    $request.expected_base == $proof.exact.base and
    ($request.allowed_paths | sort) == ($proof.exact.allowed_paths | sort) and
    $request.connector.id == $proof.connector.id and
    $request.connector.login == $proof.connector.login and
    $request.connector.tool == $proof.connector.tool and
    $request.connector.identity_observed == $proof.connector.identity_observed and
    $request.connector.identity_observation_tool ==
      $proof.connector.identity_observation_tool and
    $request.connector.identity_attested_by ==
      $proof.connector.identity_attested_by and
    $request.review.comment_id == $proof.authorization.review.comment_id and
    $request.review.body_sha256 == $proof.authorization.review.body_sha256 and
    $request.review.independent_review_run ==
      $proof.authorization.review.independent_review_run and
    $request.review.complete_review_read ==
      $proof.authorization.review.complete_review_read and
    $request.review.machine_verdict_available ==
      $proof.authorization.review.machine_verdict_available and
    $request.review.semantic_decision ==
      $proof.authorization.review.semantic_decision and
    $request.review.semantic_decision_source ==
      $proof.authorization.review.semantic_decision_source and
    $request.review.unresolved_important_findings ==
      $proof.authorization.review.unresolved_important_findings and
    $request.review.attested_by == $proof.authorization.review.attested_by
  ' "$request" >/dev/null 2>&1 || cpg_die 'postflight request tuple does not match preflight'

  repository="$(jq -r '.repository' "$request")"
  pr_number="$(jq -r '.pull_request' "$request")"
  head="$(jq -r '.expected_head' "$request")"
  base="$(jq -r '.expected_base' "$request")"
  attested_by="$(jq -r '.review.attested_by' "$request")"
  review_comment_id="$(jq -r '.review.comment_id' "$request")"
  review_body_digest="$(jq -r '.review.body_sha256' "$request")"

  cpg_get user "$CPG_TMP/post-user.json"
  operator="$(jq -r '.login // empty' "$CPG_TMP/post-user.json")"
  [ "$operator" = "$CPG_CONNECTOR_LOGIN" ] &&
    [ "$(jq -r '.id // empty' "$CPG_TMP/post-user.json")" = "$CPG_CONNECTOR_ID" ] ||
    cpg_die 'postflight operator identity mismatch'
  cpg_get "repos/$repository" "$CPG_TMP/post-repo.json"
  cpg_validate_repo "$CPG_TMP/post-repo.json"

  cpg_get "repos/$repository/contents/config/construction-mode.json?ref=$base" \
    "$CPG_TMP/post-mode-response.json"
  [ "$(jq -r '.sha // empty' "$CPG_TMP/post-mode-response.json")" = \
    "$(jq -r '.authorization.mode_record_blob' "$preflight")" ] ||
    cpg_die 'postflight mode identity mismatch'
  cpg_decode_content "$CPG_TMP/post-mode-response.json" "$CPG_TMP/post-mode.json"
  cpg_validate_mode "$CPG_TMP/post-mode.json" "$attested_by"

  cpg_get "repos/$repository/contents/ROADMAP.md?ref=$base" "$CPG_TMP/post-roadmap.json"
  cpg_get "repos/$repository/contents/NORTH_STAR.md?ref=$base" "$CPG_TMP/post-north-star.json"
  [ "$(jq -r '.sha // empty' "$CPG_TMP/post-roadmap.json")" = \
    "$(jq -r '.authorization.roadmap_blob' "$preflight")" ] ||
    cpg_die 'postflight Roadmap identity mismatch'
  [ "$(jq -r '.sha // empty' "$CPG_TMP/post-north-star.json")" = \
    "$(jq -r '.authorization.north_star_blob' "$preflight")" ] ||
    cpg_die 'postflight north-star identity mismatch'

  cpg_get "repos/$repository/contents/$CPG_PROTECTED_GATE?ref=$base" \
    "$CPG_TMP/post-gate.json"
  cpg_get "repos/$repository/contents/$CPG_PROTECTED_TEST?ref=$base" \
    "$CPG_TMP/post-test.json"
  [ "$(jq -r '.sha // empty' "$CPG_TMP/post-gate.json")" = \
    "$(jq -r '.authorization.publisher_gate_blob' "$preflight")" ] ||
    cpg_die 'postflight publisher gate identity mismatch'
  [ "$(jq -r '.sha // empty' "$CPG_TMP/post-test.json")" = \
    "$(jq -r '.authorization.publisher_test_blob' "$preflight")" ] ||
    cpg_die 'postflight publisher test identity mismatch'

  cpg_get "repos/$repository/rulesets/$CPG_RULESET_ID" "$CPG_TMP/post-ruleset.json"
  cpg_validate_ruleset "$CPG_TMP/post-ruleset.json"
  [ "$(jq -r '.updated_at // empty' "$CPG_TMP/post-ruleset.json")" = \
    "$(jq -r '.authorization.ruleset_updated_at' "$preflight")" ] ||
    cpg_die 'postflight ruleset identity mismatch'

  cpg_get_pages "repos/$repository/issues/$pr_number/comments?per_page=100" \
    "$CPG_TMP/post-comments.json"
  cpg_validate_review \
    "$CPG_TMP/post-comments.json" "$CPG_TMP/post-review.json" "$operator" \
    "$review_comment_id" "$head" "$base" "$review_body_digest" \
    "$CPG_TMP/post-review-body"
  [ "$(jq -r '.created_at // empty' "$CPG_TMP/post-review.json")" = \
    "$(jq -r '.authorization.review.created_at' "$preflight")" ] &&
    [ "$(jq -r '.updated_at // empty' "$CPG_TMP/post-review.json")" = \
    "$(jq -r '.authorization.review.updated_at' "$preflight")" ] ||
    cpg_die 'postflight review identity mismatch'

  cpg_get_pages "repos/$repository/pulls/$pr_number/files?per_page=100" \
    "$CPG_TMP/post-files.json"
  cpg_validate_changed_paths \
    "$CPG_TMP/post-files.json" "$request" "$CPG_TMP/post-mode.json" \
    "$CPG_TMP/post-changed-paths.json" "$CPG_TMP/post-allowed-paths.json"

  cpg_get "repos/$repository/contents/ci/required-files.txt?ref=$base" \
    "$CPG_TMP/post-base-manifest-response.json"
  cpg_decode_content "$CPG_TMP/post-base-manifest-response.json" \
    "$CPG_TMP/post-base-manifest.txt"
  cpg_get "repos/$repository/contents/ci/required-files.txt?ref=$head" \
    "$CPG_TMP/post-manifest-response.json"
  cpg_decode_content "$CPG_TMP/post-manifest-response.json" "$CPG_TMP/post-manifest.txt"
  cpg_validate_manifest "$CPG_TMP/post-manifest.txt" "$CPG_TMP/post-mode.json" \
    "$CPG_TMP/post-base-manifest.txt"

  cpg_get "repos/$repository/compare/$base...$head" "$CPG_TMP/post-compare.json"
  cpg_validate_ancestry "$CPG_TMP/post-compare.json" "$base"

  cpg_get "repos/$repository/pulls/183" "$CPG_TMP/post-frozen-pr.json"
  cpg_validate_frozen_pr "$CPG_TMP/post-frozen-pr.json" "$CPG_TMP/post-mode.json"

  cpg_get "repos/$repository/commits/$head/check-runs?check_name=$CPG_CI_NAME&app_id=$CPG_CI_APP_ID&filter=latest&per_page=100" \
    "$CPG_TMP/post-checks.json"
  cpg_validate_ci "$CPG_TMP/post-checks.json" "$head"
  [ "$(jq -r '.check_runs[0].id' "$CPG_TMP/post-checks.json")" = \
    "$(jq -r '.authorization.ci.check_run_id' "$preflight")" ] &&
    [ "$(jq -r '.check_runs[0].details_url // empty' "$CPG_TMP/post-checks.json")" = \
    "$(jq -r '.authorization.ci.details_url' "$preflight")" ] ||
    cpg_die 'postflight CI evidence mismatch'
}

cpg_emit_reconciliation() {
  local preflight="$1"
  local status="$2"
  local result="$3"
  local reason="$4"
  local observed_merge="$5"
  local observed_main="$6"
  local record="$CPG_TMP/reconciliation.json"
  local digest
  local preflight_digest
  preflight_digest="$(cpg_sha256_file "$preflight")"
  jq -S -c -n \
    --arg status "$status" --arg result "$result" --arg reason "$reason" \
    --arg observed_merge "$observed_merge" --arg observed_main "$observed_main" \
    --arg preflight_sha256 "$preflight_digest" \
    --slurpfile preflight "$preflight" '
      {
        schema_version:1,kind:"construction-merge-reconciliation",
        status:$status,result:$result,reason:$reason,
        repository:$preflight[0].repository,
        repository_id:$preflight[0].repository_id,
        pull_request:$preflight[0].pull_request,
        expected:$preflight[0].exact,
        observed:{
          merge_commit:(if $observed_merge == "" then null else $observed_merge end),
          main:(if $observed_main == "" then null else $observed_main end)
        },
        authorization:{
          preflight_sha256:$preflight_sha256,
          mode_record_blob:$preflight[0].authorization.mode_record_blob,
          publisher_gate_blob:$preflight[0].authorization.publisher_gate_blob,
          publisher_test_blob:$preflight[0].authorization.publisher_test_blob,
          ruleset_id:$preflight[0].authorization.ruleset_id,
          ci:$preflight[0].authorization.ci,
          review:$preflight[0].authorization.review,
          connector:$preflight[0].connector
        },
        retry_allowed:false
      }
    ' > "$record"
  digest="$(cpg_sha256_file "$record")"
  jq -S -c --arg sha256 "$digest" '{receipt:.,receipt_sha256:$sha256}' "$record"
}

cpg_postflight() {
  local request_path="$1"
  local preflight_path="$2"
  local merge_result_path="$3"
  local request="$CPG_TMP/postflight-request.json"
  local preflight="$CPG_TMP/preflight.json"
  local merge_result="$CPG_TMP/merge-result.json"
  local receipt="$CPG_TMP/receipt.json"
  local receipt_digest
  local request_digest
  local repository
  local repository_id
  local pr_number
  local head
  local base
  local head_tree
  local merge_sha=''
  local result_sha=''
  local main_sha=''
  local merged_at
  local merged_by
  local connector_outcome

  [ -f "$request_path" ] && [ ! -L "$request_path" ] || cpg_die 'request must be a regular non-symlink file'
  [ -f "$preflight_path" ] && [ ! -L "$preflight_path" ] || cpg_die 'preflight must be a regular non-symlink file'
  [ -f "$merge_result_path" ] && [ ! -L "$merge_result_path" ] || cpg_die 'merge result must be a regular non-symlink file'
  jq -S -c . "$request_path" > "$request" 2>/dev/null || cpg_die 'postflight request is not valid JSON'
  cpg_validate_request "$request"
  jq -S -c . "$preflight_path" > "$preflight" 2>/dev/null || cpg_die 'preflight is not valid JSON'
  cpg_validate_preflight "$preflight"

  repository="$(jq -r '.repository' "$preflight")"
  repository_id="$(jq -r '.repository_id' "$preflight")"
  pr_number="$(jq -r '.pull_request' "$preflight")"
  head="$(jq -r '.exact.head' "$preflight")"
  base="$(jq -r '.exact.base' "$preflight")"
  head_tree="$(jq -r '.exact.head_tree' "$preflight")"
  request_digest="$(cpg_sha256_file "$preflight")"

  cpg_validate_trusted_source "$base"
  [ "$CPG_LOCAL_GATE_BLOB" = "$(jq -r '.authorization.publisher_gate_blob' "$preflight")" ] &&
    [ "$CPG_LOCAL_TEST_BLOB" = "$(jq -r '.authorization.publisher_test_blob' "$preflight")" ] ||
    cpg_die 'postflight is not running from the preflight-authorized publisher base'

  jq -S -c 'if has("result") then .result else . end' "$merge_result_path" > "$merge_result" 2>/dev/null ||
    cpg_die 'connector merge result is not valid JSON'
  if jq -e '.merged == true and (.sha | type == "string" and test("\\A[0-9a-f]{40}\\z"))' \
      "$merge_result" >/dev/null 2>&1; then
    connector_outcome='confirmed'
    result_sha="$(jq -r '.sha' "$merge_result")"
  elif jq -e 'keys == ["outcome"] and .outcome == "uncertain"' \
      "$merge_result" >/dev/null 2>&1; then
    connector_outcome='uncertain'
  elif jq -e '.merged == false' "$merge_result" >/dev/null 2>&1; then
    connector_outcome='refused'
  else
    cpg_die 'connector result must be confirmed, refused, or the exact uncertain marker'
  fi

  if ! cpg_try_get "repos/$repository/pulls/$pr_number" "$CPG_TMP/pr-post.json"; then
    cpg_emit_reconciliation "$preflight" unknown inconclusive pr_read_failed '' ''
    return 1
  fi
  if ! jq -e --argjson number "$pr_number" --arg head "$head" --arg base "$base" '
      .number == $number and .head.sha == $head and .base.sha == $base
    ' "$CPG_TMP/pr-post.json" >/dev/null 2>&1; then
    cpg_emit_reconciliation "$preflight" unknown inconclusive pr_identity_mismatch '' ''
    return 1
  fi
  if [ "$(jq -r '.merged' "$CPG_TMP/pr-post.json")" != true ]; then
    cpg_emit_reconciliation "$preflight" not_merged not_merged \
      "connector_${connector_outcome}" '' ''
    return 1
  fi

  merge_sha="$(jq -r '.merge_commit_sha // empty' "$CPG_TMP/pr-post.json")"
  merged_at="$(jq -r '.merged_at // empty' "$CPG_TMP/pr-post.json")"
  merged_by="$(jq -r '.merged_by.login // empty' "$CPG_TMP/pr-post.json")"
  if ! [[ "$merge_sha" =~ ^[0-9a-f]{40}$ ]] ||
     [ "$merged_by" != "$CPG_CONNECTOR_LOGIN" ] ||
     ! [[ "$merged_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    cpg_emit_reconciliation "$preflight" merged_unverified inconclusive \
      pr_merge_record_malformed "$merge_sha" ''
    return 1
  fi
  if [ "$connector_outcome" = confirmed ] && [ "$result_sha" != "$merge_sha" ]; then
    cpg_emit_reconciliation "$preflight" merged_unverified inconclusive \
      connector_sha_mismatch "$merge_sha" ''
    return 1
  fi
  if [ "$connector_outcome" = refused ]; then
    cpg_emit_reconciliation "$preflight" merged_unverified inconclusive \
      connector_refused_but_pr_merged "$merge_sha" ''
    return 1
  fi
  case "$connector_outcome" in
    uncertain) connector_outcome='reconciled_after_uncertain' ;;
  esac

  if ! (cpg_postflight_revalidate "$request" "$preflight") >/dev/null 2>&1; then
    cpg_emit_reconciliation "$preflight" merged_unverified inconclusive \
      authorization_revalidation_failed "$merge_sha" ''
    return 1
  fi

  if ! cpg_try_get "repos/$repository/git/commits/$head" "$CPG_TMP/head-post.json" ||
     ! jq -e --arg head "$head" --arg tree "$head_tree" '
       .sha == $head and .tree.sha == $tree
     ' "$CPG_TMP/head-post.json" >/dev/null 2>&1; then
    cpg_emit_reconciliation "$preflight" merged_unverified inconclusive \
      head_tree_mismatch "$merge_sha" ''
    return 1
  fi

  if ! cpg_try_get "repos/$repository/git/commits/$merge_sha" "$CPG_TMP/merge-commit.json" ||
     ! jq -e --arg merge "$merge_sha" --arg base "$base" --arg tree "$head_tree" '
       .sha == $merge and (.parents | length) == 1 and
       .parents[0].sha == $base and .tree.sha == $tree
     ' "$CPG_TMP/merge-commit.json" >/dev/null 2>&1; then
    cpg_emit_reconciliation "$preflight" merged_unverified inconclusive \
      squash_parent_or_tree_mismatch "$merge_sha" ''
    return 1
  fi

  # This is the final GitHub read on the success path.
  if ! cpg_try_get "repos/$repository/git/ref/heads/$CPG_DEFAULT_BRANCH" "$CPG_TMP/main-post.json"; then
    cpg_emit_reconciliation "$preflight" merged_unverified inconclusive \
      main_read_failed "$merge_sha" ''
    return 1
  fi
  main_sha="$(jq -r '.object.sha // empty' "$CPG_TMP/main-post.json")"
  if [ "$main_sha" != "$merge_sha" ]; then
    cpg_emit_reconciliation "$preflight" merged_unverified inconclusive \
      main_mismatch "$merge_sha" "$main_sha"
    return 1
  fi

  jq -S -c -n \
    --arg repository "$repository" --argjson repository_id "$repository_id" \
    --argjson pr "$pr_number" --arg head "$head" --arg base "$base" \
    --arg tree "$head_tree" --arg merge "$merge_sha" --arg main "$main_sha" \
    --arg merged_at "$merged_at" --arg merged_by "$merged_by" \
    --arg connector_outcome "$connector_outcome" \
    --arg preflight_sha256 "$request_digest" --slurpfile authorization "$preflight" '
      {
        schema_version:1,kind:"construction-merge-receipt",status:"completed",result:"merged",
        repository:$repository,repository_id:$repository_id,pull_request:$pr,
        actor:$merged_by,merge_method:"squash",merged_at:$merged_at,
        connector_outcome:$connector_outcome,
        exact:{head:$head,base:$base,head_tree:$tree,merge_commit:$merge,
               parents:[$base],merge_tree:$tree,main:$main},
        authorization:{
          preflight_sha256:$preflight_sha256,
          mode_record_blob:$authorization[0].authorization.mode_record_blob,
          publisher_gate_blob:$authorization[0].authorization.publisher_gate_blob,
          publisher_test_blob:$authorization[0].authorization.publisher_test_blob,
          roadmap_blob:$authorization[0].authorization.roadmap_blob,
          north_star_blob:$authorization[0].authorization.north_star_blob,
          ruleset_id:$authorization[0].authorization.ruleset_id,
          ruleset_updated_at:$authorization[0].authorization.ruleset_updated_at,
          ci:$authorization[0].authorization.ci,
          review:$authorization[0].authorization.review,
          connector:$authorization[0].connector
        }
      }
    ' > "$receipt"
  receipt_digest="$(cpg_sha256_file "$receipt")"
  jq -S -c --arg sha256 "$receipt_digest" '{receipt:.,receipt_sha256:$sha256}' "$receipt"
}

main() {
  cpg_need_tools
  [ "$#" -ge 1 ] || {
    cpg_usage
    exit 1
  }

  CPG_TMP="$(mktemp -d /tmp/ystack-construction-publisher.XXXXXXXX)" ||
    cpg_die 'could not create private temporary directory'
  case "$CPG_TMP" in
    /tmp/ystack-construction-publisher.*) ;;
    *) cpg_die 'unexpected temporary directory path' ;;
  esac
  [ -d "$CPG_TMP" ] && [ ! -L "$CPG_TMP" ] || cpg_die 'temporary directory is unsafe'
  readonly CPG_TMP
  trap 'rm -rf -- "$CPG_TMP"' EXIT

  case "$1" in
    preflight)
      [ "$#" -eq 2 ] || {
        cpg_usage
        exit 1
      }
      cpg_preflight "$2"
      ;;
    postflight)
      [ "$#" -eq 4 ] || {
        cpg_usage
        exit 1
      }
      cpg_postflight "$2" "$3" "$4"
      ;;
    *)
      cpg_usage
      exit 1
      ;;
  esac
}

main "$@"
