#!/bin/zsh
# Sourced by build-app.sh. Publication owns the running instance's lifecycle:
# stop it gracefully before the bundle is replaced (a bundle replaced under a
# running instance makes apps started later refuse its AX calls), then start
# the new bundle and accept success only from its ready marker.
#
# The app writes the ready marker "<pid> <mapped executable inode> <unix time>"
# after launch setup. A process is "running from the published executable"
# when it is a live process with the app's name whose mapped inode is the
# inode of the published file: independent of how its path was spelled
# (relative argv, symlinks, letter case).

switchblade_pid_alive() {
    local state
    state="$(ps -o stat= -p "$1" 2>/dev/null || true)"
    [[ -n "$state" && "$state" != Z* ]]
}

switchblade_pid_name() {
    local command_path
    command_path="$(ps -o comm= -p "$1" 2>/dev/null || true)"
    print -r -- "${command_path:t}"
}

# Prints the marker's pid if the marker names a live process called
# `app_name` that maps the file at `executable` (same inode now).
switchblade_marker_instance() {
    local marker="$1" executable="$2" app_name="$3"
    local pid inode stamp
    [[ -f "$marker" ]] || return 1
    read -r pid inode stamp < "$marker" 2>/dev/null || return 1
    [[ "$pid" == <-> && "$inode" == <-> && "$stamp" == <-> ]] || return 1
    switchblade_pid_alive "$pid" || return 1
    [[ "$(switchblade_pid_name "$pid")" == "$app_name" ]] || return 1
    [[ "$inode" == "$(stat -f %i "$executable" 2>/dev/null)" ]] || return 1
    print -r -- "$pid"
}

# Running instances of the published executable: by exact argv path (both the
# given and the physical spelling) and by the ready marker's inode identity.
switchblade_running_pids() {
    local executable="$1" marker="$2" app_name="$3"
    local resolved pattern spelling
    resolved="${executable:A}"
    {
        for spelling in "$executable" "$resolved"; do
            pattern="^$(printf '%s' "$spelling" | sed 's/[][\.*^$+?(){}|]/\\&/g')( |\$)"
            pgrep -f "$pattern" 2>/dev/null || true
        done
        switchblade_marker_instance "$marker" "$executable" "$app_name" || true
    } | sort -un
}

# SIGTERM (the app quits gracefully once idle, at most a few seconds, and
# writes its window-rank handoff), then SIGKILL after the grace period.
# Returns non-zero only if a process survives SIGKILL.
switchblade_stop_running() {
    local executable="$1" marker="$2" app_name="$3" grace_ticks="${4:-100}"
    local pids
    pids="$(switchblade_running_pids "$executable" "$marker" "$app_name")"
    [[ -z "$pids" ]] && return 0
    kill -TERM ${(f)pids} 2>/dev/null || true
    local tick=0 remaining
    while true; do
        remaining=""
        for pid in ${(f)pids}; do switchblade_pid_alive "$pid" && remaining+="$pid"$'\n'; done
        [[ -z "$remaining" ]] && return 0
        tick=$((tick + 1))
        if (( tick == grace_ticks )); then
            echo "WARNING: running instance did not quit within the grace period; killing it (window order is lost)." >&2
            kill -KILL ${(f)remaining} 2>/dev/null || true
        fi
        (( tick > grace_ticks + 50 )) && return 1
        sleep 0.1
    done
}

# Prints the ready pid once a marker written at or after `since` names a live
# process called `app_name` that maps the published file. Never accepts mere
# process existence.
switchblade_wait_ready() {
    local marker="$1" executable="$2" since="$3" app_name="$4" ticks="${5:-150}"
    local tick=0 pid inode stamp
    while (( tick < ticks )); do
        if [[ -f "$marker" ]] && read -r pid inode stamp < "$marker" 2>/dev/null \
            && [[ "$stamp" == <-> ]] && (( stamp >= since )) \
            && pid="$(switchblade_marker_instance "$marker" "$executable" "$app_name")"; then
            print -r -- "$pid"
            return 0
        fi
        tick=$((tick + 1))
        sleep 0.1
    done
    return 1
}

