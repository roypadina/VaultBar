#!/usr/bin/env bash
# launchd end-to-end test of "always one copy running": hand-off to the login agent, an upgrade replacing the bundle
# under the running agent (the way brew does), and a crash (kill -9).
#
# It uses a separate headless variant: bundle id com.padina.vaultbar.e2e, executable VaultBarE2E, login agent
# com.padina.vaultbar.e2e.login (~/Library/LaunchAgents/com.padina.vaultbar.e2e.login.plist), config in .scratch with
# no vaults, no menu bar item and no URL scheme. So it never touches the real app, its login agent or any vault.
# macOS may show a "Background Items Added" notification. Everything is removed again at the end.
#
# A monitor samples `pgrep -x VaultBarE2E` every 200 ms; each scenario fails if no copy was running for longer
# than MAX_GAP_MS (default 1000), or if it doesn't end with exactly one copy, started by launchd.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
NAME="VaultBarE2E"
BUNDLE_ID="com.padina.vaultbar.e2e"
SERVICE="gui/$(id -u)/$BUNDLE_ID.login"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.login.plist"
WORK="$ROOT_DIR/.scratch/launchd"
APP="$WORK/apps/$NAME.app"
EXE="$APP/Contents/MacOS/$NAME"
SAMPLES="$WORK/samples.txt"
MAX_GAP_MS="${MAX_GAP_MS:-1000}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

