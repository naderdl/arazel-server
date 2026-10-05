param([string]$Image = 'arazel-nginx:local')

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$alpine = 'alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0'
$certbotImage = 'certbot/certbot:v5.8.0@sha256:f70ad0adbb7e117f0fe42a63c553f28ea451edabc0148757b6efcd9735acaa20'
$pebbleImage = 'ghcr.io/letsencrypt/pebble@sha256:ddf230642b1a584f519f32e347de1b05a6e4c1f6c35c1863b33effeab5f78199'
$challengeImage = 'ghcr.io/letsencrypt/pebble-challtestsrv@sha256:12ce21884def456bcf9786542113949e1f19dc7738d2c70e156c2d0c38a1405b'

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Invoke-Docker([string[]]$Arguments, [string]$Description) {
    $output = & docker.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$Description`: $($output -join [Environment]::NewLine)" }
    return $output
}
function Wait-Until([scriptblock]$Probe, [int]$Seconds, [string]$Description) {
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds); $last=$null
    while([DateTime]::UtcNow -lt $deadline) { try { $value=& $Probe; if($value){ return $value } } catch { $last=$_ }; Start-Sleep -Milliseconds 300 }
    if($last){throw "Timed out waiting for $Description`: $last"}; throw "Timed out waiting for $Description"
}
function Network-Subnet([string]$Network) { return ((Invoke-Docker @('network','inspect','--format','{{range .IPAM.Config}}{{.Subnet}}{{end}}',$Network) "inspect $Network subnet") -join '').Trim() }
function Network-Gateway([string]$Network) { return ((Invoke-Docker @('network','inspect','--format','{{range .IPAM.Config}}{{.Gateway}}{{end}}',$Network) "inspect $Network gateway") -join '').Trim() }
function Container-Ip([string]$Container,[string]$Network) { $detail=(Invoke-Docker @('inspect',$Container) "inspect $Container" | ConvertFrom-Json)[0]; return $detail.NetworkSettings.Networks.PSObject.Properties[$Network].Value.IPAddress }
function Port([string]$Container,[string]$Port) { return [int]((Invoke-Docker @('port',$Container,$Port) "read $Container $Port" | Select-Object -First 1) -replace '^.*:','') }
function Master { return ((Invoke-Docker @('exec',$nginx,'cat','/var/run/nginx.pid') 'read stable nginx master') -join '') }
function Workers { return ((Invoke-Docker @('exec',$nginx,'sh','-ec','pgrep -P $(cat /var/run/nginx.pid) | sort | tr "\n" " "') 'read nginx workers') -join '') }
function Config-Hash { return ((Invoke-Docker @('exec',$nginx,'sha256sum','/run/nginx-selected/nginx.conf') 'hash selected generated config') -join '') }
function Rule-Packets([string]$Table,[string]$Chain,[string]$Needle) {
    $line=(Invoke-Docker @('exec',$root,'sh','-ec',"iptables -t $Table -L $Chain -v -n -x | grep -F -- '$Needle' | head -n1") "read $Needle counter") -join ' '
    Write-Host "native $Table/$Chain counter: $line"
    if($line -notmatch '^\s*([0-9]+)\s+') { throw "could not read packet counter for ${Needle}: $line" }; return [int64]$Matches[1]
}
function Assert-CapabilityBoundary {
    $rootCaps=((Invoke-Docker @('inspect','--format','{{json .HostConfig.CapAdd}}',$root) 'inspect root capabilities') -join '')
    Assert ($rootCaps -match 'NET_ADMIN' -and $rootCaps -match 'NET_RAW') 'root helper lacks required NET_ADMIN/NET_RAW'
    $rootSysctls=((Invoke-Docker @('inspect','--format','{{json .HostConfig.Sysctls}}',$root) 'inspect root helper sysctls') -join '' | ConvertFrom-Json)
    foreach($setting in @('net.ipv4.ip_forward:1','net.ipv4.conf.all.rp_filter:0','net.ipv4.conf.default.rp_filter:0')) { $pair=$setting -split ':',2; Assert ($rootSysctls.PSObject.Properties[$pair[0]].Value -eq $pair[1]) "root helper lacks required $setting sysctl" }
    foreach($name in @($nginx,$controller)) {
        $caps=((Invoke-Docker @('inspect','--format','{{json .HostConfig.CapAdd}}',$name) "inspect $name capabilities") -join '')
        Assert ($caps -notmatch 'NET_ADMIN') "$name has prohibited NET_ADMIN"
    }
}
function Invoke-Root([string]$Command,[string]$Description) { return Invoke-Docker @('exec',$root,'bash','-ec',$Command) $Description }
function Start-RootService { Invoke-Docker @('exec','-d',$root,'bash','/routing/transparent-routing.sh','serve-readiness') 'start root routing and FIFO service' | Out-Null }
function Connect-NginxGameNetwork([string]$Network,[string]$Bridge,[string]$Subnet) {
    Invoke-Docker @('network','connect',$Network,$nginx) "attach ingress to $Network" | Out-Null
    $Address=Container-Ip $nginx $Network; Assert ([bool]$Address) "ingress has no address on $Network"; $addressWithPrefix=((Invoke-Root "ip -o -4 addr show | grep -o $Address/[0-9]* | head -n 1" "read ingress $Network endpoint prefix") -join '').Trim(); Assert ([bool]$addressWithPrefix) "ingress has no endpoint prefix for $Address on $Network"
    $device=((Invoke-Root "ip -o -4 addr show | grep -F $addressWithPrefix | head -n 1 | cut -d ' ' -f 2 | cut -d @ -f 1" "find ingress $Network endpoint") -join '').Trim(); Assert ([bool]$device) "ingress has no endpoint address $addressWithPrefix on $Network"
    Invoke-Root "ip link add $Bridge type bridge; ip link set $Bridge up; ip addr del $addressWithPrefix dev $device; ip link set $device master $Bridge; ip link set $device up; ip addr add $addressWithPrefix dev $Bridge; ip route replace $Subnet dev $Bridge src $Address; iptables -t nat -C POSTROUTING -s $Subnet ! -o $Bridge -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $Subnet ! -o $Bridge -j MASQUERADE" "move $Network ingress endpoint onto local $Bridge" | Out-Null
}
function Start-Backend([string]$Name,[string]$Project,[string]$Network,[string]$Labels,[string]$Script) {
    $arguments=@('run','-d','--name',$Name,'--network',$Network,'--label',"com.docker.compose.project=$Project",'--label','ingress.enabled=true','--mount',"type=bind,source=$backendPath,target=/lab/backend.sh,readonly",'--entrypoint','sh') + $Labels.Split("`n") + @($certbotImage,'/lab/backend.sh',$Script)
    Invoke-Docker $arguments "start $Project transparent backend" | Out-Null
}
function Set-BackendDefault([string]$Backend,[string]$Gateway) {
    $helper="$prefix-route-$([guid]::NewGuid().ToString('N').Substring(0,6))"
    Invoke-Docker @('run','-d','--name',$helper,'--network',"container:$Backend",'--cap-add','NET_ADMIN','--cap-add','NET_RAW','--sysctl','net.ipv4.ip_forward=1','--sysctl','net.ipv4.conf.all.rp_filter=0','--sysctl','net.ipv4.conf.default.rp_filter=0',$alpine,'sh','-ec',"ip route replace default via $Gateway; exec sleep 900") "set $Backend default through ingress bridge" | Out-Null
    $helperSysctls=((Invoke-Docker @('inspect','--format','{{json .HostConfig.Sysctls}}',$helper) 'inspect backend helper sysctls') -join '' | ConvertFrom-Json)
    foreach($setting in @('net.ipv4.ip_forward:1','net.ipv4.conf.all.rp_filter:0','net.ipv4.conf.default.rp_filter:0')) { $pair=$setting -split ':',2; Assert ($helperSysctls.PSObject.Properties[$pair[0]].Value -eq $pair[1]) "backend helper lacks required $setting sysctl" }
    $script:created += $helper
    Wait-Until { ((Invoke-Docker @('exec',$Backend,'sh','-ec','ip route show default') "read $Backend default") -join '') -match [regex]::Escape("via $Gateway") } 15 "$Backend policy default"
}
function Udp-Identity([string]$Port,[string]$Client) {
    $probe=@'
python3 - <<'PY'
import os, socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(8)
client_ip = socket.gethostbyname(socket.gethostname())
s.bind((client_ip, 0))
s.sendto(b'ping', (os.environ['NGINX_IP'], int(os.environ['TARGET_PORT'])))
client = s.getsockname()
payload, source = s.recvfrom(4096)
print(f"{client[0]}:{client[1]}>{source[0]}:{source[1]}|{payload.decode()}")
PY
'@
    return ((Invoke-Docker @('run','--rm','--network',$clientNetwork,'--name',$Client,'--entrypoint','sh','-e',"NGINX_IP=$nginxClientIp",'-e',"TARGET_PORT=$Port",$certbotImage,'-ec',$probe) "send and receive UDP $Port from $Client") -join '').Trim()
}
function Assert-UdpIdentity([string]$Identity,[string]$Port,[string]$Tag) {
    $pattern="^(?<client>[0-9.]+):(?<clientPort>[1-9][0-9]*)>(?<source>[0-9.]+):(?<sourcePort>[0-9]+)\|(?<backend>[0-9.]+)\|$([regex]::Escape($Tag))`$"
    if($Identity -notmatch $pattern){throw "UDP $Port did not expose complete peer/source tuple: $Identity"}
    Assert ($Matches.client -eq $Matches.backend) "UDP $Port backend did not observe the original client IP: $Identity"
    Assert ($Matches.client -ne $nginxClientIp) "UDP $Port backend observed ingress instead of client: $Identity"
    Assert ($Matches.source -eq $nginxClientIp -and $Matches.sourcePort -eq $Port) "UDP $Port response leaked backend identity or source port: $Identity"
}
function Start-ExternalClient([string]$Client,[string]$SourceIp) {
    Invoke-Docker @('run','-d','--name',$Client,'--network',$clientNetwork,'--cap-add','NET_ADMIN','--entrypoint','sh',$certbotImage,'-ec','exec sleep infinity') "start owned external-like client $Client" | Out-Null
    $endpoint=Container-Ip $Client $clientNetwork
    Invoke-Docker @('exec',$Client,'sh','-ec',"ip addr add $SourceIp/32 dev eth0; ip route replace $nginxClientIp/32 via $clientGateway src $SourceIp") "assign owned external source $SourceIp" | Out-Null
    Invoke-Root "ip route replace $SourceIp/32 via $endpoint" "route external source $SourceIp through its client endpoint" | Out-Null
}
function Udp-MultiIdentityFrom([int[]]$Ports,[string]$Client,[string]$SourceIp,[int]$SourcePort) {
    $probe=@'
python3 - <<'PY'
import os, socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(8)
s.bind((os.environ['SOURCE_IP'], int(os.environ['SOURCE_PORT'])))
for port in map(int, os.environ['TARGET_PORTS'].split(',')):
    s.sendto(b'ping', (os.environ['NGINX_IP'], port))
    client = s.getsockname()
    payload, source = s.recvfrom(4096)
    print(f"{port}|{client[0]}:{client[1]}>{source[0]}:{source[1]}|{payload.decode()}")
PY
'@
    return @(Invoke-Docker @('exec','-e',"NGINX_IP=$nginxClientIp",'-e',"TARGET_PORTS=$($Ports -join ',')",'-e',"SOURCE_IP=$SourceIp",'-e',"SOURCE_PORT=$SourcePort",$Client,'sh','-ec',$probe) "send all UDP ports from external-like $Client socket")
}
function Tcp-IdentityFrom([string]$Client,[string]$SourceIp,[int]$SourcePort) {
    $probe=@'
python3 - <<'PY'
import os, socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(30)
s.bind((os.environ['SOURCE_IP'], int(os.environ['SOURCE_PORT'])))
s.connect((os.environ['NGINX_IP'], 30033))
s.sendall(b'tcp')
client = s.getsockname()
peer = s.getpeername()
print(f"{client[0]}:{client[1]}>{peer[0]}:{peer[1]}|{s.recv(4096).decode()}")
PY
'@
    return ((Invoke-Docker @('exec','-e',"NGINX_IP=$nginxClientIp",'-e',"SOURCE_IP=$SourceIp",'-e',"SOURCE_PORT=$SourcePort",$Client,'sh','-ec',$probe) "send TCP 30033 from external-like $Client") -join '').Trim()
}
function Invoke-Certbot([switch]$Renew) {
    $args=@('--network',$clientNetwork,'--dns',$dnsIp,'--add-host',"localhost:$pebbleIp",'--add-host',"app.test:$nginxClientIp",'--entrypoint','sh','--mount',"type=volume,source=$certVolume,target=/etc/letsencrypt",'--mount',"type=volume,source=$webVolume,target=/var/www/certbot",'--mount',"type=volume,source=$selectedVolume,target=/run/nginx-selected,readonly",'--mount',"type=bind,source=$caPath,target=/run/acme-test/endpoint-ca.pem,readonly",'--mount',"type=bind,source=$repo/infra/nginx/certificates.sh,target=/opt/ingress/certificates.sh,readonly",'-e','REQUESTS_CA_BUNDLE=/run/acme-test/endpoint-ca.pem','-e','ACME_EMAIL=lab@example.test','-e','ACME_ENVIRONMENT=lab','-e','ACME_DIRECTORY=https://localhost:14000/dir','-e','ACME_TERMS_DIRECTORY=https://localhost:14000/dir','-e','ACME_ACCEPT_TERMS=true','-e','CERTBOT_COMMAND_TIMEOUT_SECONDS=120','-e','CERTBOT_POLL_SECONDS=1','-e','CERTBOT_RENEW_SECONDS=3600','-e','CERTBOT_RETRY_SECONDS=2')
    if($Renew){ Invoke-Docker (@('run','--rm')+$args+@('-e','CERTBOT_FORCE_RENEWAL=true',$certbotImage,'/opt/ingress/certificates.sh','renew')) 'force real Pebble renewal' | Out-Null; return }
    Invoke-Docker (@('run','-d','--name',$certbotRunner)+$args+@($certbotImage,'/opt/ingress/certificates.sh','run')) 'start trusted Pebble certificate worker' | Out-Null
}
function Cert-Serial {
    $probe='status=0; openssl s_client -connect app.test:443 -servername app.test -verify_return_error -verify_hostname app.test -CAfile /run/acme-test/issued.pem </dev/null >/tmp/leaf 2>/tmp/verify || status=$?; cat /tmp/verify >&2; test "$status" -eq 0; openssl x509 -noout -serial </tmp/leaf'
    return ((Invoke-Docker @('run','--rm','--network',$clientNetwork,'--add-host',"app.test:$nginxClientIp",'--entrypoint','sh','--mount',"type=bind,source=$issuedPath,target=/run/acme-test/issued.pem,readonly",$certbotImage,'-ec',$probe) 'verify real trusted TLS wire certificate') -join '').Trim()
}