typeset -g SWITCHBLADE_STOPPED_BUNDLE=""
typeset -g SWITCHBLADE_STOPPED_OPEN_CMD="open"

# Launch the bundle and wait for its ready marker; one retry with `open -n`
# (the app's instance lock keeps it to one instance).
switchblade_start_and_wait() {
    local final="$1" app_name="$2" marker="$3" open_cmd="$4" ticks="$5"
    local executable="$final/Contents/MacOS/$app_name" since pid
    since="$(date +%s)"
    "$open_cmd" "$final" 2>/dev/null || true
    if pid="$(switchblade_wait_ready "$marker" "$executable" "$since" "$app_name" "$ticks")"; then
        print -r -- "$pid"; return 0
    fi
    "$open_cmd" -n "$final" 2>/dev/null || true
    switchblade_wait_ready "$marker" "$executable" "$since" "$app_name" "$ticks"
}

# For an EXIT/INT trap: if an instance was stopped for publication and not
# restarted yet, start whatever bundle is now published (old or new).
switchblade_restore_if_stopped() {
    [[ -n "$SWITCHBLADE_STOPPED_BUNDLE" ]] || return 0
    local final="$SWITCHBLADE_STOPPED_BUNDLE"
    SWITCHBLADE_STOPPED_BUNDLE=""
    echo "Restarting SwitchBlade after an interrupted publication." >&2
    "$SWITCHBLADE_STOPPED_OPEN_CMD" "$final" 2>/dev/null || "$SWITCHBLADE_STOPPED_OPEN_CMD" -n "$final" 2>/dev/null || true
}

# Never replaces the bundle under a running instance. If one ran, it is
# stopped first and a build is started afterwards whatever happened to the
# swap; success requires the new build's ready marker.
switchblade_publish() {
    local staging="$1" final="$2" app_name="$3" marker="$4" replace_cmd="$5"
    local open_cmd="${6:-open}" grace_ticks="${7:-100}" ready_ticks="${8:-150}"
    local executable="$final/Contents/MacOS/$app_name"
    if [[ -z "$(switchblade_running_pids "$executable" "$marker" "$app_name")" ]]; then
        "$replace_cmd" "$staging" "$final" || return 1
        rm -rf "$staging"
        return 0
    fi
    switchblade_stop_running "$executable" "$marker" "$app_name" "$grace_ticks" || {
        echo "ERROR: the running SwitchBlade could not be stopped; the bundle was not replaced." >&2
        return 1
    }
    SWITCHBLADE_STOPPED_BUNDLE="$final"
    SWITCHBLADE_STOPPED_OPEN_CMD="$open_cmd"
    local published=0
    if "$replace_cmd" "$staging" "$final"; then
        published=1
        rm -rf "$staging" 2>/dev/null || true
    else
        echo "ERROR: publication failed after stopping SwitchBlade; restarting the previous build." >&2
    fi
    if [[ "${SWITCHBLADE_NO_RELAUNCH:-0}" == "1" ]]; then
        SWITCHBLADE_STOPPED_BUNDLE=""
        echo "NOTE: SwitchBlade was stopped for publication and not restarted (SWITCHBLADE_NO_RELAUNCH=1)."
        (( published )) && return 0 || return 1
    fi
    local pid
    if pid="$(switchblade_start_and_wait "$final" "$app_name" "$marker" "$open_cmd" "$ready_ticks")"; then
        SWITCHBLADE_STOPPED_BUNDLE=""
        if (( published )); then
            echo "Relaunched SwitchBlade on the new build (pid $pid, ready)."
            return 0
        fi
        echo "Restarted the previous build (pid $pid); the new build was not published." >&2
        return 1
    fi
    SWITCHBLADE_STOPPED_BUNDLE=""
    echo "ERROR: SwitchBlade was stopped for publication but no build reported ready." >&2
    return 1
}
