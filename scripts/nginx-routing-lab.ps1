param(
    [ValidateSet('policy', 'lifecycle', 'readiness', 'serve-readiness')]
    [string]$Case = 'policy'
)

$ErrorActionPreference = 'Stop'

function Invoke-Docker([string[]]$Arguments, [string]$Description) {
    $output = & docker @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { $output | Write-Host; throw "Docker failed ($Description)" }
    return $output
}

$repo = Split-Path -Parent $PSScriptRoot
$routingScript = Join-Path $repo 'infra/nginx/transparent-routing.sh'
$image = 'alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0'
$id = [guid]::NewGuid().ToString('N').Substring(0, 12)
$container = "arazel-routing-lab-$id"
$tempDir = Join-Path ([IO.Path]::GetTempPath()) $container
$policyScript = Join-Path $tempDir 'policy.sh'

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Wait-Until([scriptblock]$Probe, [int]$Seconds, [string]$Description) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        try {
            if (& $Probe) { return }
        } catch {}
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description"
}

function Invoke-SystemdLifecycle {
    function Invoke-WslDebian([string[]]$Arguments, [string]$Description) {
        $output = & wsl.exe -d Debian -- @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { $output | Write-Host; throw "WSL Debian failed ($Description)" }
        return $output
    }

    function Set-WslFixtureFile([string]$Path, [string]$Content) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content))
        Invoke-WslDebian -Arguments @('sh', '-c', "umask 077; printf '%s' '$encoded' | base64 --decode > '$Path'") -Description "write $Path" | Out-Null
    }

    $dockerUnit = "arazel-routing-lab-docker-$id.service"
    $routingUnit = "arazel-routing-lab-routing-$id.service"
    $markerDir = "/tmp/arazel-routing-lab-$id"
    $unitDir = $null
    $productionUnit = Get-Content -LiteralPath (Join-Path $repo 'infra/nginx/arazel-ingress-routing.service') -Raw
    foreach ($directive in @('Requires=docker.service', 'After=docker.service', 'PartOf=docker.service', 'WantedBy=docker.service')) {
        Assert ($productionUnit -match [regex]::Escape($directive)) "Production routing unit no longer declares $directive"
    }
    Assert ($productionUnit -notmatch 'CapabilityBoundingSet=.*CAP_NET_RAW') 'Routing policy service must not retain NGINX transparent-bind capability'
    $routingFixture = $productionUnit.Replace('docker.service', $dockerUnit)
    $fixtureService = "Type=simple`nExecStart=/bin/sh -c 'test -s $markerDir/dependency-started; cat /proc/sys/kernel/random/uuid > $markerDir/routing-started; exec /bin/sleep infinity'`nExecStop=/bin/sh -c 'date +%%s%%N > $markerDir/routing-stopped'`n`n"
    $routingFixture = [regex]::Replace($routingFixture, '(?s)(\[Service\]\r?\n).*?(?=\[Install\])', '$1' + $fixtureService)
    foreach ($directive in @("Requires=$dockerUnit", "After=$dockerUnit", "PartOf=$dockerUnit", "WantedBy=$dockerUnit")) {
        Assert ($routingFixture -match [regex]::Escape($directive)) "Disposable routing fixture is missing $directive"
    }
    $dockerFixture = "[Unit]`nDescription=Disposable routing-lab Docker dependency`n`n[Service]`nType=simple`nExecStart=/bin/sh -c 'cat /proc/sys/kernel/random/uuid > $markerDir/dependency-started; exec /bin/sleep infinity'`nExecStop=/bin/rm -f $markerDir/dependency-started`n"
    try {
        $managerState = "$((Invoke-WslDebian -Arguments @('sh', '-c', 'systemctl --user is-system-running') -Description 'inspect Debian user manager') | Select-Object -Last 1)".Trim()
        Assert ($managerState -in @('running', 'degraded')) "Debian user manager is not available: $managerState"
        $unitDir = ((Invoke-WslDebian -Arguments @('sh', '-c', 'printf %s "$HOME/.config/systemd/user"') -Description 'locate Debian user unit directory') | Select-Object -Last 1).Trim()
        Invoke-WslDebian -Arguments @('sh', '-c', "install -d -m 0700 '$unitDir' '$markerDir'") -Description 'create owned Debian fixture paths' | Out-Null
        Set-WslFixtureFile -Path "$unitDir/$dockerUnit" -Content $dockerFixture
        Set-WslFixtureFile -Path "$unitDir/$routingUnit" -Content $routingFixture
        Invoke-WslDebian -Arguments @('sh', '-c', 'systemctl --user daemon-reload') -Description 'reload Debian user unit graph' | Out-Null
        Invoke-WslDebian -Arguments @('sh', '-c', "systemd-analyze --user verify '$dockerUnit' '$routingUnit'") -Description 'verify disposable Debian user units' | Out-Null
        Invoke-WslDebian -Arguments @('sh', '-c', "systemctl --user enable '$routingUnit'") -Description 'enable disposable dependency wants relationship' | Out-Null
        Invoke-WslDebian -Arguments @('sh', '-c', "systemctl --user start '$routingUnit'") -Description 'start disposable routing stand-in' | Out-Null
        Assert (((Invoke-WslDebian -Arguments @('sh', '-c', "systemctl --user is-active '$dockerUnit'") -Description 'inspect disposable dependency') | Select-Object -Last 1).Trim() -eq 'active') 'Disposable dependency did not start'
        $firstDependency = ((Invoke-WslDebian -Arguments @('sh', '-c', "cat '$markerDir/dependency-started'") -Description 'read initial dependency marker') | Select-Object -Last 1).Trim()
        $firstStart = ((Invoke-WslDebian -Arguments @('sh', '-c', "cat '$markerDir/routing-started'") -Description 'read initial routing marker') | Select-Object -Last 1).Trim()
        Assert ($firstStart -and $firstDependency) 'After did not publish both initial stand-in markers'
        Invoke-WslDebian -Arguments @('sh', '-c', "systemctl --user restart '$dockerUnit'") -Description 'restart disposable dependency' | Out-Null
        Wait-Until { (((Invoke-WslDebian -Arguments @('sh', '-c', "systemctl --user is-active '$routingUnit'") -Description 'inspect restarted routing stand-in') | Select-Object -Last 1).Trim() -eq 'active') } 20 'routing restart propagation'
        $secondDependency = ((Invoke-WslDebian -Arguments @('sh', '-c', "cat '$markerDir/dependency-started'") -Description 'read restarted dependency marker') | Select-Object -Last 1).Trim()
        $secondStart = ((Invoke-WslDebian -Arguments @('sh', '-c', "cat '$markerDir/routing-started'") -Description 'read restarted routing marker') | Select-Object -Last 1).Trim()
        Assert ($secondStart -ne $firstStart -and $secondDependency -ne $firstDependency) 'PartOf did not recreate both stand-ins with its dependency'
        Assert ($secondStart -and $secondDependency) 'After did not publish both restarted stand-in markers'
        Invoke-WslDebian -Arguments @('sh', '-c', "systemctl --user stop '$dockerUnit'") -Description 'stop disposable dependency' | Out-Null
        Wait-Until { $state = & wsl.exe -d Debian -- sh -c "systemctl --user is-active '$routingUnit' 2>/dev/null"; return $LASTEXITCODE -ne 0 -and (($state | Select-Object -Last 1).Trim() -eq 'inactive') } 20 'routing stop propagation'
        Invoke-WslDebian -Arguments @('sh', '-c', "test -s '$markerDir/routing-stopped'") -Description 'confirm routing stop marker' | Out-Null
        Invoke-WslDebian -Arguments @('sh', '-c', "systemctl --user start '$dockerUnit'") -Description 'start disposable dependency' | Out-Null
        Wait-Until { (((Invoke-WslDebian -Arguments @('sh', '-c', "systemctl --user is-active '$routingUnit'") -Description 'inspect dependency-wanted routing stand-in') | Select-Object -Last 1).Trim() -eq 'active') } 20 'dependency wants start propagation'
        $thirdDependency = ((Invoke-WslDebian -Arguments @('sh', '-c', "cat '$markerDir/dependency-started'") -Description 'read dependency-wanted dependency marker') | Select-Object -Last 1).Trim()
        $thirdStart = ((Invoke-WslDebian -Arguments @('sh', '-c', "cat '$markerDir/routing-started'") -Description 'read dependency-wanted routing marker') | Select-Object -Last 1).Trim()
        Assert ($thirdStart -ne $secondStart -and $thirdDependency -ne $secondDependency) 'Enabled dependency wants did not recreate both stand-ins'
        Assert ($thirdStart -and $thirdDependency) 'After did not publish both dependency-wanted stand-in markers'
        Write-Host 'PASS: Debian user manager verifies stand-in dependency restart, stop, and enabled-start propagation'
    } finally {
        if ($unitDir) {
            $cleanup = "systemctl --user disable --now '$routingUnit' >/dev/null 2>&1 || true; systemctl --user stop '$dockerUnit' >/dev/null 2>&1 || true; systemctl --user reset-failed '$routingUnit' '$dockerUnit' >/dev/null 2>&1 || true; rm -f -- '$unitDir/$routingUnit' '$unitDir/$dockerUnit' '$unitDir/$dockerUnit.wants/$routingUnit'; rmdir --ignore-fail-on-non-empty '$unitDir/$dockerUnit.wants' 2>/dev/null || true; rm -rf -- '$markerDir'; systemctl --user daemon-reload >/dev/null 2>&1 || true"
            & wsl.exe -d Debian -- sh -c $cleanup 2>$null | Out-Null
        }
    }
}

