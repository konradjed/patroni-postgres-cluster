#!/usr/bin/env bash
#
# test-system-crash.sh — kill -9 na Patronim, harness loguje co się dzieje.
# Opis, wymagania i czytanie wyniku: scripts/README.md
#
set -euo pipefail


NODES="192.168.172.101 192.168.172.102 192.168.172.103"   # węzły klastra
API_PORT=8008                       # REST API Patroniego
UNIT=percona-patroni                # unit systemd do zabicia
SSH_USER=user                       # konto SSH na węzłach (potrzebuje NOPASSWD)

BASELINE=30                         # sekundy zapisów przed ciosem
OBSERVE=90                          # sekundy obserwacji po ciosie
SNAPSHOT=5                          # co ile sekund wpis w fazie obserwacji
INTERVAL_MS=500                     # odstęp między zapisami harnessu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LOGFILE=$ROOT/patroni-proc-failed.log
HARNESS=$ROOT/harness/bin/Debug/net10.0/NpgsqlFailoverLab
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5"

# ══════════════════════════════════════════════════════════════════════════════

SUDO="sudo -n"
[ "$SSH_USER" = root ] && SUDO=""

: > "$LOGFILE"
TTY=/dev/null; [ -w /dev/tty ] && TTY=/dev/tty
RULE='──────────────────────────────────────────────────────────────────────────────'

log()  { printf '%s\n' "$*" | tee -a "$LOGFILE"; }
die()  { log "  x $*"; exit 1; }
T0=$(date +%s.%N)
step() { log "$(printf '[%6ss] %s' "$(awk -v a="$(date +%s.%N)" -v b="$T0" 'BEGIN{printf "%.1f",a-b}')" "$*")"; }

rsh()    { ssh $SSH_OPTS "$SSH_USER@$1" "${@:2}"; }
health() { curl -sf -o /dev/null -m 3 "http://$1:$API_PORT/$2"; }
wrote()  { awk '$2=="W" && $5=="OK"{f=1;exit} END{exit !f}' "$LOGFILE" 2>/dev/null; }


# Odlicza $1 sekund. Licznik idzie tylko na terminal, do logu jeden wiersz.
wait_30s() {
    local left=${1:-30}
    step "${2:-Czekam}: ${left}s…"
    while [ "$left" -gt 0 ]; do
        printf '\r  %3ds ' "$left" > "$TTY"
        sleep 1
        left=$((left - 1))
    done
    printf '\r      \r' > "$TTY"
}

# Odpytuje wszystkie węzły i ustawia:
#   CLUSTER_LINE — role w jednym wierszu
#   PRIMARY_NOW  — adres aktualnego lidera albo "-", gdy klaster go nie ma
# Zwraca przez zmienne, a nie przez echo, bo $(...) odpala podpowłokę
# i przypisania ze środka nie wróciłyby tutaj.
scan_cluster() {
    local h role
    CLUSTER_LINE=""; PRIMARY_NOW="-"
    for h in $NODES; do
        if   health "$h" primary; then role=primary; PRIMARY_NOW=$h
        elif health "$h" replica; then role=replica
        else role=down
        fi
        CLUSTER_LINE+="$h=$role  "
    done
}

HPID=""
stop_harness() {
    [ -n "$HPID" ] && kill -0 "$HPID" 2>/dev/null || return 0
    kill -INT "$HPID" 2>/dev/null || true
    wait "$HPID" 2>/dev/null || true
    HPID=""
}
trap stop_harness EXIT INT TERM


main() {
    log "$RULE"
    log "Patroni — kill -9 na procesie Patroniego (lider)"
    log "  start   : $(date '+%Y-%m-%d %H:%M:%S')"
    log "  klaster : $NODES"
    log "  log     : $LOGFILE"
    log "$RULE"
    log ""

    # 1. kto jest liderem
    scan_cluster
    LEADER=$PRIMARY_NOW
    [ "$LEADER" != "-" ] || die "Żaden węzeł nie zgłasza się jako primary na :$API_PORT."
    step "PRIMARY: $LEADER"
    log "      $CLUSTER_LINE"

    MAINPID=$(rsh "$LEADER" "systemctl show -p MainPID --value $UNIT") \
        || die "Nie mogę odczytać PID z $LEADER (SSH albo systemctl)."
    [ "${MAINPID:-0}" -gt 0 ] 2>/dev/null || die "$UNIT nie ma żywego procesu."
    step "$UNIT na $LEADER: PID $MAINPID"

    # 2. harness
    log ""
    step "Start harnessu (zapis co ${INTERVAL_MS} ms)"
    [ -x "$HARNESS" ] || dotnet build "$ROOT/harness" -c Debug --nologo -v q >/dev/null \
        || die "dotnet build nie przeszedł."
    ( cd "$ROOT/harness"; PG_INTERVAL_MS=$INTERVAL_MS exec "$HARNESS" --log "$LOGFILE" ) \
        >/dev/null 2>>"$LOGFILE" &
    HPID=$!
    for _ in $(seq 120); do wrote && break; sleep 0.5; done
    wrote || die "Harness nie wykonał żadnego zapisu — sprawdź połączenie do bazy."
    wait_30s "$BASELINE" "Zapisy przed ciosem"

    # 3. cios
    log ""
    log "$RULE"
    TK=$(date +%s.%N)
    step "SIGKILL -> PID $MAINPID ($UNIT na $LEADER)"
    rsh "$LEADER" "$SUDO kill -9 $MAINPID" || true
    sleep 2
    [ "$(rsh "$LEADER" "systemctl show -p MainPID --value $UNIT" 2>/dev/null || echo 0)" = "$MAINPID" ] \
        && log "  ! Patroni wciąż działa jako PID $MAINPID — cios nie doszedł, sprawdź NOPASSWD"
    log "$RULE"

    # 4. obserwacja
    log ""
    step "Obserwacja: ${OBSERVE}s"
    local end icmp seen=$LEADER
    end=$(( $(date +%s) + OBSERVE ))
    while [ "$(date +%s)" -lt "$end" ]; do
        icmp=down; ping -c1 -W1 "$LEADER" >/dev/null 2>&1 && icmp=up
        scan_cluster
        if [ "$PRIMARY_NOW" != "$seen" ]; then
            step "*** LIDER: $seen -> $PRIMARY_NOW   (+$(awk -v a="$(date +%s.%N)" -v b="$TK" \
                 'BEGIN{printf "%.1f",a-b}')s od ciosu)"
            seen=$PRIMARY_NOW
        fi
        step "$LEADER ICMP:$icmp | $CLUSTER_LINE"
        sleep "$SNAPSHOT"
    done

    # 5. koniec
    log ""
    step "SIGINT -> harness"
    stop_harness
    log ""
    log "$RULE"
    scan_cluster
    step "Stan końcowy: $CLUSTER_LINE"
    log "  Log: $LOGFILE"
    log "$RULE"
}

main "$@"
