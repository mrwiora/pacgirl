#!/usr/bin/env bash
# install.sh — self-contained installer for the pacgirl Arch Linux controller.
#
# This single script embeds the pacgirl runtime script, the default config, and
# the systemd service unit, so copying and running it is all you need to deploy.
#
# Install (default):
#   - writes pacgirl to /usr/local/bin/pacgirl
#   - writes /etc/pacgirl.conf only if it does not already exist (preserves edits)
#   - writes the systemd oneshot service
#   - generates /etc/systemd/system/pacgirl.timer from SCAN_SCHEDULE
#     (a native systemd OnCalendar calendar expression), validates it, and enables it
#
# Uninstall (--uninstall):
#   - disables and removes the timer, removes the service unit, reloads systemd,
#     removes the script and lock file. Keeps the config unless --purge is given.
#   - a running pacgirl.service is NOT killed, so an in-progress upgrade is
#     not interrupted.
#
# Options:
#   --dry-run       Print actions only; change nothing (works for install and uninstall).
#   --no-enable     Place files and write the timer, but skip systemctl daemon-reload
#                   / enable --now (for containers without systemd as PID 1).
#   --uninstall     Remove the installed script, units and timer.
#   --purge         With --uninstall, also remove /etc/pacgirl/pacgirl.conf.
#
# The installer only installs. It writes a timer with the built-in default
# schedule; pacgirl adopts the configured SCAN_SCHEDULE at start, so editing
# /etc/pacgirl/pacgirl.conf takes effect at the next run without re-installing.
#
# Functions are prefixed with install_ and paths/systemctl are overridable via
# environment so the logic can be tested in Docker without a running systemd.

# Overridable destinations / commands (for testing).
: "${SCRIPT_DST:=/usr/local/bin/pacgirl}"
: "${CONFIG_DST:=/etc/pacgirl/pacgirl.conf}"
: "${SERVICE_DST:=/etc/systemd/system/pacgirl.service}"
: "${TIMER_DST:=/etc/systemd/system/pacgirl.timer}"
: "${LOCK_FILE:=/run/pacgirl.lock}"
: "${SYSTEMCTL:=systemctl}"

# Program version. MUST match VERSION inside emit_pacgirl_script (the embedded
# script is emitted verbatim via a quoted heredoc, so it cannot reference this).
PACGIRL_VERSION="0.0.1"

# Built-in default schedule. The installer writes a timer with this schedule;
# pacgirl adopts the configured SCAN_SCHEDULE at start (see adopt_timer).
SCAN_SCHEDULE_DEFAULT="*-*-* 03:00:00"

DRY_RUN=0
UNINSTALL=0
PURGE=0
NO_ENABLE=0

install_die() { printf 'install: error: %s\n' "$*" >&2; exit 1; }

install_usage() {
    cat <<EOF
pacgirl $PACGIRL_VERSION — self-contained installer for the Arch Linux upgrade controller.

usage: install.sh [--dry-run] [--no-enable] [--uninstall] [--purge]

  --dry-run       Print actions only; change nothing.
  --no-enable     Place files and write the timer, but do not run systemctl
                  daemon-reload / enable (for containers without systemd as PID 1).
  --uninstall     Remove the installed script, units and timer.
  --purge         With --uninstall, also remove $CONFIG_DST.

install.sh is self-contained: it embeds the pacgirl script, the default config,
and the systemd service, so it is the only file needed to deploy pacgirl. It
only installs — it writes a timer with the built-in default schedule; pacgirl
adopts the configured SCAN_SCHEDULE (see /etc/pacgirl/pacgirl.conf) when it
starts, so editing the config takes effect at the next run without re-installing.

SCAN_SCHEDULE is a native systemd OnCalendar calendar expression (e.g.
"*-*-* 03:00:00"); one or more separated by ';'. See systemd.timer(5).
EOF
}

install_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)   DRY_RUN=1; shift ;;
            --no-enable) NO_ENABLE=1; shift ;;
            --uninstall) UNINSTALL=1; shift ;;
            --purge)     PURGE=1; shift ;;
            --help|-h)   install_usage; exit 0 ;;
            *)           install_die "unknown argument: $1" ;;
        esac
    done
}

# ---- embedded files --------------------------------------------------------
# Quoted heredoc delimiters => the bodies are emitted verbatim (no expansion).

