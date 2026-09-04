#!/usr/bin/env python3
"""Run one inactive, offline delivery replay without executing candidate code."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile


MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_OBSERVATION_BYTES = 64 * 1024
MAX_VERIFIED_BLOB_BYTES = 1024 * 1024
OID = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}\Z")
ACTOR = re.compile(r"[a-z0-9][a-z0-9._:-]{0,127}\Z")


class ReplayError(Exception):
    pass


def digest_bytes(value):
    return hashlib.sha256(value).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def read_json(path, limit):
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
    try:
        return json.loads(data), digest_bytes(data)
    except json.JSONDecodeError as error:
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
    encoded = canonical(value) + b"\n"
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


def input_identity(input_value, input_sha, arguments, materializer):
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
    if not isinstance(source, dict) or not OID.fullmatch(str(source.get("commit_id", ""))):
        raise ReplayError("materialization input commit identity is invalid")
    expected = arguments.expected_sha256
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ReplayError("expected verifier digest is invalid")
    closure = trusted_file(arguments.closure_helper)
    jq_bin = trusted_file(arguments.jq_bin)
    materializer_sha = digest_bytes(materializer.read_bytes())
    identity = {
        "input_sha256": input_sha,
        "request_sha256": request_sha,
        "source_commit_id": source["commit_id"],
        "source_tree_id": source_tree_id,
        "verifier": {
            "id": "delivery.fixed-content-sha256.v1",
            "path": safe_path(arguments.verify_path),
            "expected_sha256": expected,
        },
        "materializer_sha256": materializer_sha,
        "closure_helper_sha256": digest_bytes(closure.read_bytes()),
        "jq_sha256": digest_bytes(jq_bin.read_bytes()),
        "source_repository_id": arguments.source_repository_id,
    }
    identity["run_key"] = digest_bytes(canonical(identity))
    return identity


def run_materializer(arguments, materializer):
    command = [
        str(materializer), "materialize", str(Path(arguments.input).resolve()),
        arguments.source_repository_id, str(Path(arguments.source_git_dir).resolve()),
        str(Path(arguments.candidate_root).resolve()), str(Path(arguments.scratch_root).resolve()),
        str(Path(arguments.closure_helper).resolve()), str(Path(arguments.jq_bin).resolve()),
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
        return {
            "response_sha256": digest_bytes(result.stdout),
            "receipt_sha256": response["payloads"][0]["sha256"],
            "candidate_commit_id": candidate["commit_id"],
            "candidate_tree_id": candidate["tree_id"],
        }
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as error:
        raise ReplayError("materializer response is malformed") from error


def verify_candidate(candidate_root, candidate_tree, path, expected):
    repository = Path(candidate_root).resolve() / "repository.git"
    if not repository.is_dir() or repository.is_symlink() or not OID.fullmatch(candidate_tree):
        raise ReplayError("candidate repository identity is unavailable")
    environment = {"PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_NO_REPLACE_OBJECTS": "1",
                   "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0"}
    object_name = f"{candidate_tree}:{path}"
    size = subprocess.run(["/usr/bin/git", f"--git-dir={repository}", "cat-file", "-s", object_name],
                          env=environment, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    if size.returncode != 0 or not size.stdout.strip().isdigit() or int(size.stdout) > MAX_VERIFIED_BLOB_BYTES:
        raise ReplayError("fixed verifier cannot read the candidate blob")
    blob = subprocess.run(["/usr/bin/git", f"--git-dir={repository}", "cat-file", "blob", object_name],
                          env=environment, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    if blob.returncode != 0 or len(blob.stdout) != int(size.stdout):
        raise ReplayError("fixed verifier could not read the candidate blob")
    actual = digest_bytes(blob.stdout)
    if actual != expected:
        raise ReplayError("fixed verifier digest mismatch")
    return actual


def observation(path, kind, identity, field):
    if path is None:
        return None
    value, source_sha = read_json(path, MAX_OBSERVATION_BYTES)
    if not isinstance(value, dict) or value.get("schema_version") != 1 or value.get("kind") != kind:
        raise ReplayError("offline observation is malformed")
    if not ACTOR.fullmatch(str(value.get("actor_id", ""))):
        raise ReplayError("offline observation actor is invalid")
    if value.get("request_sha256") != identity["request_sha256"] or value.get("candidate_tree_id") != identity["candidate_tree_id"]:
        raise ReplayError("offline observation does not match this candidate")
    return {"actor_id": value["actor_id"], field: value.get(field), "sha256": source_sha}


def result(state):
    print(json.dumps({"kind": "delivery_replay_receipt", "authority": "none",
                      "qualification": "unavailable", "offline_simulation": True,
                      "state": state}, sort_keys=True, separators=(",", ":")))


def replay(arguments):
    repository = Path(__file__).resolve().parents[2]
    materializer = trusted_file(repository / "adapters/local-git-materializer/v1/materialize.sh")
    input_value, input_sha = read_json(arguments.input, MAX_INPUT_BYTES)
    identity = input_identity(input_value, input_sha, arguments, materializer)
    state_dir = private_directory(arguments.state_dir)
    disjoint(state_dir, arguments.source_git_dir, arguments.candidate_root, arguments.scratch_root)
    state_path = state_dir / "run.json"
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
            state = None
            if state_path.exists():
                state, _ = read_json(state_path, MAX_OBSERVATION_BYTES)
                if not isinstance(state, dict):
                    raise ReplayError("state journal is malformed")
            if state is not None and state.get("identity", {}).get("run_key") != identity["run_key"]:
                result({"phase": "stale", "reason": "run identity changed"})
                return 2
            if state is None:
                state = {"schema_version": 1, "kind": "delivery_replay_state", "identity": identity,
                         "phase": "materializing", "authority": "none", "qualification": "unavailable"}
                atomic_json(state_path, state)
            if state["phase"] == "failed":
                if state.get("recoverable"):
                    state["recovery"] = "start a new replay with fresh empty candidate, scratch, and state directories"
                    atomic_json(state_path, state)
                result(state)
                return 1
            if state["phase"] == "completed-offline":
                verify_candidate(arguments.candidate_root, state["identity"]["candidate_tree_id"],
                                 identity["verifier"]["path"], identity["verifier"]["expected_sha256"])
                for supplied, kind, field, recorded in (
                    (arguments.review_observation, "delivery_replay_review_observation", "verdict", state.get("review")),
                    (arguments.publisher_observation, "delivery_replay_publisher_observation", "disposition", state.get("publisher")),
                ):
                    if supplied is not None and observation(supplied, kind, state["identity"], field) != recorded:
                        raise ReplayError("supplied offline observation changed after completion")
                result(state)
                return 0
            if state["phase"] == "materializing":
                try:
                    state["materialization"] = run_materializer(arguments, materializer)
                except ReplayError as error:
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
                if interrupted["value"]:
                    result(state)
                    return 75
            if state["phase"] == "verifying":
                try:
                    state["verification"] = {"id": identity["verifier"]["id"], "path": identity["verifier"]["path"],
                                             "sha256": verify_candidate(arguments.candidate_root, state["identity"]["candidate_tree_id"],
                                                                        identity["verifier"]["path"], identity["verifier"]["expected_sha256"])}
                except ReplayError as error:
                    state.update({"phase": "failed", "recoverable": False, "reason": str(error)})
                    atomic_json(state_path, state)
                    result(state)
                    return 1
                state["phase"] = "review-wait"
                atomic_json(state_path, state)
                if interrupted["value"]:
                    result(state)
                    return 75
            if state["phase"] == "review-wait":
                verify_candidate(arguments.candidate_root, state["identity"]["candidate_tree_id"],
                                 identity["verifier"]["path"], identity["verifier"]["expected_sha256"])
                review = observation(arguments.review_observation, "delivery_replay_review_observation", state["identity"], "verdict")
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
                publisher = observation(arguments.publisher_observation, "delivery_replay_publisher_observation", state["identity"], "disposition")
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
