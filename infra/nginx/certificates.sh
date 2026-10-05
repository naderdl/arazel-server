#!/bin/sh
set -eu

active=/run/nginx-selected/nginx.conf
command_timeout=900
retry_seconds=300
poll_seconds=30
renew_seconds=43200
command_kill_grace_seconds=5
production_directory=https://acme-v02.api.letsencrypt.org/directory
staging_directory=https://acme-staging-v02.api.letsencrypt.org/directory
hook='sh /opt/ingress/certificates.sh notify'

log() { printf '%s\n' "certificates: $*" >&2; }
fail() { log "$*"; exit 64; }

positive() { case "$1" in *[!0-9]*|'') return 1;; esac; [ "$1" -gt 0 ]; }
valid_directory() { printf '%s' "$1" | grep -Eq '^https://[A-Za-z0-9._~:/?&=%-]+$'; }

configure_timing() {
    case "${ACME_ENVIRONMENT:-production}" in
        lab)
            command_timeout=${CERTBOT_COMMAND_TIMEOUT_SECONDS:-900}
            retry_seconds=${CERTBOT_RETRY_SECONDS:-300}
            poll_seconds=${CERTBOT_POLL_SECONDS:-30}
            renew_seconds=${CERTBOT_RENEW_SECONDS:-43200}
            ;;
        production|staging)
            [ "${CERTBOT_COMMAND_TIMEOUT_SECONDS:-900}" = 900 ] || fail 'CERTBOT_COMMAND_TIMEOUT_SECONDS is lab-only; production and staging use 900 seconds'
            [ "${CERTBOT_RETRY_SECONDS:-300}" = 300 ] || fail 'CERTBOT_RETRY_SECONDS is lab-only'
            [ "${CERTBOT_POLL_SECONDS:-30}" = 30 ] || fail 'CERTBOT_POLL_SECONDS is lab-only'
            [ "${CERTBOT_RENEW_SECONDS:-43200}" = 43200 ] || fail 'CERTBOT_RENEW_SECONDS is lab-only'
            ;;
        *) fail 'ACME_ENVIRONMENT must be production, staging, or lab' ;;
    esac
    for value in "$command_timeout" "$retry_seconds" "$poll_seconds" "$renew_seconds"; do positive "$value" || fail 'CERTBOT timing values must be positive integers'; done
}

configure_timing

hosts() { [ -f "$active" ] && sed -n 's/^# ingress-certificate: //p' "$active" || true; }
valid_host() {
    host=$1
    [ "${#host}" -le 253 ] || return 1
    printf '%s\n' "$host" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && return 1
    printf '%s\n' "$host" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
}

validate_hosts() {
    [ -f "$active" ] || return 0
    previous=
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '# ingress-certificate: '*)
                host=${line#'# ingress-certificate: '}
                valid_host "$host" || return 1
                [ -z "$previous" ] || [ "$previous" \< "$host" ] || return 1
                previous=$host
                ;;
        esac
    done <"$active"
}

host_is_active() {
    wanted=$1
    while IFS= read -r host || [ -n "$host" ]; do
        [ "$host" = "$wanted" ] && return 0
    done <<EOF
$(hosts)
EOF
    return 1
}

select_directory() {
    ACME_ENVIRONMENT=${ACME_ENVIRONMENT:-production}
    case "$ACME_ENVIRONMENT" in
        production) default_directory=$production_directory ;;
        staging) default_directory=$staging_directory ;;
        lab) default_directory= ;;
        *) return 1 ;;
    esac
    ACME_DIRECTORY=${ACME_DIRECTORY:-$default_directory}
    valid_directory "$ACME_DIRECTORY" || return 1
    case "$ACME_ENVIRONMENT" in
        production) [ "$ACME_DIRECTORY" = "$production_directory" ] || return 1 ;;
        staging) [ "$ACME_DIRECTORY" = "$staging_directory" ] || return 1 ;;
        lab) [ -n "$ACME_DIRECTORY" ] || return 1 ;;
    esac
}

lineage_server_matches() {
    host=$1
    server=$(awk '/^server = / { if (seen) bad=1; seen=1; value=substr($0, 10) } END { if (bad || !seen) exit 1; print value }' "/etc/letsencrypt/renewal/$host.conf") || return 1
    [ "$server" = "$ACME_DIRECTORY" ]
}

