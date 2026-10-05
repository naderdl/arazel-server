#!/usr/bin/env bash
set -euo pipefail

readonly RUNTIME_DIR=/run/arazel-ingress
readonly REQUEST_FIFO="$RUNTIME_DIR/readiness.fifo"
readonly RESPONSE_FILE="$RUNTIME_DIR/readiness.response"
readonly REQUEST_LOCK="$RUNTIME_DIR/readiness.lock"
readonly OWNER_COMMENT=arazel-ingress
readonly MARK=0x7cf3
readonly RULE_PRIORITY=31087
readonly ROUTING_TABLE=31987
readonly TS6_LOGICAL_NETWORK=ingress-ts6
readonly VALHEIM_LOGICAL_NETWORK=ingress-valheim
case "${INGRESS_ENVIRONMENT:-production}" in
    production)
        for setting in INGRESS_LAB_NETWORK_PREFIX INGRESS_LAB_TS6_BRIDGE INGRESS_LAB_VALHEIM_BRIDGE INGRESS_LAB_TS6_SUBNET INGRESS_LAB_VALHEIM_SUBNET; do
            [ -z "${!setting:-}" ] || { printf 'arazel transparent routing: %s is lab-only\n' "$setting" >&2; exit 64; }
        done
        readonly TS6_NETWORK=$TS6_LOGICAL_NETWORK
        readonly VALHEIM_NETWORK=$VALHEIM_LOGICAL_NETWORK
        ;;
    lab)
        [[ ${INGRESS_LAB_NETWORK_PREFIX:-} =~ ^[a-z0-9][a-z0-9-]{0,40}-$ ]] || { printf '%s\n' 'arazel transparent routing: INGRESS_LAB_NETWORK_PREFIX must be a safe trailing-dash prefix in lab' >&2; exit 64; }
        readonly TS6_NETWORK="${INGRESS_LAB_NETWORK_PREFIX}${TS6_LOGICAL_NETWORK}"
        readonly VALHEIM_NETWORK="${INGRESS_LAB_NETWORK_PREFIX}${VALHEIM_LOGICAL_NETWORK}"
        [[ ${INGRESS_LAB_TS6_BRIDGE:-az-ts6} =~ ^az-[a-z0-9-]{1,12}$ && ${INGRESS_LAB_VALHEIM_BRIDGE:-az-valheim} =~ ^az-[a-z0-9-]{1,12}$ ]] || { printf '%s\n' 'arazel transparent routing: lab bridges must be safe az- names of at most 15 bytes' >&2; exit 64; }
        ;;
    *)
        printf '%s\n' 'arazel transparent routing: INGRESS_ENVIRONMENT must be production or lab' >&2
        exit 64
        ;;
esac
readonly TS6_BRIDGE=${INGRESS_LAB_TS6_BRIDGE:-az-ts6}
readonly VALHEIM_BRIDGE=${INGRESS_LAB_VALHEIM_BRIDGE:-az-valheim}
readonly TS6_SUBNET=${INGRESS_LAB_TS6_SUBNET:-172.29.87.0/24}
readonly VALHEIM_SUBNET=${INGRESS_LAB_VALHEIM_SUBNET:-172.29.88.0/24}
readonly OWNED_RULE_PATTERN="^$RULE_PRIORITY: from all fwmark 0x7cf3(/0xffffffff)? lookup $ROUTING_TABLE$"
readonly NAT_CHAIN=ARAZEL_INGRESS_NAT
readonly MANGLE_CHAIN=ARAZEL_INGRESS_MANGLE

fail() {
    printf '%s\n' "arazel transparent routing: $*" >&2
    return 1
}

