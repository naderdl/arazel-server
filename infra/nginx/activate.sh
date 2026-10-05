#!/bin/sh
set -eu

state=/run/nginx-config/.certificate-state
pending=/run/nginx-config/.certificate-pending
lock=/run/nginx-config/.activate.lock
config=/run/nginx-selected/nginx.conf
runtime=/run/nginx-runtime
notice=${NGINX_MASTER_RUNTIME:-$runtime}/nginx-notice.log
lineage=/opt/ingress/certificates.sh
source_default=/run/nginx-config/discovery.conf
snapshot=

log() { printf '%s\n' "ingress activate: $*" >&2; }
fail() { log "$*"; return 1; }
hosts_from() { [ -f "$1" ] && sed -n 's/^# ingress-certificate: //p' "$1" || true; }
valid_hosts() {
    while IFS= read -r host || [ -n "$host" ]; do
        [ "$(printf %s "$host" | wc -c)" -le 253 ] || return 1
        printf '%s\n' "$host" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' && return 1
        printf '%s\n' "$host" | grep -Ex '[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$' >/dev/null || return 1
    done <"$1"
    [ "$(cat "$1")" = "$(LC_ALL=C sort -u "$1")" ]
}
lineage_ready() { "$lineage" check-lineage "$1"; }
master_identity() { printf '%s %s\n' "$(cat /proc/sys/kernel/random/boot_id)" "$(awk '{print $22}' /proc/1/stat)"; }
current_has_host() {
    [ -f "$state" ] || return 1
    [ "$(awk 'NR == 2 {print; exit}' "$state")" = "$(master_identity)" ] || return 1
    awk 'NR > 2 {print}' "$state" | grep -Fx "$1" >/dev/null
}
record_loaded() {
    fingerprint=$1
    { printf '%s\n' "$fingerprint"; master_identity; cat "$snapshot/ready"; } >"$state.tmp" && mv "$state.tmp" "$state"
}
valid_huginn_usersfile() {
    [ "$(id -u nginx)" = 101 ] && [ "$(id -g nginx)" = 101 ] || return 1
    [ -f /etc/nginx/usersfile ] && [ -s /etc/nginx/usersfile ] || return 1
    su -s /bin/sh nginx -c 'test -r /etc/nginx/usersfile' || return 1
    awk -F: 'NF == 0 { next } NF == 2 && $1 ~ /^[^:[:space:]]+$/ && $2 ~ /^\$2[aby]\$(0[4-9]|[12][0-9]|3[01])\$[.\/A-Za-z0-9]{53}$/ { entries++; next } { invalid=1; exit } END { exit invalid || !entries }' /etc/nginx/usersfile
}
lineage_paths() {
    cert_path=$(readlink -f "/etc/letsencrypt/live/$1/fullchain.pem") || return 1
    key_path=$(readlink -f "/etc/letsencrypt/live/$1/privkey.pem") || return 1
    [ "${cert_path%/*}" = "/etc/letsencrypt/archive/$1" ] || return 1
    version=${cert_path##*/}; version=${version#fullchain}; version=${version%.pem}
    case "$version" in *[!0-9]*|'') return 1;; esac
    [ "$key_path" = "/etc/letsencrypt/archive/$1/privkey$version.pem" ]
}
cleanup_snapshot() { [ -z "$snapshot" ] || rm -rf "$snapshot"; snapshot=; }

validate_routes() {
    route_file=$1
    : >"$snapshot/http-routes"
    : >"$snapshot/stream-routes"
    awk '/^# ingress-http: / { sub(/^# ingress-http: /, ""); print }' "$route_file" | LC_ALL=C sort >"$snapshot/http-routes"
    awk '/^# ingress-stream: / { sub(/^# ingress-stream: /, ""); print }' "$route_file" | LC_ALL=C sort >"$snapshot/stream-routes"
    while IFS='|' read -r host address port auth extra || [ -n "$host$address$port$auth$extra" ]; do
        [ -n "$host" ] || continue
        [ -z "$extra" ] && printf '%s\n' "$host" | grep -Fx -f "$snapshot/hosts" >/dev/null || return 1
        printf '%s\n' "$address" | grep -Ex '[0-9]{1,3}(\.[0-9]{1,3}){3}' >/dev/null || return 1
        printf '%s\n' "$port" | grep -Eq '^[1-9][0-9]{0,4}$' && [ "$port" -le 65535 ] || return 1
        case "$auth" in none|huginn) ;; *) return 1;; esac
        [ "$auth" != huginn ] || valid_huginn_usersfile || return 1
    done <"$snapshot/http-routes"
    [ "$(wc -l <"$snapshot/http-routes")" -eq "$(wc -l <"$snapshot/hosts")" ] || return 1
    if [ -s "$snapshot/stream-routes" ]; then
        while IFS='|' read -r protocol listen address backend extra || [ -n "$protocol$listen$address$backend$extra" ]; do
            [ -n "$protocol" ] || continue
            [ -z "$extra" ] || return 1
            printf '%s\n' "$address" | grep -Ex '[0-9]{1,3}(\.[0-9]{1,3}){3}' >/dev/null || return 1
            case "$protocol:$listen:$backend" in
                udp:9987:9987|tcp:30033:30033|udp:2456:2456|udp:2457:2457|udp:2458:2458) ;;
                *) return 1 ;;
            esac
        done <"$snapshot/stream-routes"
        /usr/local/sbin/arazel-transparent-routing request-readiness || { fail 'fresh transparent-routing readiness failed'; return 1; }
        :
    fi
}

