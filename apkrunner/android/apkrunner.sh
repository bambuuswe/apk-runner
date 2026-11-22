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

log "ready, waiting for APKs from $HOST:$PORT"

while true; do
    APK=$DIR/incoming.apk
    rm -f $APK $APK.part
    $FETCH $HOST $PORT $APK
    RC=$?
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
