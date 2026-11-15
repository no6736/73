cat > ~/farm.sh << 'EOF'
#!/system/bin/sh
echo "== farm v11 =="
PLACE_ID="893973440"
FILTER=${FILTER:-'^aya\.'}
CHECK_INTERVAL=${CHECK_INTERVAL:-5}
HB_STALE=${HB_STALE:-120}
DISC_WAIT=${DISC_WAIT:-30}
JOIN_GRACE=${JOIN_GRACE:-240}
SOFT_GRACE=${SOFT_GRACE:-150}
INITIAL_WAIT=${INITIAL_WAIT:-60}
LAUNCH_WAIT=${LAUNCH_WAIT:-5}
KILL_WAIT=${KILL_WAIT:-2}
ACT_GAP=${ACT_GAP:-25}
LAUNCH_RETRY=${LAUNCH_RETRY:-20}
ENABLE_WATCH=${ENABLE_WATCH:-1}
WATCH_INTERVAL=${WATCH_INTERVAL:-1}
REOPEN_COOLDOWN=${REOPEN_COOLDOWN:-8}
DEBUG=${DEBUG:-1}
DEBUG_LOG=${DEBUG_LOG:-/data/local/tmp/farm_debug.log}
KILLER=${KILLER:-kill}
STATE=${STATE:-/data/local/tmp/farmstate}
PAUSE_FILE=${PAUSE_FILE:-/data/local/tmp/farm_pause}
LIST_CLONE=$(pm list packages -3 | cut -d: -f2 | grep -iE "$FILTER" | tr -d '\r')
if [ -z "$LIST_CLONE" ]; then
    echo "Khong tim thay clone nao!"
    exit 1