make_snapshot() {
    mode=$1 source=$2
    snapshot=$(mktemp -d /run/nginx-config/.activate.XXXXXX) || return 1
    [ -f "$source" ] && cp "$source" "$snapshot/source" || : >"$snapshot/source"
    hosts_from "$snapshot/source" >"$snapshot/hosts"
    validate_routes "$snapshot/source" || { fail 'candidate route inventory is malformed'; return 1; }
    : >"$snapshot/ready"; : >"$snapshot/unready"
    while IFS= read -r host || [ -n "$host" ]; do
        if lineage_ready "$host"; then
            mkdir -p "$snapshot/certificates/$host"
            lineage_paths "$host" || { fail "certificate publication for $host does not name one immutable Certbot archive generation"; return 1; }
            printf '%s\n' "$cert_path" >"$snapshot/certificates/$host/fullchain.path"
            printf '%s\n' "$key_path" >"$snapshot/certificates/$host/privkey.path"
            sha256sum "$cert_path" "$key_path" >"$snapshot/certificates/$host/hashes" || return 1
            lineage_ready "$host" || { fail "certificate publication for $host changed while being read"; return 1; }
            printf '%s\n' "$host" >>"$snapshot/ready"
        elif [ "$mode" != bootstrap ] && current_has_host "$host"; then
            fail "certificate publication for $host is incomplete or untrusted; retaining current workers"; return 1
        else printf '%s\n' "$host" >>"$snapshot/unready"; fi
    done <"$snapshot/hosts"
}

http_servers() {
    while IFS='|' read -r host address port auth; do [ -n "$host" ] || continue; cat <<EOF
    server {
        listen 80;
        server_name $host;
        location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; default_type text/plain; try_files \$uri =404; auth_basic off; }
        location / { return 308 https://$host\$request_uri; }
    }
EOF
done <"$snapshot/http-routes"
}
https_servers() {
    while IFS='|' read -r host address port auth; do
        grep -Fx "$host" "$snapshot/ready" >/dev/null || continue
        cert_path=$(cat "$snapshot/certificates/$host/fullchain.path"); key_path=$(cat "$snapshot/certificates/$host/privkey.path")
        auth_block=''
        [ "$auth" != huginn ] || auth_block='auth_basic "Huginn"; auth_basic_user_file /etc/nginx/usersfile;'
        cat <<EOF
    server {
        listen 443 ssl;
        server_name $host;
        ssl_certificate $cert_path;
        ssl_certificate_key $key_path;
        if (\$ssl_server_name !~* "^\\Q$host\\E\$") { return 421; }
        location / {
            $auth_block
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-Host \$host;
            proxy_set_header X-Forwarded-Proto https;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header Forwarded "";
            proxy_set_header X-Forwarded-Port 443;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_pass http://$address:$port;
        }
    }
EOF
done <"$snapshot/http-routes"
}
stream_servers() {
    while IFS='|' read -r protocol listen address backend; do
        [ -n "$protocol" ] || continue
        case "$protocol" in udp) proto=' udp'; timeout='proxy_timeout 2m;';; tcp) proto=''; timeout='proxy_timeout 30s;';; *) return 1;; esac
        cat <<EOF
    server {
        listen $listen$proto;
        proxy_connect_timeout 5s;
        $timeout
        proxy_bind \$remote_addr:\$remote_port transparent;
        proxy_pass $address:$backend;
    }
