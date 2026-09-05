#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha256_path() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

snapshot_file() {
  /usr/bin/perl -MFcntl=:DEFAULT,:mode -e '
    my ($source,$target,$limit,$mode)=@ARGV;
    sysopen(my $in,$source,O_RDONLY|O_NOFOLLOW) or exit 40;
    my @stat=stat($in);
    @stat && S_ISREG($stat[2]) or exit 40;
    $stat[7] <= $limit or exit 42;
    sysopen(my $out,$target,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,oct($mode))
      or exit 40;
    my $total=0;
    while (1) {
      my $read=sysread($in,my $buffer,65536);
      defined($read) or exit 40;
      last if $read == 0;
      $total += $read;
      $total <= $limit or exit 42;
      my $offset=0;
      while ($offset < $read) {
        my $written=syswrite($out,$buffer,$read-$offset,$offset);
        defined($written) && $written > 0 or exit 40;
        $offset += $written;
      }
    }
    close($in) or exit 40;
    close($out) or exit 40;
    chmod(oct($mode),$target) == 1 or exit 40;
  ' "$1" "$2" "$3" "$4"
}

snapshot_expected() {
  local expected=$1 source=$2 target=$3 mode=$4 status=0
  snapshot_file "$source" "$target" 16777216 "$mode" || status=$?
  [ "$status" -eq 0 ] && [ "$(sha256_path "$target")" = "$expected" ]
}

[ "$#" -eq 3 ] && [ "$1" = run ] || emit_error E_USAGE
input=$2
observed_at=$3
[[ "$observed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  emit_error E_USAGE

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) self="$(pwd -P)/$self" ;; esac
[ -f "$self" ] && [ ! -L "$self" ] || emit_error E_RUNTIME
source_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
self="$source_dir/${self##*/}"
[ "$self" = "$source_dir/evals-launcher.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
[ "$source_dir" = "$repo/evals/v1" ] || emit_error E_RUNTIME
[ -f "$input" ] && [ ! -L "$input" ] || emit_error E_RUNTIME

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64)
    host_os=linux; host_arch=x86_64; jq_arch=x86_64; execution_mode=native
    jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    ;;
  Darwin:x86_64)
    host_os=darwin; host_arch=x86_64; jq_arch=x86_64; execution_mode=native
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  Darwin:arm64)
    host_os=darwin; host_arch=arm64; jq_arch=x86_64; execution_mode=rosetta
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  *) emit_error E_RUNTIME ;;
esac

jq_source=''
for candidate in "${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset" "/usr/bin/jq"; do
  if [ -f "$candidate" ] && [ ! -L "$candidate" ] &&
     [ "$(sha256_path "$candidate")" = "$jq_sha" ]; then
    jq_source=$candidate
    break
  fi