require_root() {
    [ "$(id -u)" -eq 0 ] || fail 'root is required'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

ip_to_integer() {
    local address=$1 a b c d
    IFS=. read -r a b c d <<<"$address"
    [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ && $c =~ ^[0-9]+$ && $d =~ ^[0-9]+$ ]] || return 1
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
    printf '%s\n' "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}

cidr_bounds() {
    local cidr=$1 address prefix value mask start end
    address=${cidr%/*}
    prefix=${cidr#*/}
    [[ $cidr == */* && $prefix =~ ^[0-9]+$ ]] && (( prefix <= 32 )) || return 1
    value=$(ip_to_integer "$address") || return 1
    if (( prefix == 0 )); then
        start=0
        end=4294967295
    else
        mask=$(( (4294967295 << (32 - prefix)) & 4294967295 ))
        start=$(( value & mask ))
        end=$(( start | (4294967295 ^ mask) ))
    fi
    printf '%s %s\n' "$start" "$end"
}

cidrs_overlap() {
    local first second first_start first_end second_start second_end
    first=$(cidr_bounds "$1") || return 1
    second=$(cidr_bounds "$2") || return 1
    read -r first_start first_end <<<"$first"
    read -r second_start second_end <<<"$second"
    (( first_start <= second_end && second_start <= first_end ))
}

if [ "${INGRESS_ENVIRONMENT:-production}" = lab ]; then
    if [ "$TS6_BRIDGE" = "$VALHEIM_BRIDGE" ] || ! cidr_bounds "$TS6_SUBNET" >/dev/null || ! cidr_bounds "$VALHEIM_SUBNET" >/dev/null || cidrs_overlap "$TS6_SUBNET" "$VALHEIM_SUBNET"; then
        printf '%s\n' 'arazel transparent routing: lab game bridges and valid IPv4 subnets must be distinct' >&2
        exit 64
    fi
fi

network_subnets() {
    local network networks
    networks=$(docker network ls -q) || return 1
    while IFS= read -r network; do
        [ -n "$network" ] || continue
        docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' "$network" || return 1
    done <<<"$networks"
}

host_route_subnets() {
    ip -o -4 route show table all | awk '{print $1}' | while IFS= read -r route; do
        case "$route" in
            default|broadcast|local|unreachable|prohibit|throw|blackhole) continue ;;
        esac
        if [[ $route =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
            [[ $route == */* ]] || route="$route/32"
            printf '%s\n' "$route"
        fi
    done
}

assert_subnet_available() {
    local candidate=$1 existing docker_subnets host_subnets
    docker_subnets=$(network_subnets) || { fail 'Docker subnet inventory is unavailable'; return 1; }
    host_subnets=$(host_route_subnets) || { fail 'host route inventory is unavailable'; return 1; }
    while IFS= read -r existing; do
        [ -n "$existing" ] || continue
        if cidrs_overlap "$candidate" "$existing"; then
            fail "requested subnet $candidate overlaps existing Docker subnet $existing"
            return 1
        fi
    done <<<"$docker_subnets"
    while IFS= read -r existing; do
        [ -n "$existing" ] || continue
        if cidrs_overlap "$candidate" "$existing"; then
            fail "requested subnet $candidate overlaps host or VPN route $existing"
            return 1
        fi
    done <<<"$host_subnets"
}

network_value() {
    docker network inspect --format "$2" "$1"
}

verify_network() {
    local network=$1 bridge=$2 subnet=$3 driver actual_bridge actual_subnet masquerade owner
    driver=$(network_value "$network" '{{.Driver}}')
    actual_bridge=$(network_value "$network" '{{index .Options "com.docker.network.bridge.name"}}')
    actual_subnet=$(network_value "$network" '{{(index .IPAM.Config 0).Subnet}}')
    masquerade=$(network_value "$network" '{{index .Options "com.docker.network.bridge.enable_ip_masquerade"}}')
    owner=$(network_value "$network" '{{index .Labels "com.arazel.ingress.network"}}')
    [ "$driver" = bridge ] || { fail "$network is not a bridge network"; return 1; }
    [ "$actual_bridge" = "$bridge" ] || { fail "$network bridge is $actual_bridge, expected $bridge"; return 1; }
    [ "$actual_subnet" = "$subnet" ] || { fail "$network subnet is $actual_subnet, expected $subnet"; return 1; }
    [ "$masquerade" = true ] || { fail "$network disables ordinary bridge masquerading"; return 1; }
    [ "$owner" = "$network" ] || { fail "$network is not owned by Arazel ingress"; return 1; }
}

ensure_network() {
    local network=$1 bridge=$2 subnet=$3
    if docker network inspect "$network" >/dev/null 2>&1; then
        verify_network "$network" "$bridge" "$subnet" || return 1
        return
    fi
    assert_subnet_available "$subnet" || return 1
    docker network create \
        --driver bridge \
        --subnet "$subnet" \
        --opt "com.docker.network.bridge.name=$bridge" \
        --opt com.docker.network.bridge.enable_ip_masquerade=true \
        --label "com.arazel.ingress.network=$network" \
        "$network" >/dev/null || return 1
    verify_network "$network" "$bridge" "$subnet" || return 1
}

setup() {
    require_root || return 1
    require_command docker || return 1
    require_command ip || return 1
    ensure_network "$TS6_NETWORK" "$TS6_BRIDGE" "$TS6_SUBNET" || return 1
    ensure_network "$VALHEIM_NETWORK" "$VALHEIM_BRIDGE" "$VALHEIM_SUBNET" || return 1
}

verify_firewall_backend() {
    local version
    require_command iptables || return 1
    require_command nft || return 1
    iptables -t nat -S POSTROUTING >/dev/null || return 1
    iptables -t mangle -S PREROUTING >/dev/null || return 1
    version=$(iptables -V) || return 1
    [[ $version == *nf_tables* ]] || { fail "unsupported iptables backend: $version (iptables-nft is required)"; return 1; }
    nft list chain ip nat POSTROUTING | grep -Eq 'type nat hook postrouting priority (srcnat|100)' \
        || fail 'nat POSTROUTING hook priority is not srcnat'
}

verify_mangle_hook() {
    nft list chain ip mangle PREROUTING | grep -Eq 'type filter hook prerouting priority (mangle|-150)' \
        || fail 'mangle PREROUTING hook priority is not mangle'
}

assert_bridge() {
    ip link show dev "$1" >/dev/null 2>&1 || fail "required bridge is unavailable: $1"
}

assert_normal_masquerading() {
    local subnet=$1 bridge=$2
    iptables -t nat -S | grep -F -- "-s $subnet" | grep -F -- "! -o $bridge" | grep -F -- '-j MASQUERADE' >/dev/null \
        || fail "ordinary Docker masquerading is unavailable for $bridge"
}

assert_sysctls() {
    local bridge
    [ "$(sysctl -n net.ipv4.ip_forward)" = 1 ] || { fail 'IPv4 forwarding is disabled'; return 1; }
    [ "$(sysctl -n net.ipv4.conf.all.rp_filter)" = 0 ] \
        || { fail 'global rp_filter is enabled; refusing to widen global routing policy'; return 1; }
    for bridge in "$TS6_BRIDGE" "$VALHEIM_BRIDGE"; do
        [ "$(sysctl -n "net.ipv4.conf.$bridge.rp_filter")" = 0 ] \
            || { fail "rp_filter is enabled on $bridge"; return 1; }
    done
}

configure_bridge_sysctls() {
    local bridge
    [ "$(sysctl -n net.ipv4.conf.all.rp_filter)" = 0 ] \
        || { fail 'global rp_filter is enabled; refusing to change global routing policy'; return 1; }
    for bridge in "$TS6_BRIDGE" "$VALHEIM_BRIDGE"; do
        if [ "$(sysctl -n "net.ipv4.conf.$bridge.rp_filter")" != 0 ]; then
            sysctl -w "net.ipv4.conf.$bridge.rp_filter=0" >/dev/null || return 1
        fi
    done
}

chain_is_owned() {
    local table=$1 chain=$2 line rules owned=0
    rules=$(iptables -t "$table" -S "$chain" 2>/dev/null) || return 1
    while IFS= read -r line; do
        [ "$line" = "-N $chain" ] && continue
        [[ $line == *"--comment \"$OWNER_COMMENT\""* || $line == *"--comment $OWNER_COMMENT"* ]] || return 1
        owned=1
    done <<<"$rules"
    [ "$owned" -eq 1 ]
}

ensure_owned_chain() {
    local table=$1 chain=$2
    if iptables -t "$table" -S "$chain" >/dev/null 2>&1; then
        chain_is_owned "$table" "$chain" || fail "refusing to reuse non-Arazel chain $chain"
    else
        iptables -t "$table" -N "$chain"
    fi
}

assert_policy_collisions_absent() {
    local rules line routes binding mask mark i table chain owned=0
    local -a fields
    local expected=$OWNED_RULE_PATTERN
    rules=$(ip -4 rule show) || return 1
    while IFS= read -r line; do
        read -r -a fields <<<"$line"
        if [ "${fields[0]:-}" = "$RULE_PRIORITY:" ]; then
            if [[ ! ${fields[*]} =~ $expected ]]; then
                fail "policy rule priority $RULE_PRIORITY is already occupied"; return 1
            fi
            owned=$((owned + 1))
            [ "$owned" -le 1 ] || { fail "duplicate policy rule priority $RULE_PRIORITY"; return 1; }
            continue
        fi
        for ((i=0; i<${#fields[@]}; i++)); do
            if [ "${fields[i]}" = lookup ] && [ "${fields[i+1]:-}" = "$ROUTING_TABLE" ]; then
                fail "routing table $ROUTING_TABLE is used by another policy"; return 1
            fi
            [ "${fields[i]}" = fwmark ] || continue
            binding=${fields[i+1]}
            mark=${binding%/*}; mask=0xffffffff
            [[ $binding != */* ]] || mask=${binding#*/}
            if (( (MARK & mask) == (mark & mask) )); then
                fail "reserved mark $MARK matches another policy rule"; return 1
            fi
        done
    done <<<"$rules"
    routes=$(ip -4 route show table "$ROUTING_TABLE" 2>/dev/null || true)
    routes=$(printf '%s\n' "$routes" | awk '{$1=$1; print}')
    case "$routes" in
        ''|'local default dev lo'|'local default dev lo scope host') ;;
        *) fail "routing table $ROUTING_TABLE contains unrelated routes"; return 1 ;;
    esac
    for table in nat mangle; do
        if [ "$table" = nat ]; then chain=$NAT_CHAIN; else chain=$MANGLE_CHAIN; fi
        if iptables -t "$table" -S "$chain" >/dev/null 2>&1; then
            chain_is_owned "$table" "$chain" || { fail "reserved chain $chain is not owned"; return 1; }
        fi
    done
}

remove_plain_jump() {
    local table=$1 parent=$2 chain=$3
    while iptables -t "$table" -C "$parent" -j "$chain" >/dev/null 2>&1; do
        iptables -t "$table" -D "$parent" -j "$chain" || return 1
    done
}

first_masquerade_position() {
    iptables -t nat -L POSTROUTING --line-numbers -n --exact | awk '$2 == "MASQUERADE" { print $1; exit }'
}

install_nat_policy() {
    local masquerade_position
    ensure_owned_chain nat "$NAT_CHAIN" || return 1
    remove_plain_jump nat POSTROUTING "$NAT_CHAIN" || return 1
    masquerade_position=$(first_masquerade_position) || return 1
    [ -n "$masquerade_position" ] || { fail 'Docker MASQUERADE rule is unavailable'; return 1; }
    iptables -t nat -F "$NAT_CHAIN" &&
        iptables -t nat -A "$NAT_CHAIN" -o "$TS6_BRIDGE" -p udp --dport 9987 -m comment --comment "$OWNER_COMMENT" -j ACCEPT &&
        iptables -t nat -A "$NAT_CHAIN" -o "$TS6_BRIDGE" -p tcp --dport 30033 -m comment --comment "$OWNER_COMMENT" -j ACCEPT &&
        iptables -t nat -A "$NAT_CHAIN" -o "$VALHEIM_BRIDGE" -p udp --dport 2456 -m comment --comment "$OWNER_COMMENT" -j ACCEPT &&
        iptables -t nat -A "$NAT_CHAIN" -o "$VALHEIM_BRIDGE" -p udp --dport 2457 -m comment --comment "$OWNER_COMMENT" -j ACCEPT &&
        iptables -t nat -A "$NAT_CHAIN" -o "$VALHEIM_BRIDGE" -p udp --dport 2458 -m comment --comment "$OWNER_COMMENT" -j ACCEPT &&
        iptables -t nat -I POSTROUTING "$masquerade_position" -j "$NAT_CHAIN"
}

install_mangle_policy() {
    ensure_owned_chain mangle "$MANGLE_CHAIN" || return 1
    iptables -t mangle -F "$MANGLE_CHAIN" &&
        iptables -t mangle -A "$MANGLE_CHAIN" -i "$TS6_BRIDGE" -p udp --sport 9987 -m socket --transparent -m comment --comment "$OWNER_COMMENT" -j MARK --set-xmark "$MARK/0xffffffff" &&
        iptables -t mangle -A "$MANGLE_CHAIN" -i "$TS6_BRIDGE" -p tcp --sport 30033 -m socket --transparent -m comment --comment "$OWNER_COMMENT" -j MARK --set-xmark "$MARK/0xffffffff" &&
        iptables -t mangle -A "$MANGLE_CHAIN" -i "$VALHEIM_BRIDGE" -p udp --sport 2456 -m socket --transparent -m comment --comment "$OWNER_COMMENT" -j MARK --set-xmark "$MARK/0xffffffff" &&
        iptables -t mangle -A "$MANGLE_CHAIN" -i "$VALHEIM_BRIDGE" -p udp --sport 2457 -m socket --transparent -m comment --comment "$OWNER_COMMENT" -j MARK --set-xmark "$MARK/0xffffffff" &&
        iptables -t mangle -A "$MANGLE_CHAIN" -i "$VALHEIM_BRIDGE" -p udp --sport 2458 -m socket --transparent -m comment --comment "$OWNER_COMMENT" -j MARK --set-xmark "$MARK/0xffffffff" || return 1
    remove_plain_jump mangle PREROUTING "$MANGLE_CHAIN" || return 1
    iptables -t mangle -I PREROUTING 1 -j "$MANGLE_CHAIN"
}

install_policy_route() {
    if ! ip -4 rule show | grep -Eq "^$RULE_PRIORITY:.*fwmark (0x)?0*7cf3(/0xffffffff)? .*lookup $ROUTING_TABLE"; then
        ip -4 rule add priority "$RULE_PRIORITY" fwmark "$MARK/0xffffffff" lookup "$ROUTING_TABLE" || return 1
    fi
    ip -4 route replace local default dev lo table "$ROUTING_TABLE"
}

apply() {
    require_root || return 1
    require_command ip || return 1
    require_command sysctl || return 1
    verify_firewall_backend || return 1
    assert_bridge "$TS6_BRIDGE" || return 1
    assert_bridge "$VALHEIM_BRIDGE" || return 1
    assert_normal_masquerading "$TS6_SUBNET" "$TS6_BRIDGE" || return 1
    assert_normal_masquerading "$VALHEIM_SUBNET" "$VALHEIM_BRIDGE" || return 1
    assert_policy_collisions_absent || return 1
    configure_bridge_sysctls || return 1
    install_nat_policy || return 1
    install_mangle_policy || return 1
    install_policy_route || return 1
    check
}

assert_chain_size() {
    local table=$1 chain=$2 expected=$3 rules line count=0
    rules=$(iptables -t "$table" -S "$chain") || return 1
    while IFS= read -r line; do
        case "$line" in
            "-N $chain") ;;
            "-A $chain "*) count=$((count + 1));;
            *) fail "unexpected $table/$chain content"; return 1;;
        esac
    done <<<"$rules"
    [ "$count" -eq "$expected" ] || fail "unexpected $table/$chain rule count: $count"
}