check_lineage() {
    host=$1
    valid_host "$host" || return 1
    select_directory || return 1
    [ -f "/etc/letsencrypt/live/$host/fullchain.pem" ] && [ -r "/etc/letsencrypt/live/$host/fullchain.pem" ] && [ -s "/etc/letsencrypt/live/$host/fullchain.pem" ] || return 1
    [ -f "/etc/letsencrypt/live/$host/privkey.pem" ] && [ -r "/etc/letsencrypt/live/$host/privkey.pem" ] && [ -s "/etc/letsencrypt/live/$host/privkey.pem" ] || return 1
    lineage_server_matches "$host"
}

lineage_state() {
    host=$1
    valid_host "$host" || return 2
    if [ ! -e "/etc/letsencrypt/live/$host/fullchain.pem" ] && [ ! -L "/etc/letsencrypt/live/$host/fullchain.pem" ] && \
       [ ! -e "/etc/letsencrypt/live/$host/privkey.pem" ] && [ ! -L "/etc/letsencrypt/live/$host/privkey.pem" ] && \
       [ ! -e "/etc/letsencrypt/renewal/$host.conf" ] && [ ! -L "/etc/letsencrypt/renewal/$host.conf" ]; then
        return 1
    fi
    check_lineage "$host" && return 0
    return 2
}

validate_invocation() {
    ACME_EMAIL=${ACME_EMAIL:-}
    ACME_ACCEPT_TERMS=${ACME_ACCEPT_TERMS:-false}
    select_directory || fail 'ACME_ENVIRONMENT and ACME_DIRECTORY must select the matching production, staging, or explicit lab directory'
    ACME_TERMS_DIRECTORY=${ACME_TERMS_DIRECTORY:-}
    printf '%s' "$ACME_EMAIL" | grep -Eq '^[^@[:space:];]+@[^@[:space:];]+$' || fail 'ACME_EMAIL must be a non-empty mailbox'
    [ -n "$ACME_TERMS_DIRECTORY" ] || fail 'ACME_TERMS_DIRECTORY is required for explicit directory-bound consent'
    [ "$ACME_TERMS_DIRECTORY" = "$ACME_DIRECTORY" ] || fail 'ACME_TERMS_DIRECTORY must exactly match ACME_DIRECTORY'
    case "$ACME_ACCEPT_TERMS" in true|false) ;; *) fail 'ACME_ACCEPT_TERMS must be true or false';; esac
    validate_hosts || fail 'active certificate inventory must contain sorted normalized DNS hosts'
}

run_certbot() {
    if [ "$command_timeout" -gt "$command_kill_grace_seconds" ]; then
        set -- timeout -k "$command_kill_grace_seconds" "$((command_timeout - command_kill_grace_seconds))" certbot "$@"
    else
        set -- timeout -s KILL "$command_timeout" certbot "$@"
    fi
    setsid "$@" & child=$!
    if wait "$child"; then status=0; else status=$?; fi
    kill -KILL -"$child" 2>/dev/null || true
    return "$status"
}

notify() {
    mkdir -p /etc/letsencrypt
    token=$(mktemp /etc/letsencrypt/.ingress-renewed.XXXXXX)
    printf '%s %s\n' "${RENEWED_LINEAGE:-unknown}" "$(date -u +%s)" >"$token"
    mv "$token" /etc/letsencrypt/.ingress-renewed
}

issue_host() {
    host=$1
    if lineage_state "$host"; then :; else
        state=$?
        [ "$state" -eq 1 ] || { log "saved lineage for $host is incomplete or uses a different ACME directory"; return 1; }
    fi
    [ "$ACME_ACCEPT_TERMS" = true ] || { log "terms prerequisite not met for $host; no ACME account or order was attempted"; return 0; }
    run_certbot certonly --webroot --webroot-path /var/www/certbot --cert-name "$host" -d "$host" --keep-until-expiring --non-interactive --email "$ACME_EMAIL" --agree-tos --server "$ACME_DIRECTORY" --deploy-hook "$hook"
}