EOF
    done <"$snapshot/stream-routes"
}
render() {
    http_servers >"$snapshot/http"; https_servers >"$snapshot/https"; stream_servers >"$snapshot/stream"
    umask 077
    awk -v source="$snapshot/source" -v http="$snapshot/http" -v https="$snapshot/https" -v stream="$snapshot/stream" '
        /__INGRESS_RECORDS__/ { while ((getline line < source) > 0) if (line ~ /^# ingress-/) print line; close(source); next }
        /__HTTP_SERVERS__/ { while ((getline line < http) > 0) print line; close(http); next }
        /__HTTPS_SERVERS__/ { while ((getline line < https) > 0) print line; close(https); next }
        /__STREAM_SERVERS__/ { while ((getline line < stream) > 0) print line; close(stream); next }
        { print }
    ' /opt/ingress/nginx.conf.tmpl >"$snapshot/root.conf"
}
candidate_fingerprint() { { printf 'candidate '; sha256sum "$snapshot/root.conf" | awk '{print $1}'; while IFS= read -r host || [ -n "$host" ]; do printf 'certificate pair %s\n' "$host"; cat "$snapshot/certificates/$host/hashes"; done <"$snapshot/ready"; } | sha256sum | awk '{print $1}'; }
snapshot_consistent() {
    [ -f "$source" ] && cmp -s "$snapshot/source" "$source" || { [ ! -f "$source" ] && [ ! -s "$snapshot/source" ]; } || return 1
    while IFS= read -r host || [ -n "$host" ]; do lineage_ready "$host" && lineage_paths "$host" || return 1; [ "$cert_path" = "$(cat "$snapshot/certificates/$host/fullchain.path")" ] && [ "$key_path" = "$(cat "$snapshot/certificates/$host/privkey.path")" ] || return 1; sha256sum -c "$snapshot/certificates/$host/hashes" >/dev/null || return 1; done <"$snapshot/ready"
    while IFS= read -r host || [ -n "$host" ]; do ! lineage_ready "$host" || return 1; done <"$snapshot/unready"
}
master_pid() { command=$(tr '\000' ' ' </proc/1/cmdline 2>/dev/null || true); case "$command" in 'nginx: master process'*) printf '1\n';; *) return 1;; esac; }
notice_size() { [ -f "$notice" ] && wc -c <"$notice" || printf 0; }
wait_for_reload() { master=$1 offset=$2; kill -HUP "$master" || return 1; i=0; while [ "$i" -lt 20 ]; do [ "$(master_pid 2>/dev/null || true)" = "$master" ] || return 1; messages=$(tail -c "+$((offset + 1))" "$notice" 2>/dev/null || true); if printf '%s\n' "$messages" | grep -Eq 'signal [0-9]+ \(SIGHUP\) received.*reconfiguring' && printf '%s\n' "$messages" | grep -Eq 'start worker processes'; then worker=$(printf '%s\n' "$messages" | sed -n 's/.*start worker process \([0-9][0-9]*\).*/\1/p' | tail -n 1); [ -n "$worker" ] && pgrep -P "$master" | grep -Fx "$worker" >/dev/null && return 0; fi; sleep 1; i=$((i + 1)); done; return 1; }
activate() {
    mode=$1; source=$2; status=0; make_snapshot "$mode" "$source" || status=1
    if [ "$status" -eq 0 ]; then render || status=1; fi
    if [ "$status" -eq 0 ]; then wanted=$(candidate_fingerprint); applied=$(head -n 1 "$state" 2>/dev/null || true)
        if [ "$mode" != bootstrap ] && [ ! -e "$pending" ] && [ "$wanted" = "$applied" ] && snapshot_consistent; then :
        elif ! nginx -t -c "$snapshot/root.conf"; then status=1
        elif ! snapshot_consistent; then log 'candidate changed before configuration selection'; status=1
        else master=$(master_pid 2>/dev/null || true); offset=$(notice_size); printf '%s\n' "$wanted" >"$pending.tmp"; mv "$pending.tmp" "$pending"; mv "$snapshot/root.conf" "$config"
            if [ -z "$master" ]; then [ "$mode" = bootstrap ] || { log 'configuration selected; awaiting stable NGINX master'; status=1; }
            elif ! wait_for_reload "$master" "$offset"; then log 'NGINX reload acknowledgement failed; state was not recorded'; status=1
            else
                record_loaded "$wanted" || { log 'NGINX reload acknowledgement could not record loaded membership'; status=1; }
                if [ "$status" -eq 0 ] && ! snapshot_consistent; then log 'candidate changed during reload; loaded membership retained while newer inputs remain pending'; status=1
                elif [ "$status" -eq 0 ]; then rm -f "$pending"; log "activated certificate/configuration fingerprint $wanted"; fi
            fi
        fi
    fi
    cleanup_snapshot; return "$status"
}
run_locked() { mode=$1 source=$2; if flock -n -E 75 "$lock" "$0" locked "$mode" "$source"; then return 0; else status=$?; fi; [ "$status" -eq 75 ] && log 'another activation transaction is active'; return "$status"; }
case "${1:-}" in
 bootstrap) run_locked bootstrap "${2:-$source_default}" ;;
 activate) run_locked normal "${2:-$source_default}" ;;
 locked) activate "$2" "$3" ;;
 *) printf '%s\n' 'usage: activate.sh {bootstrap|activate} [candidate]' >&2; exit 64 ;;
esac
