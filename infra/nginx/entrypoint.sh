#!/bin/sh
set -eu

state=/run/nginx-config
selected=/run/nginx-selected/nginx.conf
ready=$state/.controller-ready
wait_seconds=${NGINX_CONTROLLER_WAIT_SECONDS:-45}
log() { printf '%s\n' "ingress bootstrap: $*" >&2; }
case "$wait_seconds" in *[!0-9]*|'') exit 64;; esac
[ "$wait_seconds" -gt 0 ] || exit 64
mkdir -p /run/nginx-runtime /var/www/certbot
incarnation="$(cat /proc/sys/kernel/random/boot_id):$(awk '{print $22}' /proc/1/stat)"
deadline=$(( $(date +%s) + wait_seconds ))
while :; do
    ready_identity= ready_at=
    [ -s "$ready" ] && read -r ready_identity ready_at _ <"$ready" || true
    now=$(date +%s)
    if [ "$ready_identity" = "$incarnation" ] && [ "${ready_at:-0}" -le "$now" ] && [ "$((now - ${ready_at:-0}))" -le 35 ] && [ -s "$selected" ] && nginx -t -c "$selected"; then
        break
    fi
    [ "$now" -lt "$deadline" ] || { log 'fresh validated controller root was not available'; exit 64; }
    sleep 1
done
if grep -q '^# ingress-stream: ' "$selected"; then /usr/local/sbin/arazel-transparent-routing request-readiness || { log 'fresh transparent-routing readiness failed'; exit 64; }; fi
if [ "${1:-}" = nginx ]; then shift; exec nginx -c "$selected" "$@"; fi
exec "$@"