assert_rule() {
    local table=$1 chain=$2
    shift 2
    iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1 || fail "missing required $table/$chain rule"
}

assert_global_jump_first() {
    local table=$1 parent=$2 chain=$3 first
    first=$(iptables -t "$table" -S "$parent" | awk '$1 == "-A" { print; exit }')
    [ "$first" = "-A $parent -j $chain" ] || fail "$table/$parent does not dispatch $chain unconditionally before routing"
}

assert_nat_jump_order() {
    local jump masquerade
    jump=$(iptables -t nat -S POSTROUTING | awk -v target="$NAT_CHAIN" '$1 == "-A" { position++ } $0 == "-A POSTROUTING -j " target { print position; exit }')
    masquerade=$(first_masquerade_position)
    [[ $jump =~ ^[0-9]+$ && $masquerade =~ ^[0-9]+$ && jump -lt masquerade ]] \
        || fail 'NAT exemption does not precede Docker MASQUERADE'
}

check() {
    require_root || return 1
    require_command ip || return 1
    require_command sysctl || return 1
    verify_firewall_backend || return 1
    verify_mangle_hook || return 1
    assert_bridge "$TS6_BRIDGE" || return 1
    assert_bridge "$VALHEIM_BRIDGE" || return 1
    assert_normal_masquerading "$TS6_SUBNET" "$TS6_BRIDGE" || return 1
    assert_normal_masquerading "$VALHEIM_SUBNET" "$VALHEIM_BRIDGE" || return 1
    assert_sysctls || return 1
    assert_policy_collisions_absent || return 1
    chain_is_owned nat "$NAT_CHAIN" || { fail "$NAT_CHAIN is absent or not owned"; return 1; }
    chain_is_owned mangle "$MANGLE_CHAIN" || { fail "$MANGLE_CHAIN is absent or not owned"; return 1; }
    assert_chain_size nat "$NAT_CHAIN" 5 || return 1
    assert_chain_size mangle "$MANGLE_CHAIN" 5 || return 1
    assert_global_jump_first mangle PREROUTING "$MANGLE_CHAIN" || return 1
    assert_nat_jump_order || return 1
    assert_rule nat "$NAT_CHAIN" -o "$TS6_BRIDGE" -p udp --dport 9987 -m comment --comment "$OWNER_COMMENT" -j ACCEPT || return 1
    assert_rule nat "$NAT_CHAIN" -o "$TS6_BRIDGE" -p tcp --dport 30033 -m comment --comment "$OWNER_COMMENT" -j ACCEPT || return 1
    assert_rule nat "$NAT_CHAIN" -o "$VALHEIM_BRIDGE" -p udp --dport 2456 -m comment --comment "$OWNER_COMMENT" -j ACCEPT || return 1
    assert_rule nat "$NAT_CHAIN" -o "$VALHEIM_BRIDGE" -p udp --dport 2457 -m comment --comment "$OWNER_COMMENT" -j ACCEPT || return 1
    assert_rule nat "$NAT_CHAIN" -o "$VALHEIM_BRIDGE" -p udp --dport 2458 -m comment --comment "$OWNER_COMMENT" -j ACCEPT || return 1
    assert_rule mangle "$MANGLE_CHAIN" -i "$TS6_BRIDGE" -p udp --sport 9987 -m socket --transparent -m comment --comment "$OWNER_COMMENT" -j MARK --set-xmark "$MARK/0xffffffff" || return 1
    assert_rule mangle "$MANGLE_CHAIN" -i "$TS6_BRIDGE" -p tcp --sport 30033 -m socket --transparent -m comment --comment "$OWNER_COMMENT" -j MARK --set-xmark "$MARK/0xffffffff" || return 1
    assert_rule mangle "$MANGLE_CHAIN" -i "$VALHEIM_BRIDGE" -p udp --sport 2456 -m socket --transparent -m comment --comment "$OWNER_COMMENT" -j MARK --set-xmark "$MARK/0xffffffff" || return 1
    assert_rule mangle "$MANGLE_CHAIN" -i "$VALHEIM_BRIDGE" -p udp --sport 2457 -m socket --transparent -m comment --comment "$OWNER_COMMENT" -j MARK --set-xmark "$MARK/0xffffffff" || return 1
    assert_rule mangle "$MANGLE_CHAIN" -i "$VALHEIM_BRIDGE" -p udp --sport 2458 -m socket --transparent -m comment --comment "$OWNER_COMMENT" -j MARK --set-xmark "$MARK/0xffffffff" || return 1
    ip -4 rule show | grep -Eq "^$RULE_PRIORITY:.*fwmark (0x)?0*7cf3(/0xffffffff)? .*lookup $ROUTING_TABLE" || { fail "missing policy rule priority $RULE_PRIORITY"; return 1; }
    ip -4 route show table "$ROUTING_TABLE" | grep -Eq '^local default dev lo( scope host)?[[:space:]]*$' || { fail "missing local route in table $ROUTING_TABLE"; return 1; }
}

