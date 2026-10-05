#!/bin/sh
set -eu

config=/run/nginx-config
candidate=$config/discovery.conf
ready=$config/.controller-ready
watch=/etc/docker-gen/docker-gen.cfg
interval=${CONTROLLER_RECONCILE_SECONDS:-30}

log() { printf '%s\n' "ingress controller: $*" >&2; }
case "$interval" in *[!0-9]*|'') exit 64;; esac
[ "$interval" -le 30 ] && [ "$interval" -gt 0 ] || { log 'CONTROLLER_RECONCILE_SECONDS must be 1..30'; exit 64; }

docker_url() { printf '%s' "${DOCKER_HOST:-unix:///var/run/docker.sock}" | sed -e 's#^tcp://#http://#' -e 's#^unix://.*#http://localhost#'; }
metadata_available() {
    base=$(docker_url)
    case "$base" in http://localhost) return 1;; esac
    curl --fail --silent --show-error --max-time 5 "$base/version" >/dev/null && curl --fail --silent --show-error --max-time 5 "$base/containers/json?all=1" >/dev/null
}
render() {
    metadata_available || { log 'Docker metadata is unavailable'; return 1; }
    umask 077
    stage=$(mktemp "$config/.discovery-stage.XXXXXX") || return 1
    stage_config=$(mktemp "$config/.docker-gen-stage.XXXXXX") || { rm -f "$stage"; return 1; }
    stage_log=$(mktemp "$config/.docker-gen-log.XXXXXX") || { rm -f "$stage" "$stage_config"; return 1; }
    printf '[[config]]\ntemplate = "/etc/docker-gen/discovery.tmpl"\ndest = "%s"\nwatch = false\n' "$stage" >"$stage_config"
    # docker-gen 0.17.2 returns zero after failed inspections; any diagnostic beyond its fresh-render completion rejects the whole snapshot.
    if docker-gen -config "$stage_config" >"$stage_log" 2>&1 &&
        awk -v path="'$stage'" '
            NF == 7 && $3 == "Generated" && $4 == path && $5 == "from" && $6 ~ /^[0-9]+$/ && $7 == "containers" { complete++; next }
            { invalid=1 }
            END { exit !(complete == 1 && !invalid) }
        ' "$stage_log" &&
        [ -s "$stage" ] && grep -Fx '# ingress-discovery: v1' "$stage" >/dev/null; then
        rm -f "$stage_config" "$stage_log"
        mv "$stage" "$candidate"
    else
        rm -f "$stage" "$stage_config" "$stage_log"
        log 'docker-gen metadata retrieval/render did not complete cleanly; no snapshot published'
        return 1
    fi
}
activate() {
    [ -s "$candidate" ] || { log 'discovery has not emitted a candidate'; return 1; }
    /usr/local/sbin/activate.sh activate "$candidate"
}
mark_ready() {
    nginx -t -c /run/nginx-selected/nginx.conf >/dev/null
    tmp=$(mktemp "$config/.controller-ready.XXXXXX")
    printf '%s:%s %s %s\n' "$(cat /proc/sys/kernel/random/boot_id)" "$(awk '{print $22}' /proc/1/stat)" "$(date +%s)" "$(sha256sum "$candidate" | awk '{print $1}')" >"$tmp"
    mv "$tmp" "$ready"
}
bootstrap() {
    rm -f "$ready"
    render || return 1
    command=$(tr '\000' ' ' </proc/1/cmdline 2>/dev/null || true)
    case "$command" in 'nginx: master process'*) /usr/local/sbin/activate.sh activate "$candidate" ;; *) /usr/local/sbin/activate.sh bootstrap "$candidate" ;; esac || return 1
    mark_ready || return 1
}
periodic() {
    while sleep "$interval"; do
        if render && activate; then mark_ready || log 'selected root is no longer valid'; else log 'reconciliation rejected; retaining current workers'; fi
    done
}
watch_forever() {
    while :; do
        docker-gen -config "$watch" || log 'docker-gen watcher exited after a rejected discovery snapshot; retrying'
        sleep 1
    done
}
case "${1:-run}" in
    run) periodic & while ! bootstrap; do log 'initial discovery snapshot rejected; retrying'; sleep 1; done; watch_forever ;;
    activate) render && activate && mark_ready ;;
    *) printf '%s\n' 'usage: controller.sh {run|activate}' >&2; exit 64 ;;
esac