$id=[guid]::NewGuid().ToString('N').Substring(0,10); $prefix="arazel-transparent-$id"; $clientNetwork="$prefix-proxy"; $controlNetwork="$prefix-control"; $tsNetwork="$prefix-ingress-ts6"; $valNetwork="$prefix-ingress-valheim"; $tsBridge="az-t$id"; $valBridge="az-v$id"; $nginx="$prefix-nginx"; $root="$prefix-root"; $controller="$prefix-controller"; $socket="$prefix-socket"; $httpBackend="$prefix-http"; $tsBackend="$prefix-ts6"; $valBackend="$prefix-valheim"; $dns="$prefix-dns"; $pebble="$prefix-pebble"; $certVolume="$prefix-cert"; $webVolume="$prefix-web"; $configVolume="$prefix-config"; $selectedVolume="$prefix-selected"; $runtimeVolume="$prefix-runtime"; $readinessVolume="$prefix-readiness"; $temp=Join-Path ([IO.Path]::GetTempPath()) $prefix; $backendPath=Join-Path $temp 'backend.sh'; $caPath=Join-Path $temp 'endpoint-ca.pem'; $issuedPath=Join-Path $temp 'issued.pem'; $pebbleConfig=Join-Path $temp 'pebble.json'; $script:created=@(); $primaryFailure=$false
$certbotRunner="$prefix-certificates"
try {
    Invoke-Docker @('image','inspect',$Image) 'inspect requested immutable ingress image' | Out-Null
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    $rootImage="$prefix-root-tools"; $rootDockerfile=Join-Path $temp 'root-tools.Dockerfile'
    @("FROM $alpine", 'RUN apk add --no-cache bash iproute2 iptables nftables util-linux docker-cli') | Set-Content -LiteralPath $rootDockerfile -Encoding ascii
    Invoke-Docker @('build','--tag',$rootImage,'--file',$rootDockerfile,$temp) 'build ephemeral pinned root helper tools' | Out-Null
    @'
#!/bin/sh
set -eu
exec python3 - "$1" <<'PY'
import socket
import sys
import threading
import time

def udp_socket(port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('0.0.0.0', port))
    return sock

def udp_loop(sock, tag):
    while True:
        _, peer = sock.recvfrom(65535)
        sock.sendto(f'{peer[0]}|{tag}'.encode(), peer)

def serve_udp(sockets, tag):
    print(f'ready {tag}', flush=True)
    for sock in sockets:
        threading.Thread(target=udp_loop, args=(sock, tag), daemon=True).start()
    threading.Event().wait()

def serve_ts():
    udp = udp_socket(9987)
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('0.0.0.0', 30033))
    listener.listen()
    print('ready ts', flush=True)
    threading.Thread(target=udp_loop, args=(udp, 'ts-udp'), daemon=True).start()
    while True:
        conn, peer = listener.accept()
        threading.Thread(target=serve_tcp, args=(conn, peer), daemon=True).start()