invalidate_readiness() {
    rm -f "$RESPONSE_FILE"
}

remove_owned_chain() {
    local table=$1 chain=$2 parent=$3
    if ! iptables -t "$table" -S "$chain" >/dev/null 2>&1; then
        return 0
    fi
    chain_is_owned "$table" "$chain" || { fail "refusing to delete non-Arazel chain $chain"; return 1; }
    remove_plain_jump "$table" "$parent" "$chain" || return 1
    iptables -t "$table" -F "$chain" && iptables -t "$table" -X "$chain"
}

remove_policy_route() {
    local routes
    if ip -4 rule show | awk '{$1=$1; print}' | grep -Eq "$OWNED_RULE_PATTERN"; then
        ip -4 rule del priority "$RULE_PRIORITY" from all fwmark "$MARK/0xffffffff" lookup "$ROUTING_TABLE" || return 1
    fi
    routes=$(ip -4 route show table "$ROUTING_TABLE" 2>/dev/null || true)
    if grep -Eq '^local default dev lo( scope host)?[[:space:]]*$' <<<"$routes"; then
        ip -4 route del local default dev lo table "$ROUTING_TABLE"
    fi
}

remove() {
    require_root || return 1
    require_command ip || return 1
    require_command iptables || return 1
    invalidate_readiness || return 1
    assert_policy_collisions_absent || return 1
    remove_policy_route || return 1
    remove_owned_chain nat "$NAT_CHAIN" POSTROUTING || return 1
    remove_owned_chain mangle "$MANGLE_CHAIN" PREROUTING || return 1
}