emit_pacgirl_script() {
    cat <<'PACGIRL_SCRIPT_EOF'
#!/usr/bin/env bash
# pacgirl — Arch Linux automatic upgrade controller
#
# Runs once per invocation (scheduled by pacgirl.timer). Based on
# /etc/pacgirl/pacgirl.conf it scans for updates, optionally installs them,
# detects whether mkinitcpio ran, and reboots when configured to. At start it
# also "adopts" the configured SCAN_SCHEDULE into pacgirl.timer (so editing the
# config takes effect without re-running the installer).
#
# Real system commands are invoked through overridable variables so the decision
# logic can be unit/integration tested with fakes (see test/).

# Defaults for overridable commands (do not edit here; override via environment
# for testing).
: "${PACMAN:=pacman}"
: "${PACMAN_CONF:=pacman-conf}"
# $CHECKUPDATES is the update-check hook. The default is the internal
# check_updates_pacman() function (no external deps); tests override it.
: "${CHECKUPDATES:=check_updates_pacman}"
: "${UNAME:=uname}"
: "${REBOOT_CMD:=systemctl reboot}"
: "${SHUTDOWN_CMD:=shutdown}"
: "${PACMAN_LOG:=/var/log/pacman.log}"
: "${MODULES_DIR:=/usr/lib/modules}"
: "${WALL:=wall}"
: "${LOGGER:=logger}"
# Timer adoption (config → pacgirl.timer at start). Tests set ADOPT_TIMER=0.
: "${TIMER_DST:=/etc/systemd/system/pacgirl.timer}"
: "${SYSTEMCTL:=systemctl}"
: "${SYSTEMD_ANALYZE:=systemd-analyze}"
: "${ADOPT_TIMER:=1}"

# ---- defaults / globals ----------------------------------------------------
VERSION="0.0.1"
CONFIG_PATH="/etc/pacgirl/pacgirl.conf"
CHECK_ONLY=0
LOCK_FILE="/run/pacgirl.lock"
LOG_TAG="pacgirl"

AUTO_INSTALL=true
REBOOT_ALWAYS=false
REBOOT_AFTER_MKINITCPIO=true
REBOOT_DELAY=60
UPDATE_KEYRING_FIRST=true
SCAN_SCHEDULE="*-*-* 03:00:00"

# run state
UPGRADE_LOG=""
MKINITCPIO_RAN=false

# ---- small helpers ---------------------------------------------------------
lower() { printf '%s' "${1,,}"; }

# trim leading/trailing whitespace (used when parsing ';'-separated schedules).
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_true() {
    case "$(lower "$1")" in
        1|true|yes|on|y) return 0 ;;
        *) return 1 ;;
    esac
}

to_bool() { if is_true "$1"; then printf 'true'; else printf 'false'; fi; }

# log() — central message hook. Routes by context to avoid duplicate journald
# entries: under systemd stdout is a pipe (not a tty), so only the logger path
# runs and the message is written to journald once (tagged "pacgirl"). When run
# interactively (stdout is a tty), it echoes to the terminal instead. logger is
# used (not printf) so messages are still visible when log() is called inside a
# command substitution, where stdout is captured and a printf would be lost.
log() {
    local msg="$*"
    if [[ -t 1 ]]; then
        printf '[pacgirl] %s\n' "$msg"
    elif command -v "$LOGGER" >/dev/null 2>&1; then
        "$LOGGER" -t "$LOG_TAG" "$msg" 2>/dev/null || true
    else
        printf '[pacgirl] %s\n' "$msg" >&2
    fi
}

# notify() — central notification hook. Currently: journald (via log) + wall.
# A KDE/DBus desktop notifier can be added here later without touching callers.
notify() {
    local msg="$*"
    log "$msg"
    if command -v "$WALL" >/dev/null 2>&1; then
        printf '%s\n' "$msg" | "$WALL" 2>/dev/null || true
    fi
}

die() { log "ERROR: $*"; exit 1; }