function Invoke-ReadinessBoundary {
    $volume = "arazel-routing-readiness-$id"
    $responder = "arazel-routing-responder-$id"
    $requester = "arazel-routing-requester-$id"
    $responderScript = Join-Path $tempDir 'responder.sh'
    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        @'
set -eu
mkdir -p /run/arazel-ingress
[ -p /run/arazel-ingress/readiness.fifo ] || mkfifo -m 0600 /run/arazel-ingress/readiness.fifo
touch /run/arazel-ingress/readiness.lock
chmod 0600 /run/arazel-ingress/readiness.lock
printf '%032d stale\n' 0 > /run/arazel-ingress/readiness.response
chmod 0400 /run/arazel-ingress/readiness.response
while IFS= read -r nonce < /run/arazel-ingress/readiness.fifo; do
    sleep 1
    temporary=$(mktemp /run/arazel-ingress/.response.XXXXXX)
    printf '%s %s\n' "$nonce" "${READINESS_RESULT:-ok}" > "$temporary"
    chmod 0400 "$temporary"
    mv -f "$temporary" /run/arazel-ingress/readiness.response
done
'@ | Set-Content -LiteralPath $responderScript -Encoding ascii -NoNewline
        function Start-Responder([string]$Result) {
            Invoke-Docker @(
                'run', '-d', '--rm', '--name', $responder,
                '-e', "READINESS_RESULT=$Result",
                '--mount', "type=volume,source=$volume,target=/run/arazel-ingress",
                '--mount', "type=bind,source=$responderScript,target=/lab/responder.sh,readonly",
                $image, 'sh', '/lab/responder.sh'
            ) 'start root readiness responder' | Out-Null
            Wait-Until { & docker exec $responder sh -c 'test -p /run/arazel-ingress/readiness.fifo && test -f /run/arazel-ingress/readiness.response' | Out-Null; return $LASTEXITCODE -eq 0 } 10 'root readiness runtime'
        }
        function Invoke-ReadinessRequest {
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            $output = & docker run --rm --name "$requester-$([guid]::NewGuid().ToString('N').Substring(0, 8))" --mount "type=volume,source=$volume,target=/run/arazel-ingress,readonly" --mount "type=bind,source=$routingScript,target=/routing/transparent-routing.sh,readonly" $image sh -ec 'apk add --no-cache bash util-linux >/dev/null; exec bash /routing/transparent-routing.sh request-readiness' 2>&1
            $status = $LASTEXITCODE
            $stopwatch.Stop()
            return [PSCustomObject]@{ Status = $status; Output = $output; Elapsed = $stopwatch.Elapsed }
        }
        Invoke-Docker @('volume', 'create', $volume) 'create owned readiness volume' | Out-Null
        Start-Responder 'ok'
        $success = Invoke-ReadinessRequest
        if ($success.Status -ne 0) { $success.Output | Write-Host; throw 'Read-only requester did not complete a fresh readiness handshake' }
        Assert ($success.Elapsed.TotalMilliseconds -ge 750) 'Requester accepted the stale response instead of awaiting its matching nonce'
        $response = (& docker exec $responder sh -c 'cat /run/arazel-ingress/readiness.response').Trim()
        Assert ($response -match '^[0-9a-f]{32} ok$') 'Root responder did not atomically publish the matching successful result'
        & docker rm -f $responder 2>$null | Out-Null
        Start-Responder 'fail'
        $failure = Invoke-ReadinessRequest
        Assert ($failure.Status -ne 0) 'Requester accepted a root readiness failure'
        & docker rm -f $responder 2>$null | Out-Null
        $timeout = Invoke-ReadinessRequest
        Assert ($timeout.Status -ne 0) 'Requester accepted readiness without a responder'
        Assert ($timeout.Elapsed.TotalSeconds -ge 9) 'Requester did not enforce the bounded readiness timeout'
        Write-Host 'PASS: read-only requester serializes native flock, rejects failures/timeouts, and waits for a matching root response'
    } finally {
        & docker rm -f $responder 2>$null | Out-Null
        & docker volume rm -f $volume 2>$null | Out-Null
    }
}

