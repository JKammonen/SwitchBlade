#!/bin/zsh
# Tests scripts/relaunch-lifecycle.sh end to end with a compiled fake app in a
# temporary directory. The fake "bundle" is deliberately not a ".app" (Gatekeeper
# would assess it and show a dialog) and `open` is replaced by a fake launcher,
# so nothing here touches the real SwitchBlade or LaunchServices.

set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
source "$repo_root/scripts/relaunch-lifecycle.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/switchblade-relaunch-test.XXXXXX")"
work="${work:A}"
cleanup() {
    pkill -KILL -f "^$work/" 2>/dev/null || true
    pkill -KILL -f "^\./FakeApp" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# A tiny app: writes the ready marker like SwitchBlade (pid, own executable
# inode, time) unless FAKE_NO_MARKER, optionally ignores SIGTERM, then sleeps.
cat > "$work/fake.c" <<'C'
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (getenv("FAKE_IGNORE_TERM")) signal(SIGTERM, SIG_IGN);
    const char *marker = getenv("FAKE_MARKER");
    if (marker && !getenv("FAKE_NO_MARKER")) {
        char path[4096]; uint32_t size = sizeof(path); struct stat st;
        if (_NSGetExecutablePath(path, &size) == 0 && stat(path, &st) == 0) {
            char tmp[4200]; snprintf(tmp, sizeof(tmp), "%s.tmp%d", marker, getpid());
            FILE *f = fopen(tmp, "w");
            if (f) { fprintf(f, "%d %llu %ld\n", getpid(), (unsigned long long)st.st_ino, (long)time(NULL)); fclose(f); rename(tmp, marker); }
        }
    }
    sleep(argc > 1 ? atoi(argv[1]) : 30);
    return 0;
}
C
cc -O0 -o "$work/fakeapp" "$work/fake.c" || fail "cannot compile the fake app"

app="FakeApp"
make_bundle() {  # $1 bundle dir
    mkdir -p "$1/Contents/MacOS"
    cp "$work/fakeapp" "$1/Contents/MacOS/$app"
}
final="$work/Dist Bundle+(x)"
marker="$work/ready"
export FAKE_MARKER="$marker"

# Fake launcher: starts "<bundle>/Contents/MacOS/FakeApp" detached; records calls.
cat > "$work/fake-open" <<SH
#!/bin/zsh
[[ "\$1" == -n ]] && shift
print -r -- "\$1" >> "$work/open-calls"
nohup "\$1/Contents/MacOS/$app" 60 >/dev/null 2>&1 &
exit 0
SH
chmod +x "$work/fake-open"
# Fake replace: asserts nothing runs from the published executable, then swaps.
cat > "$work/fake-replace" <<SH
#!/bin/zsh
source "$repo_root/scripts/relaunch-lifecycle.sh"
if [[ -n "\$(switchblade_running_pids "\$2/Contents/MacOS/$app" "$marker" "$app")" ]]; then
  print -r -- "swap-under-running" >> "$work/violations"
fi
rm -rf "\$2" && mv "\$1" "\$2"
SH
chmod +x "$work/fake-replace"
cat > "$work/failing-replace" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$work/failing-replace"

start_instance() {  # running instance with a relative argv[0]
    ( cd "$final/Contents/MacOS" && nohup ./$app 60 >/dev/null 2>&1 & )
    for _ in {1..50}; do [[ -f "$marker" ]] && break; sleep 0.1; done
    read -r instance_pid _ _ < "$marker"
}

# 1. Relative argv[0] is still identified as running from the published file.
make_bundle "$final"
start_instance
found="$(switchblade_running_pids "$final/Contents/MacOS/$app" "$marker" "$app")"
[[ "$found" == "$instance_pid" ]] || fail "instance with relative argv not identified (got '$found')"

# 2. Publish with a running instance: stop before swap, relaunch, ready.
make_bundle "$work/staging"
out="$(switchblade_publish "$work/staging" "$final" "$app" "$marker" "$work/fake-replace" "$work/fake-open" 30 50)" \
    || fail "publish failed: $out"