# ---- config ----------------------------------------------------------------
# Parse KEY=VALUE lines only (no sourcing of arbitrary code) for safety.
set_config_var() {
    case "$1" in
        SCAN_SCHEDULE)           SCAN_SCHEDULE="$2" ;;
        AUTO_INSTALL)            AUTO_INSTALL="$(to_bool "$2")" ;;
        REBOOT_ALWAYS)           REBOOT_ALWAYS="$(to_bool "$2")" ;;
        REBOOT_AFTER_MKINITCPIO) REBOOT_AFTER_MKINITCPIO="$(to_bool "$2")" ;;
        REBOOT_DELAY)            REBOOT_DELAY="$2" ;;
        UPDATE_KEYRING_FIRST)    UPDATE_KEYRING_FIRST="$(to_bool "$2")" ;;
        *) ;; # ignore unknown keys
    esac
}

load_config() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        log "no config at $CONFIG_PATH; using built-in defaults"
        return 0
    fi
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"                                   # strip comments
        line="${line#"${line%%[![:space:]]*}"}"              # left trim
        line="${line%"${line##*[![:space:]]}"}"              # right trim
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val#\"}"; val="${val%\"}"                 # strip quotes
            set_config_var "$key" "$val"
        fi
    done < "$CONFIG_PATH"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)  CHECK_ONLY=1; shift ;;
            --config) [[ $# -ge 2 ]] || die "--config requires a path"; CONFIG_PATH="$2"; shift 2 ;;
            --help|-h)
                cat <<EOF
pacgirl $VERSION — Arch Linux automatic upgrade controller

usage: pacgirl [--check] [--config PATH] [--version]

  --check        Scan and report only; never install or reboot.
  --config PATH  Use PATH instead of /etc/pacgirl/pacgirl.conf.
  --version      Print the version and exit.

The scan schedule is set via SCAN_SCHEDULE in the config file as a native
systemd OnCalendar expression (e.g. "*-*-* 03:00:00"); see systemd.timer(5).
EOF
                exit 0 ;;
            --version|-V)
                printf 'pacgirl %s\n' "$VERSION"; exit 0 ;;
            *) die "unknown argument: $1" ;;
        esac
    done
}

# ---- concurrency / pacman lock --------------------------------------------
acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "another pacgirl run is in progress; exiting"
        exit 0
    fi
}

wait_pacman_lock() {
    local lock="/var/lib/pacman/db.lck" waited=0
    while [[ -e "$lock" ]]; do
        if (( waited >= 60 )); then
            die "pacman database lock held after ${waited}s; aborting"
        fi
        log "pacman database locked; waiting..."
        sleep 5
        waited=$((waited + 5))
    done
}