fi
TOTAL_CLONE=$(echo "$LIST_CLONE" | wc -l | tr -cd '0-9')
echo "Da nhan dien $TOTAL_CLONE tab:"
echo "$LIST_CLONE"
pkill -f "logcat -b main -v threadtime -T 1" 2>/dev/null
EV="$STATE/ev"
rm -rf "$STATE"
mkdir -p "$STATE" "$EV"
: > "$DEBUG_LOG" 2>/dev/null
START=$(date +%s)
LOOP=0
rv() { local V; V=$(cat "$STATE/$1" 2>/dev/null | tr -d '\r\n'); echo "${V:-$2}"; }
wv() { echo "$2" > "$STATE/$1"; }
ev() { local V; V=$(cat "$EV/$1_$2" 2>/dev/null | tr -d '\r\n'); echo "${V:-0}"; }
dbg() {
    [ "$DEBUG" = "1" ] || return 0
    echo "$(date +%T) $*" >> "$DEBUG_LOG" 2>/dev/null
}
dbg_trim() {
    [ -f "$DEBUG_LOG" ] || return 0
    if [ "$(wc -c < "$DEBUG_LOG" 2>/dev/null | tr -cd '0-9')" -gt 400000 ]; then
        tail -n 1500 "$DEBUG_LOG" > "$DEBUG_LOG.tmp" 2>/dev/null && mv "$DEBUG_LOG.tmp" "$DEBUG_LOG"
    fi
}
get_pid() {
    local P
    P=$(pidof "$1" 2>/dev/null | cut -d' ' -f1 | tr -cd '0-9')
    if [ -z "$P" ]; then
        P=$(pgrep -f "^$1" 2>/dev/null | head -n 1 | tr -cd '0-9')
    fi
    echo "$P"
}
kill_tab() {
    local P
    for P in $(pidof "$1" 2>/dev/null); do
        echo "$(date +%T) [KILL] $1 pid=$P"
        $KILLER -9 "$P" 2>/dev/null
    done
    if [ -n "$(get_pid "$1")" ]; then
        sleep 1
        am force-stop "$1" 2>/dev/null
    fi
}
send_join() {
    local OUT
    OUT=$(am start -n "$1/com.roblox.client.ActivityProtocolLaunch" -a android.intent.action.VIEW -d "roblox://experiences/start?placeId=$PLACE_ID" 2>&1)
    case "$OUT" in
        *Error*|*Exception*|*unable*)
            am start -a android.intent.action.VIEW -p "$1" -d "roblox://experiences/start?placeId=$PLACE_ID" > /dev/null 2>&1
            ;;
    esac
}
reader_loop() {
    local line pid now t n=0
    set -f
    while true; do
        logcat -b main -v threadtime -T 1 -s Roblox:I 2>/dev/null | while IFS= read -r line; do
            case "$line" in
                *"Joining game"*|*"Disconnection Notification"*|*"FARMHB|"*) ;;
                *) continue ;;
            esac
            set -- $line
            pid=$3
            case "$pid" in ''|*[!0-9]*) continue ;; esac
            now=$(date +%s)
            case "$line" in
                *"Joining game"*) echo "$now" > "$EV/join_$pid" ;;
                *"Disconnection Notification"*) echo "$now" > "$EV/disc_$pid" ;;
                *"FARMHB|"*)
                    echo "$now" > "$EV/hb_$pid"
                    t=${line#*FARMHB|}
                    echo "${t%%|*}" > "$EV/user_$pid"
                    ;;
            esac
        done
        sleep 2
    done
}
start_reader() {
    reader_loop &
    READER_PID=$!
}
reader_alive() { kill -0 "$READER_PID" 2>/dev/null; }
launch_app() { send_join "$1"; }
restart_tab() {
    local C N
    C=$(( $(rv "consec_$1" 0) + 1 )); wv "consec_$1" "$C"
    echo "$(date +%T) [RESTART] Tab $2 ($1): $3 (lan $C lien tiep)"
    if [ "$C" -eq 3 ] || { [ "$C" -gt 3 ] && [ $((C % 10)) -eq 0 ]; }; then
        echo "$(date +%T) [CANH BAO] Tab $2 ($1) da restart $C lan lien tiep van chua vao duoc game. Kiem tra acc / autoexec."
    fi
    dbg "ACTION restart tab=$2 pkg=$1 kill=$4 why=$3"
    if [ "$4" = "1" ]; then
        kill_tab "$1"
        sleep "$KILL_WAIT"
    fi
    launch_app "$1"
    N=$(date +%s)
    wv "lt_$1" "$N"; wv "stage_$1" 0; wv "resent_$1" 0
    sleep "$LAUNCH_WAIT"
}
soft_push() {
    local N
    N=$(date +%s)
    echo "$(date +%T) [DAY LAI] Tab $2 ($1): $3 -> day lai vao game (chua kill)"
    dbg "ACTION soft_push tab=$2 pkg=$1 why=$3"
    launch_app "$1"
    wv "lt_$1" "$N"; wv "stage_$1" 1; wv "resent_$1" 0
}
init_tabs() {
    local p
    for p in $LIST_CLONE; do
        if [ -n "$(get_pid "$p")" ]; then
            wv "lt_$p" "$((START - JOIN_GRACE + INITIAL_WAIT))"
        else
            wv "lt_$p" "$START"
        fi
        wv "resent_$p" 1
    done
}
watch_visible() {
    local W a N S OLD L CD
    while true; do
        if [ ! -f "$PAUSE_FILE" ]; then
            W=$(dumpsys window windows 2>/dev/null)
            N=$(date +%s)
            for a in $LIST_CLONE; do
                [ -n "$(get_pid "$a")" ] || continue
                S=false
                if [ "$(echo "$W" | awk -v pat="u0 $a/" '/^ *Window #/{b=(index($0,pat)>0)} b && /mHasSurface=true/{print "true"; exit}')" = "true" ]; then S=true; fi
                OLD=$(rv "wstate_$a" "")
                if [ "$S" != "$OLD" ]; then wv "wstate_$a" "$S"; dbg "WATCH $a surface=$S"; fi
                if [ "$S" = "false" ]; then
                    L=$(rv "lt_$a" 0)
                    CD=$REOPEN_COOLDOWN
                    [ "$(rv "reopen_n_$a" 0)" -ge 5 ] && CD=60
                    if [ $((N - L)) -ge 10 ] && [ $((N - $(rv "reopen_$a" 0))) -ge "$CD" ]; then
                        wv "reopen_n_$a" "$(( $(rv "reopen_n_$a" 0) + 1 ))"
                        wv "reopen_$a" "$N"
                        echo "$(date +%T) [THU NHO] $a -> mo lai"
                        monkey -p "$a" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1 &
                    fi
                else
                    wv "reopen_n_$a" 0
                fi
            done
        fi
        sleep "$WATCH_INTERVAL"
    done
}
act_ok() { [ $(( $(date +%s) - LAST_ACT )) -ge "$ACT_GAP" ]; }
trap 'kill $WATCH_PID $READER_PID 2>/dev/null; pkill -f "logcat -b main -v threadtime -T 1" 2>/dev/null; exit 0' INT TERM
echo "--- BAT DAU CANH TAB (tam dung: touch $PAUSE_FILE) ---"
LAST_ACT=0
start_reader
init_tabs
WATCH_PID=""
if [ "$ENABLE_WATCH" = "1" ]; then
    watch_visible &
    WATCH_PID=$!