renew_host() {
    host=$1
    if lineage_state "$host"; then :; else
        state=$?
        [ "$state" -eq 1 ] && return 0
        log "saved lineage for $host is incomplete or uses a different ACME directory"
        return 1
    fi
    [ "$ACME_ACCEPT_TERMS" = true ] || { log "terms prerequisite not met for $host; no ACME account or order was attempted"; return 0; }
    set -- renew --cert-name "$host" --non-interactive --no-random-sleep-on-renew --server "$ACME_DIRECTORY" --deploy-hook "$hook"
    if [ "${CERTBOT_FORCE_RENEWAL:-false}" = true ]; then
        [ "$ACME_ENVIRONMENT" = lab ] || fail 'forced renewal is lab-only'
        set -- "$@" --force-renewal
    fi
    run_certbot "$@"
}

run_hosts() {
    operation=$1
    requested=$2
    [ -n "$requested" ] || { failed_hosts=; return 0; }
    inventory=$(mktemp)
    printf '%s\n' "$requested" >"$inventory"
    failed=0
    failed_hosts=
    while IFS= read -r host || [ -n "$host" ]; do
        queued_host=$host
        validate_invocation
        if ! host_is_active "$queued_host"; then
            log "skipping removed queued host $queued_host"
            continue
        fi
        if ! "$operation" "$queued_host"; then
            log "$operation failed for $queued_host"
            failed=1
            if [ -n "$failed_hosts" ]; then
                failed_hosts="$failed_hosts
$queued_host"
            else
                failed_hosts=$queued_host
            fi
        fi
    done <"$inventory"
    rm -f "$inventory"
    return "$failed"
}

attempt_host() {
    if lineage_state "$1"; then
        renew_host "$1"
    else
        state=$?
        [ "$state" -eq 1 ] || { log "saved lineage for $1 is incomplete or uses a different ACME directory"; return 1; }
        issue_host "$1"
    fi
}

issue_hosts() { run_hosts issue_host "$1"; }
renew_hosts() { run_hosts renew_host "$1"; }
issue_all() { issue_hosts "$(hosts)"; }
renew_all() { renew_hosts "$(hosts)"; }

run() {
    schedule=''
    while :; do
        validate_invocation
        now=$(date +%s)
        active_hosts=$(hosts)
        missing=''
        while IFS= read -r host || [ -n "$host" ]; do
            [ -n "$host" ] || continue
            if lineage_state "$host"; then :; else
                state=$?
                if [ "$state" -eq 1 ]; then missing="$missing $host"; fi
            fi
        done <<EOF
$active_hosts
EOF
        schedule=$(
            { printf '%s\n' "$schedule"; printf '%s\n' --; printf '%s\n' "$active_hosts"; } |
            awk -v now="$now" -v period="$renew_seconds" -v missing="$missing" '
                BEGIN { n=split(missing,names," "); for(i=1;i<=n;i++) absent[names[i]]=1 }
                $0=="--" { inventory=1; next }
                !NF { next }
                !inventory { due[$1]=$2; failed[$1]=$3; next }
                { if(!($1 in due)) due[$1]=($1 in absent ? now : now+period);
                  if(($1 in absent) && !failed[$1]) due[$1]=now;
                  print $1,due[$1],failed[$1]+0 }
            ' | LC_ALL=C sort
        )
        targets=$(printf '%s\n' "$schedule" | awk -v now="$now" 'NF && $2<=now {print $1}')
        if [ -n "$targets" ]; then
            run_hosts attempt_host "$targets" || true
            finished=$(date +%s)
            schedule=$(printf '%s\n' "$schedule" | awk -v now="$now" -v finished="$finished" -v period="$renew_seconds" -v retry="$retry_seconds" -v failures="$failed_hosts" '
                BEGIN { n=split(failures,names,"\n"); for(i=1;i<=n;i++) failed[names[i]]=1 }
                NF { if($2<=now) { $3=($1 in failed); $2=finished+($3 ? retry : period) } print }
            ')
        fi
        sleep "$poll_seconds"
    done
}

case "${1:-run}" in
    run) run ;;
    renew) validate_invocation; renew_all ;;
    notify) notify ;;
    check-lineage) [ "$#" -eq 2 ] || exit 64; check_lineage "$2" ;;
    *) printf '%s\n' 'usage: certificates.sh {run|renew|notify|check-lineage <normalized-host>}' >&2; exit 64 ;;
esac