# ---- update detection ------------------------------------------------------
# detect_updates prints pending upgrades (one per line) and returns:
#   0 = updates available, 1 = up to date, 2 = the check itself failed.
# It never calls exit/die: it is invoked via $(...) in main(), where an exit
# would only quit the command-substitution subshell. The actual work is done by
# $CHECKUPDATES (default: check_updates_pacman below); tests swap in a fake.
#
# check_updates_pacman: safe, non-invasive update check using pacman directly.
# It syncs repo metadata into a throwaway database (symlinking the real "local"
# installed-DB so `pacman -Qu` can compare installed vs. available) and lists
# pending upgrades. The LIVE pacman database is never modified, so there is no
# partial-upgrade risk. pacgirl runs as root, so no fakeroot is needed (fakeroot
# only exists so non-root users can run `checkupdates`).
#
# Robustness notes:
#   - pacman's download sandbox may restrict the custom --dbpath and drop
#     privileges to a non-root user, so the temp DB is made world-writable and
#     the sync is tried with --disable-sandbox-filesystem first, then without it
#     (some builds don't recognise the flag).
#   - The sync is retried a few times: right after boot the network may not be
#     fully ready yet. CHECK_RETRIES (default 3) and CHECK_RETRY_SLEEP (default
#     10s) tune this; tests set CHECK_RETRIES=1.
#   - `pacman -Qu` may exit non-zero simply because nothing is upgradable, so
#     up-to-date is decided by EMPTY OUTPUT (like checkupdates), not by exit
#     code -- otherwise an up-to-date system would look like a check failure.
#   - The real pacman stderr is logged on sync failure (never swallowed).
# Returns: 0 = updates available (printed), 2 = up to date, 1 = check failed.
check_updates_pacman() {
    local dbpath tmpdb updates attempt err
    dbpath="$("$PACMAN_CONF" DBPath 2>/dev/null || printf '%s' '/var/lib/pacman')"
    if [[ -z "$dbpath" || ! -d "$dbpath" ]]; then
        dbpath="/var/lib/pacman"
    fi
    tmpdb="$(mktemp -d "${TMPDIR:-/tmp}/pacgirl-checkdb-XXXXXXXX")" || return 1
    err="${tmpdb}/.pacgirl-err"
    # The download sandbox may drop to a non-root user (e.g. alpm); make the
    # temp DB writable by it. It holds only public repo metadata and is deleted
    # at once, so 1777 (sticky, like /tmp itself) is safe here.
    chmod 1777 "$tmpdb" 2>/dev/null || true
    ln -s "${dbpath}/local" "${tmpdb}/local" 2>/dev/null || true
    # Sync repo metadata into the temp DB only (the live DB is untouched).
    attempt=0
    while (( attempt < ${CHECK_RETRIES:-3} )); do
        attempt=$((attempt + 1))
        if "$PACMAN" -Sy --dbpath "$tmpdb" --logfile /dev/null \
                --disable-sandbox-filesystem >/dev/null 2>"$err" \
            || "$PACMAN" -Sy --dbpath "$tmpdb" --logfile /dev/null >/dev/null 2>"$err"; then
            break
        fi
        if (( attempt >= ${CHECK_RETRIES:-3} )); then
            log "ERROR: update check failed (pacman -Sy): $(cat "$err" 2>/dev/null | tr '\n' ' ')"
            rm -rf "$tmpdb"
            return 1
        fi
        sleep "${CHECK_RETRY_SLEEP:-10}" 2>/dev/null || true
    done
    # List pending upgrades. Decide by output: pacman -Qu may exit non-zero when
    # nothing is upgradable, which is NOT an error.
    updates="$("$PACMAN" -Qu --dbpath "$tmpdb" 2>/dev/null)" || updates=""
    rm -rf "$tmpdb"
    if [[ -n "$updates" ]]; then
        printf '%s\n' "$updates"
        return 0
    fi
    return 2
}

detect_updates() {
    local updates rc
    if updates="$("$CHECKUPDATES")"; then
        rc=0
    else
        rc=$?
    fi
    case "$rc" in
        0)
            if [[ -n "$updates" ]]; then
                printf '%s\n' "$updates"
                return 0
            fi
            return 1 ;;   # exit 0 + no output: up to date
        2) return 1 ;;     # up to date
        *) return 2 ;;     # check failed
    esac
}

# ---- upgrade ---------------------------------------------------------------
# Returns 0 on success, 1 on pacman failure. Captures output to UPGRADE_LOG.
do_upgrade() {
    UPGRADE_LOG="$(mktemp)"
    if is_true "$UPDATE_KEYRING_FIRST"; then
        log "updating archlinux-keyring first"
        "$PACMAN" -S --noconfirm --needed archlinux-keyring 2>&1 \
            | tee -a "$UPGRADE_LOG" || log "keyring update failed; continuing"
    fi
    log "starting system upgrade"
    if "$PACMAN" -Syu --noconfirm 2>&1 | tee -a "$UPGRADE_LOG"; then
        return 0
    fi
    return 1
}

# ---- mkinitcpio detection --------------------------------------------------
# Sets MKINITCPIO_RAN=true if mkinitcpio executed during this update.
# Signal 1 (primary): the running kernel's modules dir is gone -> a new kernel
#   + initramfs are on disk -> reboot to use them.
# Signal 2 (secondary): mkinitcpio/initramfs output appeared during the upgrade.
detect_mkinitcpio_ran() {
    MKINITCPIO_RAN=false
    local running_kernel
    running_kernel="$("$UNAME" -r 2>/dev/null || printf '')"
    if [[ -n "$running_kernel" && ! -d "$MODULES_DIR/$running_kernel" ]]; then
        log "running kernel ($running_kernel) modules not on disk; new kernel installed"
        MKINITCPIO_RAN=true
        return 0
    fi
    if [[ -n "$UPGRADE_LOG" && -f "$UPGRADE_LOG" ]] \
        && grep -qiE 'mkinitcpio|initramfs|initcpio|==> (Starting build|Creating|Generating)' "$UPGRADE_LOG"; then
        log "mkinitcpio execution detected in upgrade output"
        MKINITCPIO_RAN=true
        return 0
    fi
    log "no mkinitcpio execution detected"
}