build() { # build number, output folder
    APP_NAME="$NAME" BUNDLE_ID="$BUNDLE_ID" BUILD_NUMBER="$1" DIST_DIR="$2" TEST_CONFIG_DIR="$WORK/config" \
        CODE_SIGN_IDENTITY=- Scripts/package_app.sh >/dev/null
}
copies() { pgrep -x "$NAME" || true; }
agent_pid() { launchctl print "$SERVICE" 2>/dev/null | awk '$1 == "pid" && $2 == "=" { print $3; exit }'; }
# The executable a process runs (launchd starts the agent with a relative argv[0], so `ps` can't tell).
exe_of() { lsof -a -p "$1" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
phase() { echo "# $1 $(now_ms)" >> "$SAMPLES"; echo "== $1"; }

# Exactly one copy, it is launchd's agent copy, and it runs the bundle at $APP (not a moved-away old one).
one_agent() {
    local agent
    agent="$(agent_pid)"
    [[ -n "$agent" && "$(copies)" == "$agent" && "$(exe_of "$agent")" == "$EXE" ]]
}
upgraded() { one_agent && [[ "$(agent_pid)" != "$before" ]]; }
restarted() { one_agent && [[ "$(agent_pid)" != "$killed" ]]; }

wait_for() { # what, seconds, command…
    local what="$1" seconds="$2"
    shift 2
    for ((i = 0; i < seconds * 5; i++)); do
        if "$@"; then echo "   ok: $what"; return 0; fi
        sleep 0.2
    done
    echo "FAIL: $what (not within ${seconds} s)"
    echo "--- launchctl print $SERVICE"
    launchctl print "$SERVICE" 2>&1 | grep -E "state =|pid =|last exit|runs =|spawn|program|properties" || true
    echo "--- copies: $(copies | tr '\n' ' ')"
    echo "--- launchd / app log (last 3 min)"
    /usr/bin/log show --last 3m --info --debug --style compact \
        --predicate "(process == \"launchd\" AND eventMessage CONTAINS \"$BUNDLE_ID\") OR (subsystem == \"com.padina.vaultbar\" AND process == \"$NAME\")" \
        2>/dev/null | grep -v "^Timestamp" | cut -c12-23,40-260 | tail -60
    exit 1
}

cleanup() {
    set +e
    [[ -n "${MONITOR:-}" ]] && kill "$MONITOR" 2>/dev/null
    [[ -x "$EXE" ]] && "$EXE" --unregister-login-item
    sleep 1
    for pid in $(copies); do # only this test's variant: its executable lives under .scratch
        [[ "$(exe_of "$pid")" == "$WORK"/* ]] && kill "$pid"
    done
    for app in "$WORK"/*/"$NAME.app"; do [[ -d "$app" ]] && "$LSREGISTER" -u "$app"; done
    rm -rf "$WORK"
    rm -f "$(getconf DARWIN_USER_TEMP_DIR)$BUNDLE_ID".*
    if launchctl print "$SERVICE" >/dev/null 2>&1; then echo "LEFTOVER: $SERVICE is still loaded"; fi
    if [[ -e "$PLIST" ]]; then echo "LEFTOVER: $PLIST"; fi
    if [[ -n "$(copies)" ]]; then echo "LEFTOVER: $NAME still running: $(copies | tr '\n' ' ')"; fi
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK/apps" "$WORK/config" "$WORK/old"
cat > "$WORK/config/vaults.json" <<'JSON'
{ "autoLock": { "onSleep": false, "onScreenLock": false, "idleMinutes": 0 },
  "launchAtLogin": true, "panicHotkey": "off", "vaults": [] }
JSON
chmod 600 "$WORK/config/vaults.json"
echo "== building $NAME build 100 and 101"
build 100 "$WORK/build100"
build 101 "$WORK/build101"
mv "$WORK/build100/$NAME.app" "$APP"

perl -MTime::HiRes=time,sleep -e '$| = 1; while (1) {
    my $n = () = `pgrep -x '"$NAME"'` =~ /\d+/g; printf "%d %d\n", time * 1000, $n; sleep 0.2 }' >> "$SAMPLES" &
MONITOR=$!

phase "i-handoff"   # a manual open: the non-agent copy registers the agent and hands off to it
open -n "$APP"
wait_for "one copy, launchd's agent" 90 one_agent

phase "ii-upgrade"  # brew: move the old bundle away, move the new one in, while the agent runs
sleep 2
before="$(agent_pid)"
mv "$APP" "$WORK/old/$NAME.app"
mv "$WORK/build101/$NAME.app" "$APP"
wait_for "a new agent copy runs the build 101 bundle" 150 upgraded
rm -rf "$WORK/old"

phase "iii-kill"    # a crash: launchd restarts the agent (it must have run for 10 s first)
sleep 12
killed="$(agent_pid)"
kill -9 "$killed"
wait_for "launchd restarted the agent" 30 restarted

phase "end"
sleep 0.5
kill "$MONITOR"
MONITOR=""

# Longest stretch with no copy at all, per scenario (after the first copy ever appeared).
MAX_GAP_MS="$MAX_GAP_MS" perl -e '
    my (%gap, %max, $zero_since);
    my ($phase, $seen, $worst) = ("", 0, 0);
    while (<>) {
        if (/^# (\S+) (\d+)/) { $phase = $1; next }
        my ($t, $n) = split;
        $seen ||= $n > 0;
        next unless $seen && $phase ne "" && $phase ne "end";
        $max{$phase} = $n if $n > ($max{$phase} // 0);
        if ($n == 0) { $zero_since //= $t } elsif (defined $zero_since) {
            my $g = $t - $zero_since; $gap{$phase} = $g if $g > ($gap{$phase} // 0); $zero_since = undef }
        $gap{$phase} //= 0;
    }
    for my $p (sort keys %gap) {
        printf "   %-11s longest gap with no copy: %5d ms, most copies at once: %d\n", $p, $gap{$p}, $max{$p};
        $worst = $gap{$p} if $gap{$p} > $worst;
    }
    printf "   worst gap: %d ms (limit %d ms)\n", $worst, $ENV{MAX_GAP_MS};
    exit($worst > $ENV{MAX_GAP_MS} ? 1 : 0);
' "$SAMPLES" && echo "PASS" || { echo "FAIL: a gap was longer than ${MAX_GAP_MS} ms"; exit 1; }