function Invoke-ServeReadinessBoundary {
    $volume = "arazel-routing-serve-$id"
    $server = "arazel-routing-serve-$id"
    $labScript = Join-Path $tempDir 'serve-readiness.sh'
    try {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $toolsImage="$server-tools"; $toolsDockerfile=Join-Path $tempDir 'serve-tools.Dockerfile'
        @("FROM $image", 'RUN apk add --no-cache bash iproute2 iptables nftables util-linux') | Set-Content -LiteralPath $toolsDockerfile -Encoding ascii
        Invoke-Docker @('build','--tag',$toolsImage,'--file',$toolsDockerfile,$tempDir) 'build ephemeral serve-readiness helper tools' | Out-Null
        @'
set -eu
mkdir -p /lab/bin
cat > /lab/bin/docker <<'EOF'
#!/bin/sh
set -eu
if [ "$1" = network ] && [ "$2" = inspect ]; then
    if [ "${3:-}" != --format ]; then exit 0; fi
    case "$4" in
        *'.Driver'*) printf '%s\n' bridge ;;
        *'bridge.name'*) case "$5" in *ts6) printf '%s\n' az-ts6;; *) printf '%s\n' az-valheim;; esac ;;
        *'.IPAM.Config'*) case "$5" in *ts6) printf '%s\n' 172.29.87.0/24;; *) printf '%s\n' 172.29.88.0/24;; esac ;;
        *'enable_ip_masquerade'*) printf '%s\n' true ;;
        *'com.arazel.ingress.network'*) printf '%s\n' "$5" ;;
        *) exit 64 ;;
    esac
    exit 0