# ---- reboot decision -------------------------------------------------------
# Prints "true" if a reboot should happen, else "false".
should_reboot() {
    if is_true "$REBOOT_ALWAYS"; then
        printf 'true'; return 0
    fi
    if is_true "$REBOOT_AFTER_MKINITCPIO" && is_true "$MKINITCPIO_RAN"; then
        printf 'true'; return 0
    fi
    printf 'false'
}

# Schedule/perform the reboot with a wall warning. Honors REBOOT_DELAY seconds.
schedule_reboot() {
    local delay="${REBOOT_DELAY:-0}" mins msg
    msg="pacgirl: system updates installed"
    if [[ "$delay" =~ ^[0-9]+$ ]] && (( delay > 0 )); then
        mins=$(( (delay + 59) / 60 ))
        (( mins < 1 )) && mins=1
        notify "${msg}; rebooting in ~${mins} minute(s). Cancel with 'shutdown -c'."
        "$SHUTDOWN_CMD" -r "+${mins}" "pacgirl: rebooting in ~${mins} minute(s)" \
            || die "failed to schedule reboot"
    else
        notify "${msg}; rebooting now."
        "$REBOOT_CMD" || die "failed to reboot"
    fi
}

cleanup() {
    if [[ -n "$UPGRADE_LOG" && -f "$UPGRADE_LOG" ]]; then
        rm -f "$UPGRADE_LOG"
    fi
}

# ---- config adoption (schedule → timer) ------------------------------------
# generate_timer_content — print a pacgirl.timer unit body for the given
# schedule (a native systemd OnCalendar expression, or several separated by
# ';'). Pure: no validation, no side effects. adopt_timer validates first and
# only writes when the schedule actually changed.
generate_timer_content() {
    local schedule="${1:-$SCAN_SCHEDULE}"
    local -a calendars
    local oncal="" cal trimmed
    IFS=';' read -r -a calendars <<<"$schedule"
    for cal in "${calendars[@]}"; do
        trimmed="$(trim "$cal")"
        [[ -z "$trimmed" ]] && continue
        oncal+="OnCalendar=${trimmed}"$'\n'
    done
    cat <<EOF
[Unit]
Description=Automatic Arch Linux upgrade (timer)
Documentation=file:///etc/pacgirl/pacgirl.conf

[Timer]
${oncal}Persistent=true
RandomizedDelaySec=5m
Unit=pacgirl.service

[Install]
WantedBy=timers.target
EOF
}

# adopt_timer — read SCAN_SCHEDULE from the loaded config and, if it differs
# from the installed pacgirl.timer, rewrite the timer and reload systemd so the
# new schedule takes effect. This is the "config adoption at start" step: edit
# /etc/pacgirl/pacgirl.conf and the next pacgirl start applies it (no re-install
# needed). Safe by design — it never aborts the run: on any failure (not root,
# no systemd, invalid schedule, unwritable path) it logs and returns 0.
# Skipped in --check mode (caller) and when ADOPT_TIMER=0 (tests).
adopt_timer() {
    local current desired newcontent cal trimmed
    local -a calendars

    # Need root to write under /etc and to talk to systemd.
    (( EUID == 0 )) || return 0
    command -v "$SYSTEMCTL" >/dev/null 2>&1 || return 0

    IFS=';' read -r -a calendars <<<"$SCAN_SCHEDULE"
    desired=""
    for cal in "${calendars[@]}"; do
        trimmed="$(trim "$cal")"
        [[ -z "$trimmed" ]] && continue
        desired+="OnCalendar=${trimmed}"$'\n'
    done
    desired="$(printf '%s' "$desired" | sort || true)"

    current=""
    if [[ -f "$TIMER_DST" ]]; then
        current="$(grep -E '^OnCalendar=' "$TIMER_DST" 2>/dev/null | sort || true)"
    fi
    if [[ "$current" == "$desired" ]]; then
        return 0   # already in sync
    fi

    # Validate each calendar before touching the timer.
    if command -v "$SYSTEMD_ANALYZE" >/dev/null 2>&1; then
        for cal in "${calendars[@]}"; do
            trimmed="$(trim "$cal")"
            [[ -z "$trimmed" ]] && continue
            if ! "$SYSTEMD_ANALYZE" calendar "$trimmed" >/dev/null 2>&1; then
                log "SCAN_SCHEDULE calendar '$trimmed' is invalid; keeping existing timer"
                return 0
            fi
        done
    fi

    newcontent="$(generate_timer_content "$SCAN_SCHEDULE")"
    if ! printf '%s\n' "$newcontent" > "$TIMER_DST"; then
        log "could not write $TIMER_DST; keeping existing timer"
        return 0
    fi
    "$SYSTEMCTL" daemon-reload 2>/dev/null || log "warning: systemctl daemon-reload failed"
    log "adopted SCAN_SCHEDULE into $TIMER_DST (systemd reloaded)"
}