done
[ -n "$jq_source" ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evals.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM
runtime="$scratch/runtime"
/bin/mkdir -m 0700 "$runtime" "$runtime/bin" "$runtime/core" "$runtime/core/v2" \
  "$runtime/core/v2/generations" "$runtime/scripts" "$runtime/orchestrator" \
  "$runtime/orchestrator/v1" "$scratch/work" ||
  emit_error E_RUNTIME
generation=g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43
generation_runtime="$runtime/core/v2/generations/$generation"
/bin/mkdir -m 0700 "$generation_runtime" "$generation_runtime/modules" ||
  emit_error E_RUNTIME

program_sha=88e2bf8ae9a3e97d7d043f97f854fa5ef79dae6794a8c762abe35ee8d6641e4f
catalog_sha=bbb210598791b9c80d29bc1edf362c44525fc1c308544a3a2c56d5f8f10a1234
driver_sha=383a134504ef74343c5b40fe86cc22fbb8beed6ce27168747707d0aaa90f304c
snapshot_file "$source_dir/run-evals.sh" "$runtime/bootstrap.sh" 1048576 0400 ||
  emit_error E_RUNTIME
bootstrap_sha=$(sha256_path "$runtime/bootstrap.sh") || emit_error E_RUNTIME
snapshot_file "$self" "$runtime/launcher.sh" 1048576 0400 || emit_error E_RUNTIME
launcher_sha=$(sha256_path "$runtime/launcher.sh") || emit_error E_RUNTIME
snapshot_expected "$driver_sha" "$source_dir/evals-driver.sh" "$runtime/driver.sh" 0400 ||
  emit_error E_STALE
snapshot_expected "$program_sha" "$source_dir/evals.jq" "$runtime/program.jq" 0400 ||
  emit_error E_STALE
snapshot_expected "$catalog_sha" "$source_dir/eval-catalog.json" "$runtime/catalog.json" 0400 ||
  emit_error E_STALE
snapshot_expected 3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94 \
  "$repo/core/v2/generation-registry.json" \
  "$runtime/core/v2/generation-registry.json" 0400 || emit_error E_STALE
snapshot_expected 65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a \
  "$repo/core/v2/generations/$generation/contracts.jq" \
  "$generation_runtime/contracts.jq" 0400 || emit_error E_STALE
snapshot_expected dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8 \
  "$repo/core/v2/generations/$generation/core-ingress.sh" \
  "$generation_runtime/core-ingress.sh" 0400 || emit_error E_STALE
for member in \
  'profile_graph.jq c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207' \
  'result_facts.jq 8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281' \
  'result_truth.jq ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46' \
  'schema.jq 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade' \
  'stage_request.jq 6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" \
    "$repo/core/v2/generations/$generation/modules/$name" \
    "$generation_runtime/modules/$name" 0400 || emit_error E_STALE
done
snapshot_expected b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
  "$repo/scripts/core-contract.sh" "$runtime/scripts/core-contract.sh" 0400 ||
  emit_error E_STALE
# The inactive state scanner, replayed for the events family from inside the
# private runtime. It reads its core from this runtime's mirror, never the repo.
for member in \
  'scan-state.sh 556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5' \
  'state-scanner-driver.sh 5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b' \
  'state-scanner-launcher.sh 9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb' \
  'state-scanner.jq 722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae'; do
  read -r name digest <<<"$member"
  snapshot_expected "$digest" "$repo/orchestrator/v1/$name" \
    "$runtime/orchestrator/v1/$name" 0400 || emit_error E_STALE
done
snapshot_expected "$jq_sha" "$jq_source" "$runtime/bin/jq" 0500 || emit_error E_RUNTIME
bash_sha=$(sha256_path /bin/bash) || emit_error E_RUNTIME
snapshot_file "$input" "$scratch/input.json" 1048576 0400 || {
  status=$?
  [ "$status" -eq 42 ] && emit_error E_LIMIT
  emit_error E_RUNTIME
}
seed_sha=$(sha256_path "$scratch/input.json") || emit_error E_RUNTIME

"$runtime/bin/jq" -S -c -n \
  --arg bootstrap_sha "$bootstrap_sha" --arg launcher_sha "$launcher_sha" \
  --arg driver_sha "$driver_sha" --arg program_sha "$program_sha" \
  --arg catalog_sha "$catalog_sha" \
  --arg jq_sha "$jq_sha" --arg bash_sha "$bash_sha" \
  --arg host_os "$host_os" --arg host_arch "$host_arch" \
  --arg jq_arch "$jq_arch" --arg execution_mode "$execution_mode" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  {
    schema_version:1,kind:"eval_framework_evaluator",id:"evals.framework.v1",
    body:{
      core_contract:{
        generation_id_sha256:"84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
        package_ref:ref("core-contract-package.v2";
          "application/vnd.ystack.core-contract+json";
          "eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"),
        semantic_identity:"core.contracts.v2"
      },
      core_closure:[
        {path:"core/v2/generation-registry.json",sha256:"3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/contracts.jq",sha256:"65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/core-ingress.sh",sha256:"dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/profile_graph.jq",sha256:"c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_facts.jq",sha256:"8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_truth.jq",sha256:"ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/schema.jq",sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"},
        {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/stage_request.jq",sha256:"6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e"},
        {path:"scripts/core-contract.sh",sha256:"b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9"}
      ],
      orchestrator_closure:[
        {path:"orchestrator/v1/scan-state.sh",sha256:"556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5"},
        {path:"orchestrator/v1/state-scanner-driver.sh",sha256:"5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b"},
        {path:"orchestrator/v1/state-scanner-launcher.sh",sha256:"9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb"},
        {path:"orchestrator/v1/state-scanner.jq",sha256:"722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae"}
      ],
      bootstrap_ref:ref("evals-framework-bootstrap.v1";"text/x-shellscript";$bootstrap_sha),
      launcher_ref:ref("evals-framework-launcher.v1";"text/x-shellscript";$launcher_sha),
      driver_ref:ref("evals-framework-driver.v1";"text/x-shellscript";$driver_sha),
      program_ref:ref("evals-framework-program.v1";"text/x-jq";$program_sha),
      catalog_ref:ref("evals-catalog.v1";"application/vnd.ystack.eval-catalog+json";$catalog_sha),
      runtime:{
        host_os:$host_os,host_architecture:$host_arch,jq_architecture:$jq_arch,
        execution_mode:$execution_mode,
        jq_ref:ref("jq-runtime.v1";"application/x-executable";$jq_sha),
        shell_ref:ref("bash-runtime";"application/x-executable";$bash_sha)
      }
    }
  }
' > "$runtime/evaluator.json" 2>/dev/null || emit_error E_RUNTIME
evaluator_sha=$(sha256_path "$runtime/evaluator.json") || emit_error E_RUNTIME

output="$scratch/output.json"
error="$scratch/error"
/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin TMPDIR="$scratch/work" \
  /bin/bash "$runtime/driver.sh" run "$runtime" "$scratch/input.json" \
  "$runtime/evaluator.json" "$evaluator_sha" "$seed_sha" "$observed_at" \
  </dev/null >"$output" 2>"$error"
status=$?
if [ "$status" -ne 0 ]; then
  [ ! -s "$output" ] || emit_error E_RUNTIME
  driver_error=$(/bin/cat "$error" 2>/dev/null) || emit_error E_RUNTIME
  case "$driver_error" in
    E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE)
      emit_error "$driver_error"
      ;;
    *) emit_error E_RUNTIME ;;
  esac
fi
[ ! -s "$error" ] || emit_error E_RUNTIME

# Independent re-validation of the delivered document against the exact same
# private program and core, after the driver has exited.
[ "$("$runtime/bin/jq" -S -c -n -L "$generation_runtime/modules" \
    --arg evals_operation validate-run-result \
    --arg program_sha256 "$program_sha" --arg driver_sha256 "$driver_sha" \
    --arg catalog_sha256 "$catalog_sha" --arg evaluator_sha256 "$evaluator_sha" \
    --arg seed_set_sha256 "$seed_sha" \
    --arg tool_sha256 b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
    --arg scanner_sha256 556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5 \
    --arg observed_at "$observed_at" \
    --slurpfile catalog_docs "$runtime/catalog.json" \
    --slurpfile seed_set_docs "$scratch/input.json" \
    --slurpfile observation_docs "$scratch/work/observations.json" \
    --slurpfile evaluator_docs "$runtime/evaluator.json" \
    --slurpfile candidate_docs "$output" \
    -f "$runtime/program.jq" 2>/dev/null)" = true ] || emit_error E_RUNTIME
[ "$("$runtime/bin/jq" -S -c . "$output")" = "$(/bin/cat "$output")" ] ||
  emit_error E_CANONICAL
[ "$(sha256_path "$runtime/bootstrap.sh")" = "$bootstrap_sha" ] &&
[ "$(sha256_path "$runtime/launcher.sh")" = "$launcher_sha" ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/scan-state.sh")" = \
    556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5 ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/state-scanner-driver.sh")" = \
    5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/state-scanner-launcher.sh")" = \
    9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb ] &&
[ "$(sha256_path "$runtime/orchestrator/v1/state-scanner.jq")" = \
    722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae ] &&
[ "$(sha256_path "$runtime/driver.sh")" = "$driver_sha" ] &&
[ "$(sha256_path "$runtime/program.jq")" = "$program_sha" ] &&
[ "$(sha256_path "$runtime/catalog.json")" = "$catalog_sha" ] &&
[ "$(sha256_path "$runtime/bin/jq")" = "$jq_sha" ] &&
[ "$(sha256_path /bin/bash)" = "$bash_sha" ] &&
[ "$(sha256_path "$scratch/input.json")" = "$seed_sha" ] &&
[ "$(sha256_path "$runtime/evaluator.json")" = "$evaluator_sha" ] ||
  emit_error E_RUNTIME
/bin/cat "$output" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
