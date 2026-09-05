#!/usr/bin/env python3
"""Run one inactive, offline delivery replay without executing candidate code."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time


LOADED_DRIVER_BYTES = globals().get("_REPLAY_DRIVER_BYTES")
if LOADED_DRIVER_BYTES is None and __name__ == "__main__":
    try:
        driver_descriptor = os.open(__file__, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(driver_descriptor, "rb") as driver_handle:
            driver_source = driver_handle.read(8 * 1024 * 1024 + 1)
        if len(driver_source) > 8 * 1024 * 1024:
            raise OSError("replay driver exceeds its size limit")
        driver_code = compile(driver_source, __file__, "exec")
    except (OSError, SyntaxError, TypeError, ValueError) as error:
        print(f"delivery replay: loaded replay driver identity is unavailable: {error}", file=sys.stderr)
        raise SystemExit(1) from error
    globals()["_REPLAY_DRIVER_BYTES"] = driver_source
    exec(driver_code, globals())
    raise SystemExit(1)

MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_OBSERVATION_BYTES = 64 * 1024
MAX_VERIFIED_BLOB_BYTES = 1024 * 1024
OID = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}\Z")
ACTOR = re.compile(r"[a-z0-9][a-z0-9._:-]{0,127}\Z")
GIT_ENVIRONMENT = {
    "PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_NO_REPLACE_OBJECTS": "1",
    "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0",
}
NATIVE_EXECUTABLE_MAGICS = (
    b"\x7fELF", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
)
PACKAGE_FILES = (
    "adapters/local-git-materializer/v1/materialize.sh",
    "adapters/local-git-materializer/v1/protocol.jq",
    "scripts/core-contract.sh",
    "core/v2/generation-registry.json",
)
GENERATION_FILES = (
    "core-ingress.sh",
    "contracts.jq",
    "modules/schema.jq",
    "modules/profile_graph.jq",
    "modules/stage_request.jq",
    "modules/result_facts.jq",
    "modules/result_truth.jq",
)


class ReplayError(Exception):
    pass


def digest_bytes(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def read_bytes(path, limit):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        chunks = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(descriptor, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
    finally:
        os.close(descriptor)
    if len(data) > limit:
        raise ReplayError("input exceeds its size limit")
    return data


def parse_json(data):
    try:
        return json.loads(data)
    except (ValueError, UnicodeDecodeError) as error:
        raise ReplayError("input is not JSON") from error


def private_directory(path):
    value = Path(path)
    stat = value.stat()
    if value.is_symlink() or not value.is_dir() or stat.st_uid != os.getuid():
        raise ReplayError("state directory is not a caller-owned directory")
    if stat.st_mode & 0o077:
        raise ReplayError("state directory is not private")
    return value.resolve()


def trusted_file(path):
    value = Path(path)
    stat = value.stat()
    if value.is_symlink() or not value.is_file() or stat.st_size > MAX_INPUT_BYTES:
        raise ReplayError("trusted tool is unavailable")
    return value.resolve()


def disjoint(*paths):
    resolved = [Path(path).resolve() for path in paths]
    for index, left in enumerate(resolved):
        for right in resolved[index + 1:]:
            if left == right or left in right.parents or right in left.parents:
                raise ReplayError("caller-owned boundaries overlap")


def atomic_json(path, value):
    atomic_bytes(path, canonical(value) + b"\n")


def atomic_bytes(path, encoded):
    descriptor, temporary = tempfile.mkstemp(prefix=".replay-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def safe_path(value):
    if not isinstance(value, str) or not value or len(value) > 4096:
        raise ReplayError("verification path is invalid")
    parts = value.split("/")
    if any(part in {"", ".", "..", ".git"} or part.endswith((".", " ")) for part in parts):
        raise ReplayError("verification path is invalid")
    if any("\\" in part or any(ord(char) < 32 for char in part) for part in parts):
        raise ReplayError("verification path is invalid")
    return value


def package_paths(generation):
    root = f"core/v2/generations/{generation}"
    return PACKAGE_FILES + tuple(f"{root}/{name}" for name in GENERATION_FILES)


def execution_source_bytes(repository, arguments):
    core_relative = "scripts/core-contract.sh"
    core = read_bytes(trusted_file(repository / core_relative), MAX_INPUT_BYTES)
    match = re.search(
        rb"^PORTABLE_CORE_GENERATION='(g-[0-9a-f]{64})'$", core, re.MULTILINE
    )
    if match is None:
        raise ReplayError("materializer package generation is unavailable")
    generation = match.group(1).decode()
    package = {
        relative: core if relative == core_relative else
        read_bytes(trusted_file(repository / relative), MAX_INPUT_BYTES)
        for relative in package_paths(generation)
    }
    dependencies = {
        ".dependencies/object-closure": read_bytes(
            trusted_file(arguments.closure_helper), MAX_INPUT_BYTES
        ),
        ".dependencies/jq": read_bytes(trusted_file(arguments.jq_bin), MAX_INPUT_BYTES),
    }
    if any(not data.startswith(NATIVE_EXECUTABLE_MAGICS) for data in dependencies.values()):
        raise ReplayError("dependency is not a native executable")
    return package | dependencies


def owned_staging_token(owner_path):
    if not owner_path.exists() or owner_path.is_symlink() or not owner_path.is_file():
        return None
    value = read_bytes(owner_path, 128)
    match = re.fullmatch(rb"ystack-delivery-execution-v1:([0-9a-f]{64})\n", value)
    return match.group(1) if match is not None else None


def create_execution_snapshot(repository, arguments, state_dir):
    root = state_dir / "execution"
    staging = state_dir / ".execution-building"
    owner_path = state_dir / ".execution-building.owner"
    if root.is_symlink() or root.exists():
        if root.is_symlink() or not root.is_dir():
            raise ReplayError("execution bundle is unavailable")
        # An existing bundle is judged by execution_sources_match, so changed or
        # invalid dependencies read as a mismatch there, not as a build failure here.
        return root
    source_bytes = execution_source_bytes(repository, arguments)
    token = owned_staging_token(owner_path)
    if staging.is_symlink() or staging.exists():
        if staging.is_symlink() or not staging.is_dir() or token is None:
            raise ReplayError("execution bundle staging is not program-owned")
        marker = staging / ".owner"
        entries = list(staging.iterdir())
        if entries and (
            marker not in entries or marker.is_symlink() or not marker.is_file() or
            read_bytes(marker, 128) != token + b"\n"
        ):
            raise ReplayError("execution bundle staging is not program-owned")
        shutil.rmtree(staging)
    if token is None:
        if owner_path.exists():
            raise ReplayError("execution bundle staging owner is invalid")
        token = os.urandom(32).hex().encode()
        descriptor = os.open(owner_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                             getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(descriptor, "wb") as owner:
            owner.write(b"ystack-delivery-execution-v1:" + token + b"\n")
            owner.flush()
            os.fsync(owner.fileno())
    os.mkdir(staging, 0o700)
    atomic_bytes(staging / ".owner", token + b"\n")
    os.chmod(staging / ".owner", 0o400)
    for relative, data in source_bytes.items():
        destination = staging / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        atomic_bytes(destination, data)
        mode = 0o500 if relative.endswith(".sh") or relative.startswith(".dependencies/") else 0o400
        os.chmod(destination, mode)
    os.replace(staging, root)
    directory = os.open(state_dir, os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
    os.unlink(owner_path)
    return root


def execution_sources_match(repository, arguments, execution):
    try:
        return all(
            digest_bytes(data) == digest_bytes(read_bytes(trusted_file(execution / relative), MAX_INPUT_BYTES))
            for relative, data in execution_source_bytes(repository, arguments).items()
        )
    except (OSError, ReplayError):
        return False


def driver_identity():
    if not isinstance(LOADED_DRIVER_BYTES, bytes) or len(LOADED_DRIVER_BYTES) > MAX_INPUT_BYTES:
        raise ReplayError("loaded replay driver identity is unavailable")
    return digest_bytes(LOADED_DRIVER_BYTES)


def materializer_package_identity(repository):
    core_path = trusted_file(repository / "scripts/core-contract.sh")
    core_bytes = core_path.read_bytes()
    match = re.search(
        rb"^PORTABLE_CORE_GENERATION='(g-[0-9a-f]{64})'$", core_bytes, re.MULTILINE
    )
    if match is None:
        raise ReplayError("materializer package generation is unavailable")
    generation = match.group(1).decode()
    files = {
        relative: digest_bytes(trusted_file(repository / relative).read_bytes())
        for relative in package_paths(generation)
    }
    package = {"generation_id": generation, "files": files}
    package["sha256"] = digest_bytes(canonical(package))
    return package


def input_identity(input_value, input_sha, arguments, execution):
    try:
        request = input_value["stage_request"]
        request_sha = request["sha256"]
        body = request["content"]["body"]
        source = body["target_revision"]["value"]
        source_tree_id = next(
            item["value"]["value"]["value"]["object_id"]
            for item in body["inputs"]
            if item["input_id"] == body["operation"]["arguments"]["source_tree_input_id"]
        )
    except (KeyError, StopIteration, TypeError) as error:
        raise ReplayError("materialization input lacks an exact source identity") from error
    if not isinstance(request_sha, str) or not re.fullmatch(r"[0-9a-f]{64}", request_sha):
        raise ReplayError("materialization input request identity is invalid")
    if not isinstance(source_tree_id, str) or not OID.fullmatch(source_tree_id):
        raise ReplayError("materialization input tree identity is invalid")
    if not isinstance(source, dict) or not isinstance(source.get("commit_id"), str) or \
       not OID.fullmatch(source["commit_id"]):
        raise ReplayError("materialization input commit identity is invalid")
    if not isinstance(source.get("hash_algorithm"), str) or \
       source["hash_algorithm"] not in {"sha1", "sha256"}:
        raise ReplayError("materialization input hash algorithm is invalid")
    expected = arguments.expected_sha256
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ReplayError("expected verifier digest is invalid")
    package = materializer_package_identity(execution)
    identity = {
        "input_sha256": input_sha,
        "request_sha256": request_sha,
        "source_commit_id": source["commit_id"],
        "source_tree_id": source_tree_id,
        "source_hash_algorithm": source.get("hash_algorithm"),
        "verifier": {
            "id": "delivery.fixed-content-sha256.v1",
            "path": safe_path(arguments.verify_path),
            "expected_sha256": expected,
        },
        "driver_sha256": driver_identity(),
        "materializer_sha256": package["files"][PACKAGE_FILES[0]],
        "materializer_package": package,
        "closure_helper_sha256": digest_bytes(read_bytes(
            trusted_file(execution / ".dependencies/object-closure"), MAX_INPUT_BYTES
        )),
        "jq_sha256": digest_bytes(read_bytes(
            trusted_file(execution / ".dependencies/jq"), MAX_INPUT_BYTES
        )),
        "source_repository_id": arguments.source_repository_id,
    }
    identity["run_key"] = digest_bytes(canonical(identity))
    return identity


def run_materializer(arguments, execution, input_path, identity, candidate_root=None, scratch_root=None):
    candidate_root = Path(arguments.candidate_root).resolve() if candidate_root is None else candidate_root
    scratch_root = Path(arguments.scratch_root).resolve() if scratch_root is None else scratch_root
    command = [
        str(execution / PACKAGE_FILES[0]), "materialize", str(input_path),
        arguments.source_repository_id, str(Path(arguments.source_git_dir).resolve()),
        str(candidate_root), str(scratch_root),
        str(execution / ".dependencies/object-closure"), str(execution / ".dependencies/jq"),
    ]
    environment = {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}
    result = subprocess.run(command, env=environment, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    if result.returncode != 0 or len(result.stdout) > MAX_INPUT_BYTES:
        raise ReplayError("materialization did not complete")
    try:
        response = json.loads(result.stdout)
        receipt_text = response["payloads"][0]["data"]
        receipt = json.loads(receipt_text)
        candidate = receipt["candidate"]
        receipt_sha = response["payloads"][0]["sha256"]
        if (
            receipt_sha != digest_bytes(receipt_text.encode()) or
            receipt["request_ref"]["sha256"] != identity["request_sha256"] or
            response["stage_result"]["body"]["request_ref"]["sha256"] != identity["request_sha256"] or
            receipt["source"] != {
                "repository_id": identity["source_repository_id"],
                "hash_algorithm": identity["source_hash_algorithm"],
                "commit_id": identity["source_commit_id"],
                "tree_id": identity["source_tree_id"],
            }
        ):
            raise ReplayError("materializer response does not match the input snapshot")
        return {
            "response_sha256": digest_bytes(result.stdout),
            "receipt_sha256": receipt_sha,
            "candidate_commit_id": candidate["commit_id"],
            "candidate_tree_id": candidate["tree_id"],
            "candidate_parent_commit_id": candidate["parent_commit_id"],
        }
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as error:
        raise ReplayError("materializer response is malformed") from error


def candidate_identity(candidate_root, source_commit):
    repository = Path(candidate_root).resolve() / "repository.git"
    if not repository.is_dir() or repository.is_symlink():
        return None
    values = []
    for revision in ("refs/heads/candidate", "refs/heads/candidate^{tree}"):
        result = subprocess.run(["/usr/bin/git", f"--git-dir={repository}", "rev-parse", revision],
                                env=GIT_ENVIRONMENT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        value = result.stdout.decode().strip()
        if result.returncode != 0 or not OID.fullmatch(value):
            return None
        values.append(value)
    if values[0] == source_commit:
        return {"candidate_commit_id": values[0], "candidate_tree_id": values[1],
                "candidate_parent_commit_id": source_commit}
    result = subprocess.run(["/usr/bin/git", f"--git-dir={repository}", "rev-parse", "refs/heads/candidate^"],
                            env=GIT_ENVIRONMENT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    parent = result.stdout.decode().strip()
    if result.returncode != 0 or not OID.fullmatch(parent):
        return None
    return {"candidate_commit_id": values[0], "candidate_tree_id": values[1],
            "candidate_parent_commit_id": parent}


@contextmanager
def hold_candidate_ref(candidate_root, expected_commit):
    repository = Path(candidate_root).resolve() / "repository.git"
    lock_path = repository / "refs/heads/candidate.lock"
    command = ["/usr/bin/git", f"--git-dir={repository}", "-c", "core.hooksPath=/dev/null",
               "update-ref", "--stdin"]
    process = subprocess.Popen(command, env=GIT_ENVIRONMENT, stdin=subprocess.PIPE,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        process.stdin.write(
            f"option no-deref\nstart\nverify refs/heads/candidate {expected_commit}\nprepare\n".encode()
        )
        process.stdin.flush()
        for _ in range(1000):
            if lock_path.is_file() and not lock_path.is_symlink():
                break
            if process.poll() is not None:
                raise ReplayError("candidate repository identity guard failed")
            time.sleep(0.001)
        else:
            raise ReplayError("candidate repository identity guard timed out")
        symbolic = subprocess.run(
            ["/usr/bin/git", f"--git-dir={repository}", "symbolic-ref", "-q", "refs/heads/candidate"],
            env=GIT_ENVIRONMENT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False
        )
        if symbolic.returncode != 1:
            raise ReplayError("candidate repository identity guard failed")
        yield
    finally:
        if process.poll() is None:
            try:
                process.stdin.write(b"abort\n")
                process.stdin.flush()
            except (BrokenPipeError, OSError):
                pass
        if process.stdin is not None:
            process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)


def reconcile_materialization(arguments, execution, input_path, identity, state_dir):
    existing = candidate_identity(arguments.candidate_root, identity["source_commit_id"])
    if existing is None:
        return None
    recovery_candidate = Path(tempfile.mkdtemp(prefix="reconcile-candidate-", dir=state_dir))
    recovery_scratch = Path(tempfile.mkdtemp(prefix="reconcile-scratch-", dir=state_dir))
    try:
        recomputed = run_materializer(arguments, execution, input_path, identity,
                                      recovery_candidate, recovery_scratch)
    finally:
        shutil.rmtree(recovery_candidate, ignore_errors=True)
        shutil.rmtree(recovery_scratch, ignore_errors=True)
    if existing != {
        "candidate_commit_id": recomputed["candidate_commit_id"],
        "candidate_tree_id": recomputed["candidate_tree_id"],
        "candidate_parent_commit_id": recomputed["candidate_parent_commit_id"],
    }:
        raise ReplayError("existing candidate does not match frozen materialization input")
    return recomputed


def verify_candidate(candidate_root, candidate_tree, path, expected):
    repository = Path(candidate_root).resolve() / "repository.git"
    if not repository.is_dir() or repository.is_symlink() or not OID.fullmatch(candidate_tree):
        raise ReplayError("candidate repository identity is unavailable")
    object_name = f"{candidate_tree}:{path}"
    size = subprocess.run(["/usr/bin/git", f"--git-dir={repository}", "cat-file", "-s", object_name],
                          env=GIT_ENVIRONMENT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    if size.returncode != 0 or not size.stdout.strip().isdigit() or int(size.stdout) > MAX_VERIFIED_BLOB_BYTES:
        raise ReplayError("fixed verifier cannot read the candidate blob")
    blob = subprocess.run(["/usr/bin/git", f"--git-dir={repository}", "cat-file", "blob", object_name],
                          env=GIT_ENVIRONMENT, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    if blob.returncode != 0 or len(blob.stdout) != int(size.stdout):
        raise ReplayError("fixed verifier could not read the candidate blob")
    actual = digest_bytes(blob.stdout)
    if actual != expected:
        raise ReplayError("fixed verifier digest mismatch")
    return actual


def revalidate_candidate(arguments, state):
    expected = {
        name: state["materialization"][name]
        for name in ("candidate_commit_id", "candidate_tree_id", "candidate_parent_commit_id")
    }
    if candidate_identity(arguments.candidate_root, state["identity"]["source_commit_id"]) != expected:
        raise ReplayError("candidate repository no longer matches saved materialization")
    verify_candidate(arguments.candidate_root, expected["candidate_tree_id"],
                     state["identity"]["verifier"]["path"],
                     state["identity"]["verifier"]["expected_sha256"])


def observation(path, kind, identity, field):
    if path is None:
        return None
    source = read_bytes(path, MAX_OBSERVATION_BYTES)
    value = parse_json(source)
    source_sha = digest_bytes(source)
    if not isinstance(value, dict) or value.get("schema_version") != 1 or value.get("kind") != kind:
        raise ReplayError("offline observation is malformed")
    if not isinstance(value.get("actor_id"), str) or not ACTOR.fullmatch(value["actor_id"]):
        raise ReplayError("offline observation actor is invalid")
    if value.get("request_sha256") != identity["request_sha256"] or value.get("candidate_tree_id") != identity["candidate_tree_id"]:
        raise ReplayError("offline observation does not match this candidate")
    return {"actor_id": value["actor_id"], field: value.get(field), "sha256": source_sha}


def validate_state(state, identity):
    if not isinstance(state, dict) or state.get("schema_version") != 1 or \
       state.get("kind") != "delivery_replay_state" or state.get("authority") != "none" or \
       state.get("qualification") != "unavailable":
        raise ReplayError("state journal is malformed")
    saved = state.get("identity")
    if not isinstance(saved, dict) or any(
        not isinstance(saved.get(name), str) or not re.fullmatch(r"[0-9a-f]{64}", saved[name])
        for name in ("input_sha256", "request_sha256", "driver_sha256", "materializer_sha256",
                     "closure_helper_sha256", "jq_sha256", "run_key")
    ) or not isinstance(saved.get("source_repository_id"), str) or \
       saved.get("source_hash_algorithm") not in {"sha1", "sha256"} or \
       any(not isinstance(saved.get(name), str) or not OID.fullmatch(saved[name])
           for name in ("source_commit_id", "source_tree_id")) or \
       not isinstance(saved.get("verifier"), dict) or \
       not isinstance(saved["verifier"].get("id"), str) or \
       not isinstance(saved["verifier"].get("path"), str) or \
       not re.fullmatch(r"[0-9a-f]{64}", str(saved["verifier"].get("expected_sha256", ""))):
        raise ReplayError("state journal identity is malformed")
    package = saved.get("materializer_package")
    if not isinstance(package, dict) or not isinstance(package.get("generation_id"), str) or \
       not re.fullmatch(r"g-[0-9a-f]{64}", package["generation_id"]) or \
       not isinstance(package.get("files"), dict) or \
       set(package["files"]) != set(package_paths(package["generation_id"])) or any(
           not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
           for value in package["files"].values()
       ) or not isinstance(package.get("sha256"), str) or \
       package["sha256"] != digest_bytes(canonical({
           "generation_id": package["generation_id"], "files": package["files"]
       })) or saved["materializer_sha256"] != package["files"][PACKAGE_FILES[0]]:
        raise ReplayError("state journal materializer package is malformed")
    phase = state.get("phase")
    if phase not in {"materializing", "verifying", "review-wait", "publish-wait", "completed-offline", "failed"}:
        raise ReplayError("state journal phase is malformed")
    needs_materialization = phase in {"verifying", "review-wait", "publish-wait", "completed-offline"}
    for name in ("candidate_commit_id", "candidate_tree_id"):
        if (needs_materialization and name not in saved) or (
            name in saved and (not isinstance(saved[name], str) or not OID.fullmatch(saved[name]))
        ):
            raise ReplayError("state journal candidate identity is malformed")
    materialization = state.get("materialization")
    if needs_materialization and (not isinstance(materialization, dict) or any(
        not isinstance(materialization.get(name), str) or not OID.fullmatch(materialization[name])
        for name in ("candidate_commit_id", "candidate_tree_id", "candidate_parent_commit_id")
    ) or any(
        not isinstance(materialization.get(name), str) or not re.fullmatch(r"[0-9a-f]{64}", materialization[name])
        for name in ("response_sha256", "receipt_sha256")
    )):
        raise ReplayError("state journal materialization is malformed")
    if needs_materialization and any(
        saved[name] != materialization[name]
        for name in ("candidate_commit_id", "candidate_tree_id")
    ):
        raise ReplayError("state journal candidate identity does not match materialization")
    if phase in {"review-wait", "publish-wait", "completed-offline"}:
        verification = state.get("verification")
        if verification != {
            "id": saved["verifier"]["id"],
            "path": saved["verifier"]["path"],
            "sha256": saved["verifier"]["expected_sha256"],
        }:
            raise ReplayError("state journal verification is malformed")
    if phase in {"publish-wait", "completed-offline"}:
        review = state.get("review")
        if not isinstance(review, dict) or not isinstance(review.get("actor_id"), str) or \
           not ACTOR.fullmatch(review["actor_id"]) or \
           review.get("verdict") != "clean" or not re.fullmatch(r"[0-9a-f]{64}", str(review.get("sha256", ""))):
            raise ReplayError("state journal review is malformed")
    if phase == "completed-offline":
        publisher = state.get("publisher")
        if not isinstance(publisher, dict) or not isinstance(publisher.get("actor_id"), str) or \
           not ACTOR.fullmatch(publisher["actor_id"]) or \
           publisher.get("disposition") != "offline-simulated" or \
           not re.fullmatch(r"[0-9a-f]{64}", str(publisher.get("sha256", ""))):
            raise ReplayError("state journal publisher is malformed")
    if phase == "failed" and not isinstance(state.get("reason"), str):
        raise ReplayError("state journal failure is malformed")


def result(state):
    print(json.dumps({"kind": "delivery_replay_receipt", "authority": "none",
                      "qualification": "unavailable", "offline_simulation": True,
                      "state": state}, sort_keys=True, separators=(",", ":")), flush=True)


def stop_if_interrupted(state, interrupted):
    if not interrupted["value"]:
        return False
    if state is not None:
        result(state)
    return True


def replay_locked(arguments, state_dir):
    repository = Path(__file__).resolve().parents[2]
    state_path = state_dir / "run.json"
    input_snapshot_path = state_dir / "materialization-input.json"
    lock_path = state_dir / "replay.lock"
    interrupted = {"value": False}
    previous_term = signal.getsignal(signal.SIGTERM)
    previous_int = signal.getsignal(signal.SIGINT)
    signal.signal(signal.SIGTERM, lambda *_: interrupted.__setitem__("value", True))
    signal.signal(signal.SIGINT, lambda *_: interrupted.__setitem__("value", True))
    try:
        lock_descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(lock_descriptor, "a+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            execution = create_execution_snapshot(repository, arguments, state_dir)
            sources_match = execution_sources_match(repository, arguments, execution)
            input_bytes = read_bytes(arguments.input, MAX_INPUT_BYTES)
            input_value = parse_json(input_bytes)
            input_sha = digest_bytes(input_bytes)
            identity = input_identity(input_value, input_sha, arguments, execution)
            state = None
            if state_path.exists():
                state = parse_json(read_bytes(state_path, MAX_OBSERVATION_BYTES))
                validate_state(state, identity)
            if state is not None and any(state["identity"].get(name) != value for name, value in identity.items()):
                result({"phase": "stale", "reason": "run identity changed"})
                return 2
            if not sources_match:
                if state is not None:
                    result({"phase": "stale", "reason": "execution dependencies changed"})
                    return 2
                raise ReplayError("execution bundle does not match current dependencies")
            if stop_if_interrupted(state, interrupted):
                return 75
            if state is None:
                state = {"schema_version": 1, "kind": "delivery_replay_state", "identity": identity,
                         "phase": "materializing", "authority": "none", "qualification": "unavailable"}
                atomic_bytes(input_snapshot_path, input_bytes)
                atomic_json(state_path, state)
            elif not input_snapshot_path.is_file() or input_snapshot_path.is_symlink() or (
                digest_bytes(read_bytes(input_snapshot_path, MAX_INPUT_BYTES)) != identity["input_sha256"]
            ):
                raise ReplayError("saved materialization input snapshot is unavailable")
            if state["phase"] == "failed":
                if state.get("recoverable"):
                    state["recovery"] = "start a new replay with fresh empty candidate, scratch, and state directories"
                    atomic_json(state_path, state)
                result(state)
                return 1
            if state["phase"] == "completed-offline":
                revalidate_candidate(arguments, state)
                if stop_if_interrupted(state, interrupted):
                    return 75
                for supplied, kind, field, recorded in (
                    (arguments.review_observation, "delivery_replay_review_observation", "verdict", state.get("review")),
                    (arguments.publisher_observation, "delivery_replay_publisher_observation", "disposition", state.get("publisher")),
                ):
                    if supplied is not None:
                        supplied_observation = observation(supplied, kind, state["identity"], field)
                        if stop_if_interrupted(state, interrupted):
                            return 75
                        if supplied_observation != recorded:
                            raise ReplayError("supplied offline observation changed after completion")
                result(state)
                return 0
            if state["phase"] == "materializing":
                try:
                    reconciled = reconcile_materialization(arguments, execution, input_snapshot_path,
                                                           identity, state_dir)
                    state["materialization"] = reconciled or run_materializer(
                        arguments, execution, input_snapshot_path, identity
                    )
                except ReplayError as error:
                    if stop_if_interrupted(state, interrupted):
                        return 75
                    state.update({"phase": "failed", "recoverable": True, "reason": str(error)})
                    atomic_json(state_path, state)
                    result(state)
                    return 1
                state["identity"].update({
                    "candidate_commit_id": state["materialization"]["candidate_commit_id"],
                    "candidate_tree_id": state["materialization"]["candidate_tree_id"],
                })
                state["phase"] = "verifying"
                atomic_json(state_path, state)
                if stop_if_interrupted(state, interrupted):
                    return 75
            if state["phase"] == "verifying":
                try:
                    state["verification"] = {"id": identity["verifier"]["id"], "path": identity["verifier"]["path"],
                                             "sha256": verify_candidate(arguments.candidate_root, state["identity"]["candidate_tree_id"],
                                                                        identity["verifier"]["path"], identity["verifier"]["expected_sha256"])}
                except ReplayError as error:
                    if stop_if_interrupted(state, interrupted):
                        return 75
                    state.update({"phase": "failed", "recoverable": False, "reason": str(error)})
                    atomic_json(state_path, state)
                    result(state)
                    return 1
                state["phase"] = "review-wait"
                atomic_json(state_path, state)
                if stop_if_interrupted(state, interrupted):
                    return 75
            if state["phase"] == "review-wait":
                revalidate_candidate(arguments, state)
                if stop_if_interrupted(state, interrupted):
                    return 75
                review = observation(arguments.review_observation, "delivery_replay_review_observation", state["identity"], "verdict")
                if stop_if_interrupted(state, interrupted):
                    return 75
                if review is None:
                    result(state)
                    return 0
                if review["verdict"] != "clean":
                    state.update({"phase": "failed", "recoverable": False, "reason": "offline review did not report clean"})
                    atomic_json(state_path, state)
                    result(state)
                    return 1
                state["review"] = review
                state["phase"] = "publish-wait"
                atomic_json(state_path, state)
            if state["phase"] == "publish-wait":
                with hold_candidate_ref(arguments.candidate_root,
                                        state["materialization"]["candidate_commit_id"]):
                    revalidate_candidate(arguments, state)
                    if stop_if_interrupted(state, interrupted):
                        return 75
                    if arguments.review_observation is not None:
                        supplied_review = observation(arguments.review_observation,
                                                      "delivery_replay_review_observation",
                                                      state["identity"], "verdict")
                        if stop_if_interrupted(state, interrupted):
                            return 75
                        if supplied_review != state.get("review"):
                            raise ReplayError("supplied offline review changed after review wait")
                    publisher = observation(arguments.publisher_observation,
                                            "delivery_replay_publisher_observation",
                                            state["identity"], "disposition")
                    if stop_if_interrupted(state, interrupted):
                        return 75
                    if publisher is None:
                        result(state)
                        return 0
                    if publisher["disposition"] != "offline-simulated":
                        state.update({"phase": "failed", "recoverable": False, "reason": "offline publisher disposition is invalid"})
                        atomic_json(state_path, state)
                        result(state)
                        return 1
                    state["publisher"] = publisher
                    state["phase"] = "completed-offline"
                    atomic_json(state_path, state)
                    result(state)
                    return 0
            result(state)
            return 1
    finally:
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_int)


def replay(arguments):
    state_dir = private_directory(arguments.state_dir)
    disjoint(state_dir, arguments.source_git_dir, arguments.candidate_root, arguments.scratch_root)
    return replay_locked(arguments, state_dir)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--source-repository-id", required=True)
    parser.add_argument("--source-git-dir", required=True)
    parser.add_argument("--candidate-root", required=True)
    parser.add_argument("--scratch-root", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--closure-helper", required=True)
    parser.add_argument("--jq-bin", required=True)
    parser.add_argument("--verify-path", required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--review-observation")
    parser.add_argument("--publisher-observation")
    try:
        return replay(parser.parse_args())
    except (OSError, ReplayError) as error:
        print(f"delivery replay: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