# ---- main ------------------------------------------------------------------
main() {
    parse_args "$@"
    load_config
    acquire_lock
    trap cleanup EXIT

    # Adopt the configured schedule into the timer (not in --check mode; tests
    # disable via ADOPT_TIMER=0). Safe to fail — never aborts the run.
    if (( ! CHECK_ONLY )) && (( ADOPT_TIMER )); then
        adopt_timer
    fi

    if (( CHECK_ONLY )); then
        log "run started (pacgirl $VERSION; mode: check)"
    else
        log "run started (pacgirl $VERSION; mode: auto; auto_install=$AUTO_INSTALL)"
    fi

    local updates count drc
    if updates="$(detect_updates)"; then
        drc=0
    else
        drc=$?
    fi
    case "$drc" in
        0)
            count="$(printf '%s\n' "$updates" | grep -c . || true)"
            log "${count} update(s) available"
            printf '%s\n' "$updates" | sed 's/^/  /' | while IFS= read -r l; do log "$l"; done
            ;;
        1)
            log "system is up to date"
            exit 0
            ;;
        *)
            notify "pacgirl: update check failed; aborting run"
            die "update check failed (detect_updates code $drc)"
            ;;
    esac

    if (( CHECK_ONLY )) || ! is_true "$AUTO_INSTALL"; then
        notify "pacgirl: ${count} update(s) available; installation disabled — not installing"
        exit 0
    fi

    wait_pacman_lock
    if do_upgrade; then
        detect_mkinitcpio_ran
        if [[ "$(should_reboot)" == "true" ]]; then
            schedule_reboot
            exit 0
        fi
        log "updates installed; no reboot required"
        exit 0
    fi
    notify "pacgirl: system upgrade FAILED; not rebooting"
    die "system upgrade failed"
}

# Run only when executed, not when sourced for testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -Eeuo pipefail
    main "$@"
fi
PACGIRL_SCRIPT_EOF
}

emit_pacgirl_conf() {
    cat <<'PACGIRL_CONF_EOF'
# /etc/pacgirl/pacgirl.conf
# Settings for the pacgirl Arch Linux update controller.
# Lines starting with '#' are comments; values may be quoted or not.
#
# Edit this file then start pacgirl (or wait for the next timer fire) to adopt
# the new settings — including SCAN_SCHEDULE, which pacgirl writes into
# pacgirl.timer at start. No need to re-run install.sh.

# --- Schedule ---------------------------------------------------------------
# Native systemd OnCalendar calendar expression (NOT cron).
# See systemd.timer(5) and `systemd-analyze calendar EXPRESSION`.
# Examples:
#   "*-*-* 03:00:00"          daily at 03:00
#   "*-*-* 00/6:00:00"        every 6 hours
#   "*-*-* *:00/30:00"        every 30 minutes
#   "Mon..Fri *-*-* 03:00:00" weekdays at 03:00
#   "Sun *-*-* 03:00:00"      Sunday at 03:00
# To fire on more than one calendar (e.g. Mondays OR the 15th), separate
# several expressions with ';':
#   "Mon *-*-* 03:00:00;*-*-15 03:00:00"
# install.sh writes this verbatim into the timer's OnCalendar= line(s) and
# validates it with `systemd-analyze calendar`.
SCAN_SCHEDULE="*-*-* 03:00:00"

# --- Installation -----------------------------------------------------------
# Install available updates automatically (true/false).
# false = only scan and report (journald + wall), never install.
AUTO_INSTALL=true

# --- Reboot policy ----------------------------------------------------------
# Reboot after ANY successful update install (true/false).
REBOOT_ALWAYS=false

# Reboot only when mkinitcpio ran during the update, i.e. a new kernel/initramfs
# is on disk and the running kernel should be replaced (true/false).
# Ignored when REBOOT_ALWAYS=true.
REBOOT_AFTER_MKINITCPIO=true

# Grace period in seconds before rebooting, with a wall warning sent to all
# logged-in users. 0 = reboot immediately (a warning is still sent first).
REBOOT_DELAY=60

# --- Safety -----------------------------------------------------------------
# Update archlinux-keyring first to reduce PGP signature verification failures
# during the main upgrade (true/false).
UPDATE_KEYRING_FIRST=true
PACGIRL_CONF_EOF
}