fi
while true; do
    NOW=$(date +%s)
    LOOP=$((LOOP + 1))
    if [ -f "$PAUSE_FILE" ]; then
        echo "$(date +%T) [PAUSE] xoa $PAUSE_FILE de chay tiep"
        sleep "$CHECK_INTERVAL"
        continue
    fi
    if ! reader_alive; then
        echo "$(date +%T) [!] tien trinh doc log bi dung, dang mo lai"
        start_reader
        sleep "$CHECK_INTERVAL"
        continue
    fi
    LINE="$(date +%T)"
    IDX=0
    for p in $LIST_CLONE; do
        IDX=$((IDX + 1))
        PID=$(get_pid "$p")
        if [ -z "$PID" ]; then
            if act_ok; then
                restart_tab "$p" "$IDX" "app bi tat" 0
                LAST_ACT=$(date +%s)
                LINE="$LINE T$IDX:vang"
            else
                LINE="$LINE T$IDX:vang(xep-hang)"
            fi
            continue
        fi
        LT=$(rv "lt_$p" "$START")
        JT=$(ev join "$PID"); DT=$(ev disc "$PID"); HT=$(ev hb "$PID")
        STAGE=$(rv "stage_$p" 0)
        U=""; [ -f "$EV/user_$PID" ] && U=$(cat "$EV/user_$PID" 2>/dev/null | tr -d '\r\n')
        if [ -n "$U" ] && [ "$(rv "shown_$p" "")" != "$PID:$U" ]; then
            wv "shown_$p" "$PID:$U"
            echo "$(date +%T) [ACC] Tab $IDX ($p, pid $PID) = $U"
        fi
        if [ "$LAUNCH_RETRY" -gt 0 ] && [ "$(rv "resent_$p" 1)" = "0" ] && [ "$JT" -lt "$LT" ] && [ $((NOW - LT)) -ge "$LAUNCH_RETRY" ]; then
            wv "resent_$p" 1
            echo "$(date +%T) [GUI LAI LINK] Tab $IDX ($p): ${LAUNCH_RETRY}s sau khi gui link van chua thay vao game -> gui lai"
            send_join "$p"
        fi
        HBAGE=""; HBOK=0
        if [ "$HT" -gt 0 ]; then
            HBAGE=$((NOW - HT))
            if [ "$HBAGE" -le "$HB_STALE" ] && [ "$HT" -gt "$DT" ] && { [ "$STAGE" = "0" ] || [ "$HT" -gt "$LT" ]; }; then HBOK=1; fi
        fi
        if [ "$HBOK" = "1" ]; then
            wv "consec_$p" 0; wv "stage_$p" 0
            LINE="$LINE T$IDX:ok(${HBAGE}s)"
            dbg "tab$IDX $p pid=$PID user=${U:-?} state=ok hb=${HBAGE}s"
            continue
        fi
        if [ "$DT" -gt "$JT" ]; then
            KIND="bi ngat ket noi"; LIM=$DISC_WAIT
            REF=$DT; [ "$LT" -gt "$REF" ] && REF=$LT
            TAG="ngat"
        else
            KIND="chua vao game duoc"; LIM=$JOIN_GRACE
            REF=$HT; [ "$JT" -gt "$REF" ] && REF=$JT; [ "$LT" -gt "$REF" ] && REF=$LT
            TAG="cho"
        fi
        [ "$STAGE" = "1" ] && LIM=$SOFT_GRACE
        WAITED=$((NOW - REF))
        dbg "tab$IDX $p pid=$PID user=${U:-?} state=$TAG waited=${WAITED}s lim=${LIM}s stage=$STAGE join=$JT disc=$DT hb=${HBAGE:-none}"
        if [ "$WAITED" -lt "$LIM" ]; then
            LINE="$LINE T$IDX:$TAG(${WAITED}s)"
        elif ! act_ok; then
            LINE="$LINE T$IDX:xep-hang"
        elif [ "$STAGE" = "0" ]; then
            soft_push "$p" "$IDX" "$KIND ${WAITED}s"
            LAST_ACT=$(date +%s)
            LINE="$LINE T$IDX:day-lai"
        else
            restart_tab "$p" "$IDX" "$KIND (da day lai ma van ket)" 1
            LAST_ACT=$(date +%s)
            LINE="$LINE T$IDX:restart"
        fi
    done
    echo "$LINE"
    [ $((LOOP % 120)) -eq 0 ] && dbg_trim
    sleep "$CHECK_INTERVAL"
done
EOF
su -c "sh $HOME/farm.sh"