initialize_readiness_runtime() {
    install -d -o root -g root -m 0700 "$RUNTIME_DIR"
    if [ -e "$REQUEST_FIFO" ] && [ ! -p "$REQUEST_FIFO" ]; then
        fail "$REQUEST_FIFO exists but is not a FIFO"
        return 1
    fi
    [ -p "$REQUEST_FIFO" ] || mkfifo -m 0600 "$REQUEST_FIFO"
    touch "$REQUEST_LOCK"
    chown root:root "$REQUEST_FIFO" "$REQUEST_LOCK"
    chmod 0600 "$REQUEST_FIFO" "$REQUEST_LOCK"
    invalidate_readiness
}

valid_nonce() {
    [[ $1 =~ ^[0-9a-f]{32}$ ]]
}

publish_response() {
    local nonce=$1 result=$2 temporary
    temporary=$(mktemp "$RUNTIME_DIR/.readiness.response.XXXXXX")
    printf '%s %s\n' "$nonce" "$result" >"$temporary"
    chown root:root "$temporary"
    chmod 0400 "$temporary"
    mv -f "$temporary" "$RESPONSE_FILE"
}

serve_readiness() {
    require_root
    require_command flock
    setup
    apply
    initialize_readiness_runtime
    trap invalidate_readiness EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    exec 8<>"$REQUEST_FIFO"
    while IFS= read -r nonce <&8; do
        if valid_nonce "$nonce" && check; then
            publish_response "$nonce" ok
        elif valid_nonce "$nonce"; then
            publish_response "$nonce" fail
        fi
    done
}