emit_pacgirl_service() {
    cat <<'PACGIRL_SERVICE_EOF'
[Unit]
Description=Automatic Arch Linux upgrade (oneshot)
Documentation=file:///etc/pacgirl/pacgirl.conf
Wants=network-online.target
After=network-online.target

# Normally triggered by pacgirl.timer (asynchronous). For a manual one-off that
# does not block the terminal, run:  systemctl start --no-block pacgirl

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pacgirl
# System upgrades can take a while; never time out mid-upgrade.
TimeoutStartSec=0
# Run at low priority so an automated upgrade does not starve interactive work.
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
PACGIRL_SERVICE_EOF
}

# ---- timer generation ------------------------------------------------------
# validate_calendar: die on an invalid systemd calendar spec (installer only —
# pacgirl's adopt_timer logs-and-skips instead, so it never aborts a run).
ensure_root() {
    if (( EUID != 0 )); then
        install_die "must run as root (try: sudo ./install.sh)"
    fi
}

validate_calendar() {
    local cal="$1"
    if command -v systemd-analyze >/dev/null 2>&1; then
        if ! systemd-analyze calendar "$cal" >/dev/null 2>&1; then
            install_die "invalid systemd calendar spec in SCAN_SCHEDULE: '$cal'"
        fi
    fi
}

