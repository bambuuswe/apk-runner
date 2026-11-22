#!/system/bin/sh
#
# Runs as root inside the Android guest. Polls the iOS app for APKs the user
# opened, installs each one and launches it.
#

HOST=10.0.2.2
PORT=47123
DIR=/data/local/tmp/apkrunner
FETCH=/apkrunner/apkfetch

mkdir -p $DIR

log() {
    # Android-x86 hides kernel messages from the console, so write to it directly too
    echo "apkrunner: $*" > /dev/console 2> /dev/null
    echo "<3>apkrunner: $*" > /dev/kmsg
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> $DIR/log.txt
}

notify() {
    # best effort, not every Android build has "cmd notification post"
    cmd notification post -S bigtext -t "APK Runner" apkrunner "$1" > /dev/null 2>&1
}

while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

# keep the screen on and skip the lock screen, the iOS app is the "screen"
settings put system screen_off_timeout 2147483647
settings put global stay_on_while_plugged_in 7
locksettings set-disabled true > /dev/null 2>&1
svc power stayon true

# Android-x86 ships two launchers and asks which one to use on every boot;
# keep the normal one (Quickstep) by turning off Taskbar
for PKG in $(pm list packages -e | grep -i taskbar | sed 's/^package://'); do
    pm disable-user --user 0 "$PKG" > /dev/null 2>&1 && log "disabled launcher $PKG"
done
input keyevent 3
input keyevent 224
wm dismiss-keyguard > /dev/null 2>&1

CMDLINE=$(cat /proc/cmdline)

# The cloud build boots the image once ("firstboot") so the phone does not have
# to do Android's slow first-boot setup, then shuts it down cleanly.
case "$CMDLINE" in
*apkrunner.ci=firstboot*)
    log "first boot setup done, shutting down in 90s"
    sleep 90
    sync
    svc power shutdown || reboot -p
    exit 0
    ;;
esac

# Android-x86 can translate ARM apps (native bridge). Turning it on makes
# Android-x86 download its translator from dl.android-x86.org on first use.
# Skipped in the cloud build so the shipped image does not contain it.
case "$CMDLINE" in
*apkrunner.ci=*)
    ;;
*)
    if [ "$(getprop persist.sys.nativebridge)" != "1" ]; then
        setprop persist.sys.nativebridge 1
        log "native bridge enabled"
    fi
    ;;
esac

netstate() {
    echo "$(ip -4 addr show 2>&1 | grep inet | tr -s ' ' | tr '\n' ';') rules: $(ip rule 2>&1 | grep -c .)"
}

# Make sure the host (QEMU user networking, always 10.0.2.2) is reachable from
# this root service even if Android has not set up the network: give eth0 the
# address QEMU's DHCP would hand out and route 10.0.2.0/24 through the main table,
# since Android's policy routing drops traffic from sockets netd did not mark.
ensure_route() {
    IFACE=eth0
    ip link set $IFACE up 2> /dev/null
    if ! ip -4 addr show $IFACE 2> /dev/null | grep -q inet; then
        ip addr add 10.0.2.15/24 dev $IFACE 2> /dev/null && log "configured $IFACE manually"
    fi
    ip route add 10.0.2.0/24 dev $IFACE table main 2> /dev/null
    if ! ip rule 2> /dev/null | grep -q "to 10.0.2.0/24"; then
        ip rule add to 10.0.2.0/24 lookup main pref 99 2> /dev/null && log "added host route rule"
    fi
}

log "ready, waiting for APKs from $HOST:$PORT"
log "network before: $(netstate)"
ensure_route
log "network after: $(netstate)"

TRIES=0
while true; do
    APK=$DIR/incoming.apk
    rm -f $APK $APK.part
    ERR=$($FETCH $HOST $PORT $APK 2>&1)
    RC=$?
    TRIES=$((TRIES + 1))
    if [ $RC -ne 0 ] && [ -n "$ERR" ]; then
        if [ $TRIES -le 3 ] || [ $((TRIES % 60)) -eq 0 ]; then
            log "fetch attempt $TRIES: $ERR"
        fi
        # Android may reconfigure the network later, so keep the route in place
        [ $((TRIES % 15)) -eq 0 ] && ensure_route
    fi
    if [ $RC -eq 0 ]; then
        log "received $(wc -c < $APK) bytes"
        notify "Installing app..."
        OUT=$(pm install -r -g "$APK" 2>&1)
        log "pm install: $OUT"
        case "$OUT" in
        *Success*)
            NEWEST=$(ls -t /data/app | head -n 1)
            PKG=${NEWEST%%-*}
            log "installed $PKG"
            input keyevent 224
            wm dismiss-keyguard > /dev/null 2>&1
            if [ -n "$PKG" ]; then
                monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
                log "launched $PKG"
            fi
            ;;
        *)
            notify "Install failed: $OUT"
            ;;
        esac
        rm -f $APK
    elif [ $RC -eq 2 ]; then
        log "transfer failed"
    fi
    sleep 2
done