request_readiness() {
    require_root
    require_command flock
    require_command timeout
    [ -p "$REQUEST_FIFO" ] || fail 'readiness service FIFO is unavailable'
    [ -f "$REQUEST_LOCK" ] || fail 'readiness service lock is unavailable'
    timeout 10s bash -c '
        set -euo pipefail
        nonce=$1 fifo=$2 response=$3 lock=$4
        exec 9<"$lock"
        flock -x 9
        printf "%s\\n" "$nonce" >"$fifo"
        while :; do
            if [ -e "$response" ]; then
                if IFS=" " read -r received result extra <"$response"; then
                    if [ -z "${extra:-}" ] && [ "$received" = "$nonce" ]; then
                        [ "$result" = ok ] && exit 0
                        [ "$result" = fail ] && exit 1
                    fi
                fi
            fi
            sleep 0.05
        done
    ' bash "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" "$REQUEST_FIFO" "$RESPONSE_FILE" "$REQUEST_LOCK"
}

usage() {
    printf '%s\n' 'usage: transparent-routing.sh {setup|apply|check|remove|serve-readiness|request-readiness}' >&2
}

main() {
    [ "$#" -eq 1 ] || { usage; return 64; }
    case "$1" in
        setup) setup ;;
        apply) apply ;;
        check) check ;;
        remove) remove ;;
        serve-readiness) serve_readiness ;;
        request-readiness) request_readiness ;;
        *) usage; return 64 ;;
    esac
}

main "$@"
