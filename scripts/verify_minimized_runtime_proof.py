#!/usr/bin/env python3
"""Create a staged-tree-bound receipt from a real signed minimized-window scan."""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import platform
import plistlib
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_APP = REPO_ROOT / "dist" / "SwitchBlade.app"
DEFAULT_LOG = Path.home() / "Library" / "Logs" / "SwitchBlade" / "performance.jsonl"
POLICY_PATH = ".quality/test-obligations.json"
PROOF_NAME = "signed minimized AX scan"
PROOF_COMMAND = ["python3", "scripts/verify_minimized_runtime_proof.py"]
RECEIPT_FILE = "switchblade-minimized-window-live.json"
PRODUCER_PATH = "scripts/verify_minimized_runtime_proof.py"


class ProofError(RuntimeError):
    pass


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def run(command: list[str], *, cwd: Path = REPO_ROOT) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )


def git_output(*args: str) -> str:
    result = run(["git", *args])
    if result.returncode != 0:
        raise ProofError((result.stdout or "git command failed").strip())
    return result.stdout.strip()


def git_bytes(tree_id: str, path: str) -> bytes:
    result = subprocess.run(
        ["git", "show", f"{tree_id}:{path}"],
        cwd=str(REPO_ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise ProofError(f"staged source is missing: {path}")
    return result.stdout


def parse_timestamp(value: Any) -> datetime.datetime:
    if not isinstance(value, str) or not value:
        raise ProofError("runtime event is missing an ISO-8601 timestamp")
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ProofError(f"invalid runtime timestamp: {value}") from exc
    if parsed.tzinfo is None:
        raise ProofError(f"runtime timestamp has no timezone: {value}")
    return parsed.astimezone(datetime.timezone.utc)


def qualifying_snapshot(payload: dict[str, Any]) -> bool:
    candidate_apps = payload.get("candidate_apps")
    scanned_apps = payload.get("scanned_apps")
    count = payload.get("count")
    scanned_windows = payload.get("scanned_windows")
    return (
        payload.get("event") == "minimized_window_snapshot"
        and payload.get("complete") is True
        and isinstance(candidate_apps, int)
        and candidate_apps > 0
        and scanned_apps == candidate_apps
        and isinstance(count, int)
        and count > 0
        and isinstance(scanned_windows, int)
        and scanned_windows >= count
    )


def select_snapshot_line(
    lines: Iterable[bytes],
    built_at: datetime.datetime,
) -> tuple[dict[str, Any], bytes]:
    selected: tuple[datetime.datetime, dict[str, Any], bytes] | None = None
    for raw_line in lines:
        line = raw_line.rstrip(b"\r\n")
        if not line:
            continue
        try:
            payload = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if not isinstance(payload, dict) or not qualifying_snapshot(payload):
            continue
        try:
            timestamp = parse_timestamp(payload.get("timestamp"))
        except ProofError:
            continue
        if timestamp < built_at:
            continue
        if selected is None or timestamp > selected[0]:
            selected = (timestamp, payload, line)
    if selected is None:
        raise ProofError(
            "no complete post-build minimized scan with at least one minimized window was found; "
            "open the signed app, keep one safe test window minimized, use Cmd+Tab once, and retry"
        )
    return selected[1], selected[2]


def require_staged_working_copy() -> None:
    relevant = [
        "Package.swift",
        "Package.resolved",
        "Sources/SwitchBlade",
        "Sources/SwitchBladeCore",
        "scripts/build-app.sh",
        "scripts/signing-config.sh",
        "scripts/signing-safety.sh",
        "scripts/setup-local-codesign.sh",
        "scripts/sign-app-with-keychain.c",
        "scripts/atomic-replace.c",
        "scripts/generate-icon.swift",
        PRODUCER_PATH,
    ]
    diff = run(["git", "diff", "--quiet", "--", *relevant])
    if diff.returncode != 0:
        raise ProofError("working production sources differ from the staged tree; rebuild after staging exact files")
    untracked = git_output("ls-files", "--others", "--exclude-standard", "--", *relevant)
    if untracked:
        raise ProofError(f"untracked production sources prevent proof: {untracked}")


def app_subject(app: Path, tree_id: str, head_commit: str) -> tuple[dict[str, Any], datetime.datetime]:
    plist_path = app / "Contents" / "Info.plist"
    executable = app / "Contents" / "MacOS" / "SwitchBlade"
    if not plist_path.is_file() or not executable.is_file():
        raise ProofError(f"signed app bundle is missing: {app}")
    verify = run(["codesign", "--verify", "--deep", "--strict", str(app)])
    if verify.returncode != 0:
        raise ProofError(f"codesign verification failed: {verify.stdout.strip()}")
    requirements = run(["codesign", "-dv", "--requirements", "-", str(app)])
    if requirements.returncode != 0:
        raise ProofError(f"could not read signed app identity: {requirements.stdout.strip()}")
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    built_at = parse_timestamp(plist.get("SwitchBladeBuildTimestamp"))
    if plist.get("SwitchBladeSourceTree") != tree_id:
        raise ProofError("signed app was not built from the current staged tree")
    if plist.get("SwitchBladeSourceHead") != head_commit:
        raise ProofError("signed app was built against a different HEAD")
    if plist.get("SwitchBladeSourceState") != "staged":
        raise ProofError("signed app build did not have staged production sources")
    running = run(["pgrep", "-x", "SwitchBlade"])
    process_identifiers = [line.strip() for line in running.stdout.splitlines() if line.strip()]
    if running.returncode != 0 or len(process_identifiers) != 1:
        raise ProofError("exactly one rebuilt SwitchBlade process must be running")
    process_identifier = process_identifiers[0]
    process = run(["env", "LC_ALL=C", "ps", "-p", process_identifier, "-o", "lstart=", "-o", "command="])
    if process.returncode != 0 or not process.stdout.strip():
        raise ProofError("could not inspect the running SwitchBlade process")
    process_line = process.stdout.strip()
    start_text = process_line[:24]
    command = process_line[24:].strip()
    try:
        local_timezone = datetime.datetime.now().astimezone().tzinfo
        process_started_at = datetime.datetime.strptime(start_text, "%a %b %d %H:%M:%S %Y").replace(
            tzinfo=local_timezone
        ).astimezone(datetime.timezone.utc)
    except ValueError as exc:
        raise ProofError(f"could not parse SwitchBlade process start time: {start_text}") from exc
    if process_started_at < built_at - datetime.timedelta(seconds=2):
        raise ProofError("running SwitchBlade predates the signed build; relaunch dist/SwitchBlade.app")
    if not command.startswith(str(executable)):
        raise ProofError(f"running SwitchBlade is not the staged signed bundle: {command}")

    return ({
        "app_path": str(app),
        "bundle_identifier": plist.get("CFBundleIdentifier"),
        "build_timestamp": plist.get("SwitchBladeBuildTimestamp"),
        "executable_sha256": sha256(executable.read_bytes()),
        "requirements_sha256": sha256(requirements.stdout.encode()),
        "running_command": command,
        "running_pid": int(process_identifier),
        "running_started_at": process_started_at.isoformat(),
        "source_head": head_commit,
        "source_state": plist.get("SwitchBladeSourceState"),
        "source_tree": tree_id,
    }, built_at)


def receipt_directory() -> Path:
    raw = git_output("rev-parse", "--git-path", "test-obligation-runtime-proofs")
    path = Path(raw)
    if not path.is_absolute():
        path = REPO_ROOT / path
    path.mkdir(parents=True, exist_ok=True)
    return path


def create_receipt(app: Path = DEFAULT_APP, log: Path = DEFAULT_LOG) -> Path:
    require_staged_working_copy()
    tree_id = git_output("write-tree")
    head_commit = git_output("rev-parse", "HEAD")
    policy_raw = git_bytes(tree_id, POLICY_PATH)
    producer_raw = git_bytes(tree_id, PRODUCER_PATH)
    subject, built_at = app_subject(app, tree_id, head_commit)
    try:
        with log.open("rb") as handle:
            snapshot, artifact_line = select_snapshot_line(handle, built_at)
    except OSError as exc:
        raise ProofError(f"performance log is unavailable: {log}") from exc

    receipt = {
        "schema_version": 1,
        "name": PROOF_NAME,
        "status": "passed",
        "head_commit": head_commit,
        "staged_tree": tree_id,
        "policy_sha256": sha256(policy_raw),
        "command": PROOF_COMMAND,
        "exit_code": 0,
        "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "producer": {"path": PRODUCER_PATH, "sha256": sha256(producer_raw)},
        "environment": {
            "architecture": platform.machine(),
            "macos_version": platform.mac_ver()[0],
            "python": platform.python_version(),
        },
        "subject": subject,
        "artifact": {"path": str(log), "line_sha256": sha256(artifact_line)},
        "measurements": {
            "candidate_apps": snapshot["candidate_apps"],
            "complete": snapshot["complete"],
            "count": snapshot["count"],
            "milliseconds": snapshot.get("milliseconds"),
            "scanned_apps": snapshot["scanned_apps"],
            "scanned_windows": snapshot["scanned_windows"],
            "unavailable_ax_apps": snapshot.get("unavailable_ax_apps"),
            "zero_window_apps": snapshot.get("zero_window_apps"),
        },
    }
    path = receipt_directory() / RECEIPT_FILE
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    return path


def main() -> int:
    try:
        path = create_receipt()
    except ProofError as exc:
        print(f"MINIMIZED RUNTIME PROOF FAILED: {exc}", file=sys.stderr)
        return 1
    print(f"minimized runtime proof: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