[[ ! -f "$work/violations" ]] || fail "the bundle was replaced under a running instance"
switchblade_pid_alive "$instance_pid" && fail "the old instance still runs"
new_pid="$(switchblade_marker_instance "$marker" "$final/Contents/MacOS/$app" "$app")" || fail "no instance of the new build"
[[ "$out" == *"Relaunched"*"pid $new_pid"* ]] || fail "report does not name the ready instance: $out"

# 3. No instance running: swap only, nothing is started.
kill -KILL "$new_pid"; sleep 0.2; rm -f "$work/open-calls" "$marker"
make_bundle "$work/staging"
switchblade_publish "$work/staging" "$final" "$app" "$marker" "$work/fake-replace" "$work/fake-open" 30 20 >/dev/null \
    || fail "publish without instance failed"
[[ ! -f "$work/open-calls" ]] || fail "an instance was started although none was running"

# 4. New build never becomes ready: failure, never success.
start_instance
make_bundle "$work/staging"
if out="$(FAKE_NO_MARKER=1 switchblade_publish "$work/staging" "$final" "$app" "$marker" "$work/fake-replace" "$work/fake-open" 30 10 2>&1)"; then
    fail "an unready build was reported as success"
fi
[[ "$out" == *"no build reported ready"* ]] || fail "unready failure not reported: $out"
pkill -KILL -f "^$work/" 2>/dev/null || true; sleep 0.2

# 5. Swap fails after stopping: the previous build is restarted, failure reported.
rm -f "$marker"; start_instance
make_bundle "$work/staging"
if out="$(switchblade_publish "$work/staging" "$final" "$app" "$marker" "$work/failing-replace" "$work/fake-open" 30 50 2>&1)"; then
    fail "a failed swap was reported as success"
fi
[[ "$out" == *"Restarted the previous build"* ]] || fail "previous build not restarted: $out"
switchblade_marker_instance "$marker" "$final/Contents/MacOS/$app" "$app" >/dev/null || fail "no instance after failed swap"
pkill -KILL -f "^$work/" 2>/dev/null || true; pkill -KILL -f "^\./$app" 2>/dev/null || true; sleep 0.2

# 6. An instance ignoring SIGTERM is killed after the grace period, then swapped.
rm -f "$marker"
( cd "$final/Contents/MacOS" && FAKE_IGNORE_TERM=1 nohup ./$app 60 >/dev/null 2>&1 & )
for _ in {1..50}; do [[ -f "$marker" ]] && break; sleep 0.1; done
make_bundle "$work/staging"
switchblade_publish "$work/staging" "$final" "$app" "$marker" "$work/fake-replace" "$work/fake-open" 5 50 >/dev/null 2>&1 \
    || fail "publish after killing a stubborn instance failed"
[[ ! -f "$work/violations" ]] || fail "swap under a stubborn running instance"

# 7. Corrupt or stale markers are plain rejections.
print -r -- "x y z" > "$marker"
switchblade_wait_ready "$marker" "$final/Contents/MacOS/$app" 0 "$app" 3 >/dev/null 2>&1 && fail "corrupt marker accepted"
read -r p i t < "$work/ready" 2>/dev/null || true
print -r -- "$$ 1 0" > "$marker"
switchblade_wait_ready "$marker" "$final/Contents/MacOS/$app" 1 "$app" 3 >/dev/null 2>&1 && fail "stale marker accepted"

# 8. Interrupted publication: the trap helper restarts the stopped bundle.
rm -f "$work/open-calls"
SWITCHBLADE_STOPPED_BUNDLE="$final" SWITCHBLADE_STOPPED_OPEN_CMD="$work/fake-open"
switchblade_restore_if_stopped 2>/dev/null
[[ -f "$work/open-calls" ]] || fail "an interrupted publication did not restart the app"

echo "Relaunch lifecycle tests passed"