def serve_tcp(conn, peer):
    with conn:
        conn.recv(65535)
        time.sleep(20)
        conn.sendall(f'{peer[0]}|ts-tcp'.encode())

if sys.argv[1] == 'ts':
    serve_ts()
else:
    serve_udp([udp_socket(port) for port in (2456, 2457, 2458)], 'valheim')
PY
'@ | Set-Content -LiteralPath $backendPath -Encoding ascii -NoNewline
    '{"pebble":{"listenAddress":"0.0.0.0:14000","managementListenAddress":"0.0.0.0:15000","certificate":"test/certs/localhost/cert.pem","privateKey":"test/certs/localhost/key.pem","httpPort":80,"tlsPort":443,"ocspResponderURL":"","externalAccountBindingRequired":false,"retryAfter":{"authz":1,"order":1},"profiles":{"default":{"description":"lab","validityPeriod":3600}}}}' | Set-Content -LiteralPath $pebbleConfig -Encoding ascii
    foreach($network in @($clientNetwork,$controlNetwork)){Invoke-Docker @('network','create',$network) "create $network" | Out-Null; $script:created+=$network}
    Invoke-Docker @('network','create','--opt',"com.docker.network.bridge.name=$tsBridge",'--opt','com.docker.network.bridge.enable_ip_masquerade=true','--label',"com.arazel.ingress.network=$tsNetwork",$tsNetwork) 'create owned TS6 outer network' | Out-Null; $script:created+=$tsNetwork
    Invoke-Docker @('network','create','--opt',"com.docker.network.bridge.name=$valBridge",'--opt','com.docker.network.bridge.enable_ip_masquerade=true','--label',"com.arazel.ingress.network=$valNetwork",$valNetwork) 'create owned Valheim outer network' | Out-Null; $script:created+=$valNetwork
    $tsSubnet=Network-Subnet $tsNetwork; $valSubnet=Network-Subnet $valNetwork
    foreach($volume in @($certVolume,$webVolume,$configVolume,$selectedVolume,$runtimeVolume,$readinessVolume)){Invoke-Docker @('volume','create',$volume) "create $volume" | Out-Null; $script:created+=$volume}
    $clientGateway=Network-Gateway $clientNetwork; $clientSubnet=Network-Subnet $clientNetwork; $dnsIp=($clientGateway -replace '\.1$','.2'); $pebbleIp=($clientGateway -replace '\.1$','.3'); $httpIp=($clientGateway -replace '\.1$','.4'); $nginxIp=($clientGateway -replace '\.1$','.5')
    Invoke-Docker @('run','-d','--name',$httpBackend,'--network',$clientNetwork,'--ip',$httpIp,'--label','com.docker.compose.project=infra','--label','ingress.enabled=true','--label','ingress.http.network=proxy','--label','ingress.http.host=app.test','--label','ingress.http.port=8080','--label','ingress.http.auth=none',$alpine,'sh','-ec','apk add --no-cache busybox-extras >/dev/null; exec nc -lk -p 8080 -e sh -c "read x; printf \"HTTP/1.1 200 OK\\r\\nContent-Length: 2\\r\\n\\r\\nok\""') 'start generated HTTPS inventory backend' | Out-Null; $script:created+=$httpBackend
    Invoke-Docker @('run','-d','--name',$nginx,'--network',$clientNetwork,'--ip',$nginxIp,'--sysctl','net.ipv4.ip_forward=1','--sysctl','net.ipv4.conf.all.rp_filter=0','--sysctl','net.ipv4.conf.default.rp_filter=0','--mount',"type=volume,source=$certVolume,target=/etc/letsencrypt,readonly",'--mount',"type=volume,source=$webVolume,target=/var/www/certbot,readonly",'--mount',"type=volume,source=$configVolume,target=/run/nginx-config,readonly",'--mount',"type=volume,source=$selectedVolume,target=/run/nginx-selected,readonly",'--mount',"type=volume,source=$runtimeVolume,target=/run/nginx-runtime",'--mount',"type=volume,source=$readinessVolume,target=/run/arazel-ingress,readonly",$Image) 'start unprivileged ingress master' | Out-Null; $script:created+=$nginx
    $nginxClientIp=Container-Ip $nginx $clientNetwork
    Invoke-Docker @('run','-d','--name',$dns,'--network',$clientNetwork,'--ip',$dnsIp,$challengeImage,'-defaultIPv4',$nginxClientIp,'-defaultIPv6','') 'start challenge DNS with ingress address' | Out-Null; $script:created+=$dns
    Invoke-Docker @('run','-d','--name',$pebble,'--network',$clientNetwork,'--ip',$pebbleIp,'-p','127.0.0.1::15000/tcp','--mount',"type=bind,source=$pebbleConfig,target=/test/pebble.json,readonly",'-e','PEBBLE_VA_NOSLEEP=1',$pebbleImage,'-config','/test/pebble.json','-strict','-dnsserver',"$dnsIp`:8053") 'start real Pebble CA' | Out-Null; $script:created+=$pebble
    Wait-Until { ((& docker.exe logs $pebble 2>&1) -join "`n") -match 'Pebble.*ready|Starting Pebble' } 30 'Pebble startup' | Out-Null
    Invoke-Docker @('cp',"$pebble`:/test/certs/pebble.minica.pem",$caPath) 'extract Pebble trust root' | Out-Null
    New-Item -ItemType File -Path $issuedPath -Force | Out-Null
    Wait-Until { try { Invoke-Docker @('run','--rm','--network',$clientNetwork,'--entrypoint','sh','--mount',"type=bind,source=$caPath,target=/run/endpoint.pem,readonly",'--mount',"type=bind,source=$issuedPath,target=/run/issued.pem",'curlimages/curl:8.12.1','-ec',"curl --noproxy '*' --connect-to localhost:15000:$pebbleIp`:15000 --fail --silent --show-error --cacert /run/endpoint.pem https://localhost:15000/roots/0 > /run/issued.pem") 'copy Pebble issuance trust root' | Out-Null; Invoke-Docker @('run','--rm','--entrypoint','sh','--mount',"type=bind,source=$issuedPath,target=/run/issued.pem,readonly",$certbotImage,'-ec','openssl x509 -in /run/issued.pem -noout -issuer -subject -fingerprint -sha256') 'parse Pebble issuance trust root' | Out-Null; $true } catch { $null } } 30 'Pebble issuance trust root' | Out-Null
    Invoke-Docker @('run','-d','--name',$socket,'--network',$controlNetwork,'--network-alias','socket-proxy','--mount','type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly','--mount',"type=bind,source=$repo/infra/nginx/docker-socket-proxy.cfg,target=/opt/ingress/docker-socket-proxy.cfg,readonly",'--entrypoint','haproxy','tecnativa/docker-socket-proxy@sha256:1f5038b54f06c3e18422902cf00ba21803d1c97805aae032e5e6673d532d3459','-W','-db','-f','/opt/ingress/docker-socket-proxy.cfg') 'start filtered metadata controller socket' | Out-Null; $script:created+=$socket
    Invoke-Docker @('run','-d','--name',$controller,'--network',$controlNetwork,'--pid',"container:$nginx",'--entrypoint','/usr/local/sbin/controller.sh','-e','DOCKER_HOST=tcp://socket-proxy:2375','-e','INGRESS_ENVIRONMENT=lab','-e',"INGRESS_LAB_NETWORK_PREFIX=$prefix-",'-e','ACME_ENVIRONMENT=lab','-e','ACME_DIRECTORY=https://localhost:14000/dir','-e','NGINX_MASTER_RUNTIME=/run/nginx-master-runtime','-e','CONTROLLER_RECONCILE_SECONDS=1','--mount',"type=volume,source=$certVolume,target=/etc/letsencrypt,readonly",'--mount',"type=volume,source=$webVolume,target=/var/www/certbot,readonly",'--mount',"type=volume,source=$configVolume,target=/run/nginx-config",'--mount',"type=volume,source=$selectedVolume,target=/run/nginx-selected",'--mount',"type=volume,source=$runtimeVolume,target=/run/nginx-master-runtime,readonly",'--mount',"type=volume,source=$readinessVolume,target=/run/arazel-ingress,readonly",$Image,'run') 'start no-NET_ADMIN label controller' | Out-Null; $script:created+=$controller
    Wait-Until { try { Master } catch { $null } } 45 'initial generated NGINX master' | Out-Null
    Invoke-Docker @('run','-d','--name',$root,'--network',"container:$nginx",'--cap-add','NET_ADMIN','--cap-add','NET_RAW','--sysctl','net.ipv4.ip_forward=1','--sysctl','net.ipv4.conf.all.rp_filter=0','--sysctl','net.ipv4.conf.default.rp_filter=0','--mount','type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly','--mount',"type=volume,source=$readinessVolume,target=/run/arazel-ingress",'--mount',"type=bind,source=$repo/infra/nginx/transparent-routing.sh,target=/routing/transparent-routing.sh,readonly",'-e','INGRESS_ENVIRONMENT=lab','-e',"INGRESS_LAB_NETWORK_PREFIX=$prefix-",'-e',"INGRESS_LAB_TS6_BRIDGE=$tsBridge",'-e',"INGRESS_LAB_VALHEIM_BRIDGE=$valBridge",'-e',"INGRESS_LAB_TS6_SUBNET=$tsSubnet",'-e',"INGRESS_LAB_VALHEIM_SUBNET=$valSubnet",$rootImage,'sleep','infinity') 'create only privileged root helper in ingress NETNS' | Out-Null; $script:created+=$root
    Wait-Until { try { Invoke-Docker @('exec',$root,'bash','-c','command -v iptables >/dev/null && command -v docker >/dev/null') 'wait for root helper tools' | Out-Null; $true } catch { $state=((& docker.exe inspect --format '{{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}' $root 2>&1) -join ' ').Trim(); $logs=((& docker.exe logs --tail 80 $root 2>&1) -join [Environment]::NewLine).Trim(); throw "root helper bootstrap state=$state logs=$logs" } } 60 'root helper tools' | Out-Null
    Connect-NginxGameNetwork $tsNetwork $tsBridge $tsSubnet
    Connect-NginxGameNetwork $valNetwork $valBridge $valSubnet
    Start-RootService
    Wait-Until { & docker.exe exec $root sh -ec 'test -p /run/arazel-ingress/readiness.fifo && test ! -e /run/arazel-ingress/readiness.response'; $LASTEXITCODE -eq 0 } 45 'fresh root FIFO with no stale readiness' | Out-Null
    Assert-CapabilityBoundary
    $tsLabels="--label`ningress.stream.network=ingress-ts6`n--label`ningress.stream.udp=9987:9987`n--label`ningress.stream.tcp=30033:30033"
    Start-Backend $tsBackend 'ts' $tsNetwork $tsLabels 'ts'; $script:created+=$tsBackend
    Wait-Until { ((& docker.exe logs $tsBackend 2>&1) -join "`n") -match 'ready ts' } 45 'TS6 backend listeners' | Out-Null
    Set-BackendDefault $tsBackend (Container-Ip $nginx $tsNetwork)
    Wait-Until { ((Config-Hash) -and ((Invoke-Docker @('exec',$nginx,'grep','-F','# ingress-stream: tcp|30033|','/run/nginx-selected/nginx.conf') 'observe generated TS TCP route') -join '') -match '30033') } 45 'strict generated TS6 stream activation' | Out-Null
    $master=Master; $oldWorkers=Workers; $tsClient="$prefix-ts-client"; $udp=Udp-Identity 9987 $tsClient
    $tsIngressIp=Container-Ip $nginx $tsNetwork; $tsOuterGateway=Network-Gateway $tsNetwork; $tsBackendDefault=((Invoke-Docker @('exec',$tsBackend,'ip','route','show','default') 'read TS6 backend default') -join '').Trim(); $tsNatPackets=Rule-Packets nat ARAZEL_INGRESS_NAT 'dpt:9987'
    Write-Host "TS6 boundary ingress=$tsIngressIp outerGateway=$tsOuterGateway backendDefault=$tsBackendDefault natAcceptPackets=$tsNatPackets observation=$udp"
    Assert ($udp -match "\|$([regex]::Escape($tsOuterGateway))\|ts-udp`$") "ordinary client did not demonstrate outer Docker gateway NAT: $udp"
    $valLabels="--label`ningress.stream.network=ingress-valheim`n--label`ningress.stream.udp=2456:2456,2457:2457,2458:2458"
    Start-Backend $valBackend 'valheim' $valNetwork $valLabels 'valheim'; $script:created+=$valBackend
    Wait-Until { ((& docker.exe logs $valBackend 2>&1) -join "`n") -match 'ready valheim' } 45 'Valheim backend listeners' | Out-Null
    Set-BackendDefault $valBackend (Container-Ip $nginx $valNetwork)
    Wait-Until { ((Invoke-Docker @('exec',$nginx,'grep','-F','# ingress-stream: udp|2458|','/run/nginx-selected/nginx.conf') 'observe generated Valheim route') -join '') -match '2458' } 45 'generated Valheim stream activation' | Out-Null
    $externalClients=@(@{Name="$prefix-multi-a"; SourceIp='198.18.0.10'},@{Name="$prefix-multi-b"; SourceIp='198.18.0.11'})
    $multiClients=@()
    foreach($external in $externalClients) {
        Start-ExternalClient $external.Name $external.SourceIp; $script:created+=$external.Name
        $rows=@(Udp-MultiIdentityFrom @(9987,2456,2457,2458) $external.Name $external.SourceIp 41001)
        Assert ($rows.Count -eq 4) "$($external.Name) did not receive every supported UDP response"
        $clientIps=@(); $clientPorts=@()
        foreach($row in $rows) {
            if($row -notmatch '^(?<port>[0-9]+)\|(?<identity>.+)$'){throw "malformed same-socket UDP observation: $row"}
            $port=$Matches.port; $identity=$Matches.identity; Assert-UdpIdentity $identity $port $(if($port -eq '9987'){'ts-udp'}else{'valheim'})
            $identity -match '^(?<client>[0-9.]+):(?<clientPort>[0-9]+)>' | Out-Null; $clientIps+=$Matches.client; $clientPorts+=$Matches.clientPort
        }
        Assert (($clientIps | Select-Object -Unique).Count -eq 1 -and $clientIps[0] -eq $external.SourceIp -and ($clientPorts | Select-Object -Unique).Count -eq 1 -and $clientPorts[0] -eq '41001') "$($external.Name) did not retain its assigned source IP and one UDP socket/source port across every contacted port"
        $multiClients+=$clientIps[0]
    }
    Assert (($multiClients | Select-Object -Unique).Count -eq 2) 'distinct external-like clients did not retain distinct original source addresses while reusing the same source port'
    $tcp=Tcp-IdentityFrom $externalClients[0].Name $externalClients[0].SourceIp 41002; Assert ($tcp -match "^$([regex]::Escape($externalClients[0].SourceIp)):41002>$([regex]::Escape($nginxClientIp)):30033\|$([regex]::Escape($externalClients[0].SourceIp))\|ts-tcp`$") "TS6 TCP did not retain client source or ingress response identity: $tcp"
    Assert ((Rule-Packets nat ARAZEL_INGRESS_NAT 'dpt:9987') -gt 0) 'TS6 narrow NAT exemption did not receive traffic'
    Assert ((Rule-Packets mangle ARAZEL_INGRESS_MANGLE 'spt:9987') -gt 0) 'TS6 marked reply rule did not receive traffic'
    Invoke-Certbot; $script:created+=$certbotRunner
    try { $serial=Wait-Until { Cert-Serial } 90 'trusted stock Certbot HTTPS' } catch {
        $workerState=((Invoke-Docker @('inspect','--format','{{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}',$certbotRunner) 'inspect certificate worker state') -join '')
        $workerPaths=((Invoke-Docker @('exec',$certbotRunner,'sh','-ec','test -r /run/acme-test/endpoint-ca.pem; test -d /etc/letsencrypt; test -d /var/www/certbot; getent hosts localhost') 'inspect certificate worker paths and endpoint hostname') -join '; ')
        $workerLogs=((& docker.exe logs --tail 30 $certbotRunner 2>&1) -join '; ')
        $inventory=((Invoke-Docker @('exec',$nginx,'sh','-ec','grep "^# ingress-certificate: " /run/nginx-selected/nginx.conf || true; grep -E "^[[:space:]]*ssl_certificate(_key)? " /run/nginx-selected/nginx.conf || true') 'read selected certificate inventory and TLS paths') -join '; ')
        $lineage=((& docker.exe exec $controller sh /opt/ingress/certificates.sh check-lineage app.test 2>&1) -join '; '); $lineageExit=$LASTEXITCODE
        $rootAck=((Invoke-Root '/routing/transparent-routing.sh request-readiness' 'request fresh root routing readiness') -join '')
        $controllerLogs=((& docker.exe logs --tail 20 $controller 2>&1) -join '; ')
        throw "$($_.Exception.Message) worker=$workerState paths=$workerPaths inventory=$inventory lineageExit=$lineageExit lineage=$lineage rootAck=$rootAck controllerLogs=$controllerLogs workerLogs=$workerLogs"
    }
    $sustain="$prefix-sustain"; Invoke-Docker @('run','-d','--name',$sustain,'--network',$clientNetwork,'--entrypoint','sh','-e',"NGINX_IP=$nginxClientIp",$alpine,'-ec','apk add --no-cache socat >/dev/null; i=0; while [ $i -lt 40 ]; do printf u | socat -T 2 - UDP:$NGINX_IP:9987 >/tmp/u || exit 1; i=$((i+1)); sleep .2; done') 'sustain real UDP during renewal and label update' | Out-Null; $script:created+=$sustain
    $longTcp="$prefix-long-tcp"; Invoke-Docker @('run','-d','--name',$longTcp,'--network',$clientNetwork,'--entrypoint','sh','-e',"NGINX_IP=$nginxClientIp",$alpine,'-ec','apk add --no-cache socat >/dev/null; dd if=/dev/zero bs=1024 count=2048 2>/dev/null | socat -T 30 - TCP:$NGINX_IP:30033 >/tmp/tcp') 'sustain long TCP transfer during master reload' | Out-Null; $script:created+=$longTcp
    Invoke-Certbot -Renew
    $renewed=Wait-Until { $next=Cert-Serial; if($next -ne $serial){$next} } 90 'real certificate renewal'
    Assert ((Master) -eq $master) 'renewal replaced NGINX master instead of reloading it'
    Assert ((Workers) -ne $oldWorkers) 'renewal did not acknowledge new native workers'
    $oldWorkerList=@($oldWorkers -split ' ' | Where-Object { $_ }); Wait-Until { foreach($workerPid in $oldWorkerList){ & docker.exe exec $nginx kill -0 $workerPid 2>$null; if($LASTEXITCODE -eq 0){return $false} }; $true } 30 'old worker graceful shutdown bound' | Out-Null
    Invoke-Docker @('rm','-f',$valBackend) 'remove labelled Valheim backend' | Out-Null
    Wait-Until { & docker.exe exec $nginx sh -ec '! grep -qF 2458 /run/nginx-selected/nginx.conf'; $LASTEXITCODE -eq 0 } 45 'eventual generated Valheim route removal' | Out-Null
    Wait-Until { ((& docker.exe inspect --format '{{.State.ExitCode}}' $sustain 2>$null) | Select-Object -Last 1).Trim() -eq '0' } 30 'sustained UDP completion'
    Wait-Until { ((& docker.exe inspect --format '{{.State.ExitCode}}' $longTcp 2>$null) | Select-Object -Last 1).Trim() -eq '0' } 30 'long TCP completion'
    Invoke-Docker @('exec',$root,'bash','-ec',"iptables -t nat -C POSTROUTING -s $clientSubnet -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s $clientSubnet -j MASQUERADE; wget -qO- --timeout=3 http://$nginxClientIp/ >/dev/null || true") 'exercise ordinary client MASQUERADE witness outside game exemptions' | Out-Null
    $loaded=Config-Hash; Invoke-Docker @('stop','--time','1',$root) 'tear down root FIFO service' | Out-Null
    Start-Backend "$prefix-bad" 'valheim' $valNetwork "--label`ningress.stream.network=ingress-valheim`n--label`ningress.stream.udp=2456:2456,2457:2457,2458:2458" 'valheim'
    Start-Sleep -Seconds 3
    Assert ((Config-Hash) -eq $loaded) 'readiness corruption activated a new valid stream snapshot'
    Invoke-Docker @('rm','-f',"$prefix-bad") 'remove rejected stream candidate' | Out-Null
    Invoke-Docker @('start',$root) 'restart root helper namespace container' | Out-Null
    Start-RootService
    Wait-Until { & docker.exe exec $root test -p /run/arazel-ingress/readiness.fifo; $LASTEXITCODE -eq 0 } 45 'root helper recovery' | Out-Null
    Wait-Until { if((Config-Hash) -ne $loaded){return $false}; Invoke-Docker @('exec',$nginx,'test','-s','/run/nginx-config/.controller-ready') 'fresh controller recovery' | Out-Null; $true } 45 'controller readiness recovery' | Out-Null
    Write-Host "PASS: mixed TS6/Valheim transparent ingress, root FIFO gating, source identity, Pebble/Certbot renewal, stream reconciliation, and capability boundaries passed ($Image)."
} catch {
    $primaryFailure=$true
    Write-Host "GATE FAILURE: $($_.Exception.Message)"
    foreach($container in @($controller,$root,$nginx,$tsBackend,$valBackend,$certbotRunner)){ if($container){ try { $diagnostic=& docker.exe logs --tail 50 $container 2>&1; Write-Host ($diagnostic -join "`n") } catch {} } }
    throw
} finally {
    foreach($container in @($script:created | Where-Object { $_ -notmatch '^arazel-transparent-.*-(client|control|ingress-ts6|ingress-valheim|cert|web|config|selected|runtime|readiness)$' } | Select-Object -Unique)){ try { & docker.exe rm -f $container 2>&1 | Out-Null } catch {} }
    foreach($network in @($clientNetwork,$controlNetwork,$tsNetwork,$valNetwork)){ try { & docker.exe network rm $network 2>&1 | Out-Null } catch {} }
    foreach($volume in @($certVolume,$webVolume,$configVolume,$selectedVolume,$runtimeVolume,$readinessVolume)){ try { & docker.exe volume rm -f $volume 2>&1 | Out-Null } catch {} }
    if($rootImage){try { & docker.exe image rm -f $rootImage 2>&1 | Out-Null } catch {}}
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