fi
[ "$1" = network ] && [ "$2" = ls ] && exit 0
exit 64
EOF
chmod 0755 /lab/bin/docker
ip link add az-ts6 type bridge
ip link add az-valheim type bridge
ip link set az-ts6 up
ip link set az-valheim up
iptables -t nat -A POSTROUTING -s 172.29.87.0/24 ! -o az-ts6 -j MASQUERADE
iptables -t nat -A POSTROUTING -s 172.29.88.0/24 ! -o az-valheim -j MASQUERADE
PATH=/lab/bin:$PATH exec bash /routing/transparent-routing.sh serve-readiness
'@ | Set-Content -LiteralPath $labScript -Encoding ascii -NoNewline
        function Start-ServeReadiness {
            Invoke-Docker @(
                'run', '-d', '--name', $server,
                '--cap-add', 'NET_ADMIN',
                '--cap-add', 'NET_RAW',
                '--sysctl', 'net.ipv4.ip_forward=1',
                '--sysctl', 'net.ipv4.conf.all.rp_filter=0',
                '--sysctl', 'net.ipv4.conf.default.rp_filter=0',
                '-e', 'INGRESS_ENVIRONMENT=lab', '-e', 'INGRESS_LAB_NETWORK_PREFIX=lab-',
                '--mount', "type=volume,source=$volume,target=/run/arazel-ingress",
                '--mount', "type=bind,source=$routingScript,target=/routing/transparent-routing.sh,readonly",
                '--mount', "type=bind,source=$labScript,target=/lab/serve-readiness.sh,readonly",
                $toolsImage, 'sh', '/lab/serve-readiness.sh'
            ) 'start actual root serve-readiness helper' | Out-Null
            try {
                Wait-Until { & docker exec $server sh -c 'command -v bash >/dev/null && test -p /run/arazel-ingress/readiness.fifo && test -f /run/arazel-ingress/readiness.lock' | Out-Null; return $LASTEXITCODE -eq 0 } 90 'root serve-readiness runtime'
            } catch {
                & docker logs $server 2>&1 | Write-Host
                & docker inspect --format '{{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}' $server 2>&1 | Write-Host
                throw
            }
        }
        function Request-ServeReadiness {
            $output = & docker run --rm --mount "type=volume,source=$volume,target=/run/arazel-ingress,readonly" --mount "type=bind,source=$routingScript,target=/routing/transparent-routing.sh,readonly" $toolsImage bash /routing/transparent-routing.sh request-readiness 2>&1
            return [PSCustomObject]@{ Status = $LASTEXITCODE; Output = $output }
        }
        Invoke-Docker @('volume', 'create', $volume) 'create owned serve-readiness volume' | Out-Null
        Start-ServeReadiness
        $ready = Request-ServeReadiness
        if ($ready.Status -ne 0) { $ready.Output | Write-Host; throw 'Actual serve-readiness did not acknowledge its strict policy' }
        Invoke-Docker @('kill', '--signal', 'TERM', $server) 'gracefully terminate the owned root readiness helper' | Out-Null
        Wait-Until { ((& docker inspect --format '{{.State.Running}}' $server 2>$null) | Select-Object -Last 1).Trim() -eq 'false' } 10 'root helper TERM exit'
        Invoke-Docker @('run', '--rm', '--mount', "type=volume,source=$volume,target=/run/arazel-ingress,readonly", $image, 'test', '!', '-e', '/run/arazel-ingress/readiness.response') 'confirm TERM cleared root readiness without a fresh request' | Out-Null
        & docker rm -f $server 2>$null | Out-Null
        Start-ServeReadiness
        Invoke-Docker @('exec', $server, 'bash', '/routing/transparent-routing.sh', 'remove') 'remove policy while root readiness server remains running' | Out-Null
        & docker rm -f $server 2>$null | Out-Null
        Start-ServeReadiness
        $repaired = Request-ServeReadiness
        if ($repaired.Status -ne 0) { $repaired.Output | Write-Host; throw 'Actual serve-readiness did not recover after policy reinstall' }
        Write-Host 'PASS: actual serve/request readiness rejects removed policy and recovers after root helper restart'
    } finally {
        & docker rm -f $server 2>$null | Out-Null
        if($toolsImage){& docker image rm -f $toolsImage 2>$null | Out-Null}
        & docker volume rm -f $volume 2>$null | Out-Null
    }
}