# Build the pacgirl.timer unit body for the given schedule (a native systemd
# OnCalendar expression, or several separated by ';'). Each calendar is written
# verbatim as an OnCalendar= line and validated with systemd-analyze calendar.
# With no argument, uses the built-in default schedule (the installer only ever
# installs the default; pacgirl adopts the configured schedule at start).
generate_timer() {
    local schedule="${1:-$SCAN_SCHEDULE_DEFAULT}"

    local -a calendars
    local oncal="" cal trimmed
    IFS=';' read -r -a calendars <<<"$schedule"
    for cal in "${calendars[@]}"; do
        trimmed="${cal#"${cal%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [[ -z "$trimmed" ]] && continue
        validate_calendar "$trimmed"
        oncal+="OnCalendar=${trimmed}"$'\n'
    done

    [[ -n "$oncal" ]] \
        || install_die "SCAN_SCHEDULE has no valid calendar expression"

    cat <<EOF
[Unit]
Description=Automatic Arch Linux upgrade (timer)
Documentation=file:///etc/pacgirl/pacgirl.conf

[Timer]
${oncal}Persistent=true
RandomizedDelaySec=5m
Unit=pacgirl.service

[Install]
WantedBy=timers.target
EOF
}

install_files() {
    printf 'install: writing script to %s
' "$SCRIPT_DST"
    emit_pacgirl_script > "$SCRIPT_DST"
    chmod 755 "$SCRIPT_DST"

    # Preserve an existing config so user edits survive reinstalls. To reset to
    # defaults, delete /etc/pacgirl/pacgirl.conf (or --uninstall --purge) before
    # installing. The config lives in its own directory; create it if needed.
    if [[ -e "$CONFIG_DST" ]]; then
        printf 'install: keeping existing %s (delete it to reset to defaults)\n' "$CONFIG_DST"
    else
        mkdir -p "$(dirname "$CONFIG_DST")"
        printf 'install: writing config to %s\n' "$CONFIG_DST"
        emit_pacgirl_conf > "$CONFIG_DST"
        chmod 644 "$CONFIG_DST"
    fi

    printf 'install: writing service to %s\n' "$SERVICE_DST"
    emit_pacgirl_service > "$SERVICE_DST"
    chmod 644 "$SERVICE_DST"
}

# ---- uninstall helpers -----------------------------------------------------
remove_file() {
    local f="$1" label="$2"
    if [[ -e "$f" ]]; then
        if (( DRY_RUN )); then
            printf 'uninstall: would remove %s (%s)\n' "$label" "$f"
        else
            printf 'uninstall: removing %s (%s)\n' "$label" "$f"
            rm -f "$f"
        fi
    fi
}

disable_timer() {
    if "$SYSTEMCTL" is-enabled --quiet pacgirl.timer 2>/dev/null; then
        if (( DRY_RUN )); then
            printf 'uninstall: would disable pacgirl.timer\n'
        else
            printf 'uninstall: disabling pacgirl.timer\n'
            "$SYSTEMCTL" disable --now pacgirl.timer || printf 'uninstall: warning: could not disable timer\n'
        fi
    fi
}

do_uninstall() {
    disable_timer
    remove_file "$TIMER_DST"   "timer unit"
    remove_file "$SERVICE_DST" "service unit"

    if (( DRY_RUN )); then
        printf 'uninstall: would run: systemctl daemon-reload\n'
    else
        "$SYSTEMCTL" daemon-reload 2>/dev/null || true
    fi

    remove_file "$SCRIPT_DST"  "script"
    remove_file "$LOCK_FILE"   "lock file"

    if (( PURGE )); then
        remove_file "$CONFIG_DST" "config"
        # The config lives in its own directory (/etc/pacgirl); remove the dir
        # too, but only if empty so we never delete unrelated user files.
        local cfgdir
        cfgdir="$(dirname "$CONFIG_DST")"
        if [[ -d "$cfgdir" ]]; then
            if (( DRY_RUN )); then
                printf 'uninstall: would rmdir %s (if empty)\n' "$cfgdir"
            else
                rmdir "$cfgdir" 2>/dev/null || true
            fi
        fi
    elif [[ -e "$CONFIG_DST" ]]; then
        if (( DRY_RUN )); then
            printf 'uninstall: would keep %s (use --purge to remove it)\n' "$CONFIG_DST"
        else
            printf 'uninstall: kept %s (use --purge to remove it)\n' "$CONFIG_DST"
        fi
    fi
    printf 'uninstall: done\n'
}

# ---- entry point -----------------------------------------------------------
install_main() {
    install_parse_args "$@"
    ensure_root
    printf 'pacgirl %s\n' "$PACGIRL_VERSION"

    if (( UNINSTALL )); then
        do_uninstall
        return 0
    fi

    local timer_content
    timer_content="$(generate_timer)"

    if (( DRY_RUN )); then
        printf '\n--- generated %s ---\n' "$TIMER_DST"
        printf '%s\n' "$timer_content"
        printf -- '--- end ---\n\n'
        printf 'install: DRY RUN — no files written, timer not enabled\n'
        printf 'install: would write: %s, %s (if missing), %s, %s\n' \
            "$SCRIPT_DST" "$CONFIG_DST" "$SERVICE_DST" "$TIMER_DST"
        if (( NO_ENABLE )); then
            printf 'install: would skip: systemctl daemon-reload / enable (--no-enable)\n'
        else
            printf 'install: would run: systemctl daemon-reload; systemctl enable --now pacgirl.timer\n'
        fi
        exit 0
    fi

    install_files

    printf 'install: writing timer to %s\n' "$TIMER_DST"
    printf '%s\n' "$timer_content" > "$TIMER_DST"

    if (( NO_ENABLE )); then
        printf 'install: --no-enable: skipping daemon-reload and timer enable\n'
    else
        printf 'install: reloading systemd, enabling timer\n'
        "$SYSTEMCTL" daemon-reload
        "$SYSTEMCTL" enable --now pacgirl.timer
        printf 'install: done. Status:\n'
        "$SYSTEMCTL" status pacgirl.timer --no-pager || true
        printf '\nNext trigger(s):\n'
        "$SYSTEMCTL" list-timers pacgirl.timer --no-pager || true
    fi
}

# Run only when executed, not when sourced for testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -Eeuo pipefail
    install_main "$@"
fi