if ($Case -eq 'lifecycle') {
    Invoke-SystemdLifecycle
    exit 0
}

if ($Case -eq 'readiness') {
    Invoke-ReadinessBoundary
    Invoke-ServeReadinessBoundary
    exit 0
}

if ($Case -eq 'serve-readiness') {
    Invoke-ServeReadinessBoundary
    exit 0
}

try {
    if (-not (Test-Path -LiteralPath $routingScript)) { throw "Missing production routing script: $routingScript" }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    @'
set -euo pipefail
trap 'echo policy-gate-failed >&2' ERR
routing=$1


ip link add az-ts6 type bridge
ip link add az-valheim type bridge
ip link set az-ts6 up
ip link set az-valheim up
iptables -t nat -A POSTROUTING -s 172.29.87.0/24 ! -o az-ts6 -j MASQUERADE
iptables -t nat -A POSTROUTING -s 172.29.88.0/24 ! -o az-valheim -j MASQUERADE
iptables -A FORWARD -m comment --comment arazel-routing-lab-sentinel -j ACCEPT

if [ "${LAB_EXPECT_RPF_REJECTION:-0}" = 1 ]; then
    if "$routing" apply >/dev/null 2>&1; then
        echo 'conditional policy call ignored enabled global rp_filter' >&2
        exit 1
    fi
    [ "$(sysctl -n net.ipv4.conf.all.rp_filter)" = 1 ]
    exit 0
fi
"$routing" apply
"$routing" check
iptables -t nat -A ARAZEL_INGRESS_NAT -o az-ts6 -p udp --dport 9999 -m comment --comment arazel-ingress -j ACCEPT
if "$routing" check >/dev/null 2>&1; then
    echo 'strict check accepted a sixth owned NAT exemption' >&2
    exit 1
fi
iptables -t nat -D ARAZEL_INGRESS_NAT -o az-ts6 -p udp --dport 9999 -m comment --comment arazel-ingress -j ACCEPT
"$routing" check
if INGRESS_ENVIRONMENT=production INGRESS_LAB_NETWORK_PREFIX=lab- "$routing" check >/dev/null 2>&1; then
    echo 'production accepted a lab network override' >&2
    exit 1
fi
iptables -t nat -D ARAZEL_INGRESS_NAT -o az-ts6 -p udp --dport 9987 -m comment --comment arazel-ingress -j ACCEPT
if "$routing" check >/dev/null 2>&1; then
    echo 'strict check accepted a missing required NAT exemption' >&2
    exit 1
fi
"$routing" apply
"$routing" check
ip -4 route add 203.0.113.0/24 dev lo table 31987
if "$routing" apply >/dev/null 2>&1; then
    echo 'apply accepted an occupied table containing a foreign route' >&2
    exit 1
fi
if "$routing" check >/dev/null 2>&1; then
    echo 'strict readiness check accepted an occupied table' >&2
    exit 1
fi
ip -4 route show table 31987 | grep -F '203.0.113.0/24' >/dev/null
ip -4 route del 203.0.113.0/24 dev lo table 31987
"$routing" apply
ip -4 rule add priority 31087 from 203.0.113.2 fwmark 31987 lookup 31987
if "$routing" remove >/dev/null 2>&1; then
    echo 'remove accepted a foreign source-specific reserved policy rule' >&2
    exit 1
fi
ip -4 rule show | grep -Eq '^31087:.*from 203\.0\.113\.2.*lookup 31987'
iptables -t nat -S ARAZEL_INGRESS_NAT | grep -F -- '--dport 9987' >/dev/null
ip -4 rule del priority 31087 from 203.0.113.2 fwmark 31987 lookup 31987
"$routing" check
for foreign in 'priority 31088 fwmark 31987 lookup 254' 'priority 31088 from 203.0.113.1 lookup 31987' 'priority 31088 fwmark 0x7c00/0xff00 lookup 254'; do
    ip -4 rule add $foreign
    if "$routing" check >/dev/null 2>&1 || "$routing" apply >/dev/null 2>&1; then
        echo "accepted reserved policy identity collision: $foreign" >&2
        exit 1
    fi
    ip -4 rule del $foreign
    "$routing" check
done
iptables -C FORWARD -m comment --comment arazel-routing-lab-sentinel -j ACCEPT
"$routing" remove
set +e
"$routing" check >/dev/null 2>&1
removed_status=$?
set -e
if [ "$removed_status" -eq 0 ]; then
    echo 'strict check succeeded after removal' >&2
    exit 1
fi
if ! iptables -C FORWARD -m comment --comment arazel-routing-lab-sentinel -j ACCEPT; then
    echo 'unrelated FORWARD sentinel was not preserved' >&2
    exit 1
fi
for table in nat mangle; do
    if [ "$table" = nat ]; then chain=ARAZEL_INGRESS_NAT; parent=POSTROUTING; else chain=ARAZEL_INGRESS_MANGLE; parent=PREROUTING; fi
    for foreign in empty populated; do
        iptables -t "$table" -N "$chain"
        if [ "$foreign" = populated ]; then iptables -t "$table" -A "$chain" -m comment --comment lab-foreign-owner -j RETURN; fi
        iptables -t "$table" -A "$parent" -j "$chain"
        before=$(iptables -t "$table" -S)
        if "$routing" apply >/dev/null 2>&1; then
            echo "adopted $foreign unowned $table chain" >&2
            exit 1
        fi
        [ "$(iptables -t "$table" -S)" = "$before" ]
        "$routing" remove >/dev/null 2>&1 || true
        [ "$(iptables -t "$table" -S)" = "$before" ]
        iptables -t "$table" -D "$parent" -j "$chain"
        iptables -t "$table" -F "$chain"
        iptables -t "$table" -X "$chain"
    done
done

'@.Replace("`r`n", "`n") | Set-Content -LiteralPath $policyScript -Encoding ascii -NoNewline


    foreach ($rpf in @(1, 0)) {
    Invoke-Docker @(
        'run', '--rm', '--name', $container,
        '--cap-add', 'NET_ADMIN',
        '--sysctl', 'net.ipv4.ip_forward=1',
        '--sysctl', "net.ipv4.conf.all.rp_filter=$rpf",
        '-e', "LAB_EXPECT_RPF_REJECTION=$rpf",
        '--sysctl', 'net.ipv4.conf.default.rp_filter=0',
        '--mount', "type=bind,source=$routingScript,target=/routing/transparent-routing.sh,readonly",
        '--mount', "type=bind,source=$policyScript,target=/lab/policy.sh,readonly",
        $image, 'sh', '-ec', 'apk add --no-cache bash iproute2 iptables nftables util-linux >/dev/null; exec bash /lab/policy.sh /routing/transparent-routing.sh'
    ) 'run isolated root network-namespace routing policy gate' | Out-Null
    }
    Write-Host 'PASS: owned policy is idempotent, preserves FORWARD intent, and fails closed after scoped removal'
} finally {
    & docker rm -f $container 2>$null | Out-Null
    if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
}
