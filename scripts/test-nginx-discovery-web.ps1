param(
    [ValidateSet('all','discovery','web')]
    [string]$Case = 'all',
    [string]$Image = 'arazel-nginx:local'
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$alpine = 'alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0'
$certbotImage = 'certbot/certbot:v5.8.0@sha256:f70ad0adbb7e117f0fe42a63c553f28ea451edabc0148757b6efcd9735acaa20'
$pebbleImage = 'ghcr.io/letsencrypt/pebble@sha256:ddf230642b1a584f519f32e347de1b05a6e4c1f6c35c1863b33effeab5f78199'
$challengeImage = 'ghcr.io/letsencrypt/pebble-challtestsrv@sha256:12ce21884def456bcf9786542113949e1f19dc7738d2c70e156c2d0c38a1405b'
$socketImage = 'tecnativa/docker-socket-proxy:latest@sha256:1f5038b54f06c3e18422902cf00ba21803d1c97805aae032e5e6673d532d3459'
$lgtmImage = 'grafana/otel-lgtm:0.30.0@sha256:46ca028e294bd728e8e930a28e887f640a8f2a9533cc283f79bcc6ab73d2ffd8'
$alloyImage = 'grafana/alloy@sha256:2aa2099af76c0098d4af7a4d6e48f86cb66dc1a000222ad927a1c67c6542d13f'

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Invoke-Docker([string[]]$Arguments, [string]$What) {
    $output = & docker.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "$What`: $($output -join [Environment]::NewLine)" }
    return $output
}
function Wait-Until([scriptblock]$Probe, [int]$Seconds, [string]$What) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds); $last = $null
    while ([DateTime]::UtcNow -lt $until) {
        try { $value = & $Probe; if ($value) { return $value } } catch { $last = $_ }
        Start-Sleep -Milliseconds 400
    }
    if ($last) { throw "Timed out waiting for ${What}: $last" }
    throw "Timed out waiting for $What"
}
function Check([string]$Name, [scriptblock]$Action) {
    & $Action
    Write-Host "PASS [$Case]: $Name"
}
function Docker-Ip([string]$Container, [string]$Network) {
    return ((Invoke-Docker @('inspect','-f',"{{(index .NetworkSettings.Networks `"$Network`").IPAddress}}",$Container) "read $Container address") -join '').Trim()
}
function Selected-Root { return (Invoke-Docker @('exec',$nginx,'cat','/run/nginx-selected/nginx.conf') 'read selected native root') -join "`n" }
function Selected-Fingerprint { return ((Invoke-Docker @('exec',$nginx,'sha256sum','/run/nginx-selected/nginx.conf') 'fingerprint selected native root') -join '').Split(' ')[0] }
function Selected-Has([string]$Domain) { return (Selected-Root) -match [regex]::Escape("# ingress-certificate: $Domain") }
function Controller-Logs { return ((& docker.exe logs $controller 2>&1) -join "`n") }
function Pebble-Orders { return @((& docker.exe logs $pebble 2>&1) | Where-Object { $_ -match 'POST /order-plz' }).Count }
function Pebble-Accounts { return @((& docker.exe logs $pebble 2>&1) | Where-Object { $_ -match 'POST /sign-me-up' }).Count }
function Volume-Run([string]$Volume, [string]$Command, [string]$What) { return Invoke-Docker @('run','--rm','--mount',"type=volume,source=$Volume,target=/state",$alpine,'sh','-ec',$Command) $What }
function Web-Run([string]$Command, [string]$What) { return Invoke-Docker @('run','--rm','--mount',"type=volume,source=$webVolume,target=/state",$alpine,'sh','-ec',$Command) $What }
function Render-Now([switch]$ExpectFailure) { $failed=$false; try { Invoke-Docker @('run','--rm','--network',$control,'--entrypoint','docker-gen','--mount',"type=volume,source=$configVolume,target=/run/nginx-config",'-e','DOCKER_HOST=tcp://socket-proxy:2375','-e','INGRESS_ENVIRONMENT=lab','-e',"INGRESS_LAB_NETWORK_PREFIX=$prefix-",$Image,'-config','/etc/docker-gen/docker-gen-once.cfg') 'render native filtered Docker snapshot' | Out-Null } catch { $failed=$true; if(-not $ExpectFailure){throw} }; if($ExpectFailure){Assert $failed 'invalid Docker metadata rendered a candidate'} }
function Wait-Selected([string]$Domain, [bool]$Present = $true) { Wait-Until { (Selected-Has $Domain) -eq $Present } 35 "selected root state for $Domain" | Out-Null }
function Verify-Active-Still([string]$Fingerprint, [string]$Name) { Start-Sleep -Seconds 2; Assert ((Selected-Fingerprint) -eq $Fingerprint) "$Name changed the activated root"; $code=Http-Code 'baseline.test' '/'; Assert ($code -eq '308') "$Name poisoned the active baseline route ($code)" }
function Run-Backend([string]$Name,[string]$Project,[string]$Domain,[string]$Auth='none',[switch]$Disabled,[string[]]$ExtraLabels=@(),[string[]]$Networks=@($proxy)) { $labels=@('--label',"com.docker.compose.project=$Project",'--label',"ingress.enabled=$($(if($Disabled){'false'}else{'true'}))"); if($Domain){$labels+=@('--label','ingress.http.network=proxy','--label',"ingress.http.host=$Domain",'--label','ingress.http.port=8080','--label',"ingress.http.auth=$Auth")}; foreach($label in $ExtraLabels){$labels+=@('--label',$label)}; $args=@('run','-d','--name',$Name,'--network',$Networks[0])+$labels; foreach($network in ($Networks|Select-Object -Skip 1)){$args+=@('--network',$network)}; $args+=@('--mount',"type=bind,source=$backendScript,target=/run/backend.py,readonly",'--entrypoint','python',$certbotImage,'/run/backend.py','8080'); Invoke-Docker $args "start owned backend $Name" | Out-Null; $script:owned+=$Name }
function Run-LabelOnly([string]$Name,[string]$Project,[string[]]$Labels,[string[]]$Networks=@($proxy),[switch]$Stopped){$args=@('run','-d','--name',$Name,'--network',$Networks[0],'--label',"com.docker.compose.project=$Project"); foreach($network in ($Networks|Select-Object -Skip 1)){$args+=@('--network',$network)}; foreach($label in $Labels){$args+=@('--label',$label)}; $args+=@($alpine,'sleep','300'); Invoke-Docker $args "start owned metadata fixture $Name" | Out-Null; $script:owned+=$Name; if($Stopped){Invoke-Docker @('stop',$Name) "stop owned metadata fixture $Name"|Out-Null}}
function Remove-Owned([string]$Name){& docker.exe rm -f $Name 2>$null|Out-Null; $script:owned=@($script:owned|Where-Object{$_ -ne $Name})}
function Http-Code([string]$Domain,[string]$Path,[hashtable]$Headers=@{}){$args=@('run','--rm','--network',$proxy,'--add-host',"$Domain`:$nginxIp",'curlimages/curl:8.12.1','-sS','-o','/dev/null','-w','%{http_code}','--connect-timeout','5'); foreach($key in $Headers.Keys){$args+=@('-H',"$key`: $($Headers[$key])")}; $args+="http://$Domain$Path"; return ((Invoke-Docker $args "request HTTP $Domain$Path")-join '').Trim()}
function Http-Headers([string]$Domain,[string]$Path,[hashtable]$Headers=@{}){$args=@('run','--rm','--network',$proxy,'--add-host',"$Domain`:$nginxIp",'curlimages/curl:8.12.1','-sS','-D','-','-o','/dev/null','--connect-timeout','5'); foreach($key in $Headers.Keys){$args+=@('-H',"$key`: $($Headers[$key])")}; $args+="http://$Domain$Path"; return (Invoke-Docker $args "read HTTP headers $Domain$Path")-join "`n"}
function Trusted-Get([string]$Domain,[string]$Path,[string[]]$Arguments=@()){$args=@('run','--rm','--network',$proxy,'--add-host',"$Domain`:$nginxIp",'--entrypoint','curl','--mount',"type=bind,source=$issuedPath,target=/run/issued.pem,readonly",$Image,'--noproxy','*','--silent','--show-error','--cacert','/run/issued.pem')+$Arguments+@("https://$Domain$Path"); return (Invoke-Docker $args "make trusted HTTPS request to $Domain$Path")-join "`n"}
function Trusted-Status([string]$Domain,[string]$Path,[string[]]$Arguments=@()){$args=@('run','--rm','--network',$proxy,'--add-host',"$Domain`:$nginxIp",'--entrypoint','curl','--mount',"type=bind,source=$issuedPath,target=/run/issued.pem,readonly",$Image,'--noproxy','*','--silent','--output','/dev/null','--write-out','%{http_code}','--cacert','/run/issued.pem')+$Arguments+@("https://$Domain$Path"); return ((Invoke-Docker $args "read trusted HTTPS status $Domain$Path")-join '').Trim()}
function Tls-Leaf([string]$Domain){$command="openssl s_client -connect $Domain`:443 -servername $Domain -verify_return_error -verify_hostname $Domain -CAfile /run/issued.pem </dev/null >/tmp/leaf 2>/tmp/verify; openssl x509 -in /tmp/leaf -noout -serial -enddate"; return (Invoke-Docker @('run','--rm','--network',$proxy,'--add-host',"$Domain`:$nginxIp",'--entrypoint','sh','--mount',"type=bind,source=$issuedPath,target=/run/issued.pem,readonly",$certbotImage,'-ec',$command) "verify trusted TLS for $Domain")-join "`n"}
function Assert-Tls-Reject([string]$Domain){
    $command='openssl s_client -connect '+$Domain+':443 -servername '+$Domain+' -verify_return_error -verify_hostname '+$Domain+' -CAfile /run/issued.pem -showcerts </dev/null >/tmp/out 2>/tmp/err; status=$?; cat /tmp/out /tmp/err; [ "$status" -ne 0 ] && grep -q "SSL alert number 112" /tmp/err && ! grep -q "BEGIN CERTIFICATE" /tmp/out'
    Invoke-Docker @('run','--rm','--network',$proxy,'--add-host',"$Domain`:$nginxIp",'--entrypoint','sh','--mount',"type=bind,source=$issuedPath,target=/run/issued.pem,readonly",$certbotImage,'-c',$command) "observe actual rejecting TLS default for $Domain" | Out-Null
}
function Wait-Tls([string]$Domain){Wait-Until {Tls-Leaf $Domain} 100 "trusted active TLS certificate for $Domain"|Out-Null}
function Start-Certbot([string]$Name,[bool]$Force=$false){$args=@('run','-d','--name',$Name,'--network',$proxy,'--dns',$dnsIp,'--add-host',"localhost:$pebbleIp",'--label','com.docker.compose.project=infra','--label','com.docker.compose.service=certbot','--entrypoint','sh','--mount',"type=volume,source=$certVolume,target=/etc/letsencrypt",'--mount',"type=volume,source=$webVolume,target=/var/www/certbot",'--mount',"type=volume,source=$selectedVolume,target=/run/nginx-selected,readonly",'--mount',"type=bind,source=$endpointCa,target=/run/endpoint.pem,readonly",'--mount',"type=bind,source=$repo/infra/nginx/certificates.sh,target=/opt/ingress/certificates.sh,readonly",'-e','REQUESTS_CA_BUNDLE=/run/endpoint.pem','-e','ACME_EMAIL=lab@example.test','-e','ACME_ENVIRONMENT=lab','-e','ACME_DIRECTORY=https://localhost:14000/dir','-e','ACME_TERMS_DIRECTORY=https://localhost:14000/dir','-e','ACME_ACCEPT_TERMS=true','-e','CERTBOT_COMMAND_TIMEOUT_SECONDS=120','-e','CERTBOT_POLL_SECONDS=1','-e',"CERTBOT_RENEW_SECONDS=$(if($Force){'5'}else{'3600'})",'-e','CERTBOT_RETRY_SECONDS=2'); if($Force){$args+=@('-e','CERTBOT_FORCE_RENEWAL=true')}; $args+=@($certbotImage,'-ec','exec /opt/ingress/certificates.sh run'); Invoke-Docker $args 'start actual stock Certbot scheduler'|Out-Null; $script:owned+=$Name}
function Stop-Certbot([string]$Name){Remove-Owned $Name}
function Issue-Hosts([string[]]$Domains){$before=Pebble-Orders; $client="$prefix-certbot-$([guid]::NewGuid().ToString('N').Substring(0,5))"; Start-Certbot $client; foreach($domain in $Domains){Wait-Tls $domain}; Wait-Until {(Pebble-Orders)-ge($before+$Domains.Count)} 100 'actual Pebble orders for active inventory'|Out-Null; Stop-Certbot $client}
function Start-Lab {
    Invoke-Docker @('image','inspect',$Image) 'inspect requested native ingress image' | Out-Null
    New-Item -ItemType Directory -Force -Path $temp | Out-Null

    @'
import base64, hashlib, json, socket, sys
port=int(sys.argv[1])
listener=socket.socket(); listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); listener.bind(('0.0.0.0',port)); listener.listen(50)
while True:
    conn,_=listener.accept(); data=b''
    while b'\r\n\r\n' not in data:
        part=conn.recv(4096)
        if not part: break
        data+=part
    lines=data.decode('iso-8859-1').split('\r\n'); request=lines[0].split() if lines else []
    headers={}
    for line in lines[1:]:
        if ':' in line:
            key,value=line.split(':',1); headers[key.lower()]=value.strip()
    if len(request)>1 and request[1]=='/ws' and headers.get('upgrade','').lower()=='websocket':
        key=headers.get('sec-websocket-key',''); accept=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        conn.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n').encode())
        frame=conn.recv(4096); length=frame[1]&127; offset=2
        if length==126: length=int.from_bytes(frame[2:4],'big'); offset=4
        mask=frame[offset:offset+4]; payload=bytes(frame[offset+4+i]^mask[i%4] for i in range(length))
        conn.sendall(bytes([0x81,len(payload)])+payload); conn.close(); continue
    body=json.dumps({'host':headers.get('host'),'real':headers.get('x-real-ip'),'xff':headers.get('x-forwarded-for'),'xfhost':headers.get('x-forwarded-host'),'proto':headers.get('x-forwarded-proto'),'port':headers.get('x-forwarded-port'),'forwarded':headers.get('forwarded'),'upgrade':headers.get('upgrade')},sort_keys=True).encode()
    conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '+str(len(body)).encode()+b'\r\nConnection: close\r\n\r\n'+body); conn.close()
'@ | Set-Content -LiteralPath $backendScript -Encoding ascii -NoNewline
    @'
import base64, hashlib, os, socket, ssl, sys
host=sys.argv[1]; ca='/run/issued.pem'; raw=socket.create_connection((host,443),5); ctx=ssl.create_default_context(cafile=ca); conn=ctx.wrap_socket(raw,server_hostname=host); key=base64.b64encode(os.urandom(16)).decode(); conn.sendall(('GET /ws HTTP/1.1\r\nHost: '+host+'\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: '+key+'\r\nSec-WebSocket-Version: 13\r\n\r\n').encode()); response=conn.recv(4096); assert b'101 Switching Protocols' in response; payload=b'owned-websocket-proof'; mask=os.urandom(4); conn.sendall(bytes([0x81,0x80|len(payload)])+mask+bytes(payload[i]^mask[i%4] for i in range(len(payload)))); frame=conn.recv(4096); assert frame[0]==0x81 and frame[2:2+(frame[1]&127)]==payload; print(payload.decode())
'@ | Set-Content -LiteralPath $websocketScript -Encoding ascii -NoNewline
    @'
{"pebble":{"listenAddress":"0.0.0.0:14000","managementListenAddress":"0.0.0.0:15000","certificate":"test/certs/localhost/cert.pem","privateKey":"test/certs/localhost/key.pem","httpPort":80,"tlsPort":443,"ocspResponderURL":"","externalAccountBindingRequired":false,"retryAfter":{"authz":1,"order":1},"profiles":{"default":{"description":"lab","validityPeriod":3600}}}}
'@ | Set-Content -LiteralPath $pebbleConfig -Encoding ascii
    $script:prefix = 'arazel-discovery-'+[guid]::NewGuid().ToString('N').Substring(0,10)
    $script:control="$prefix-control"; $script:proxy="$prefix-proxy"; $script:stream="$prefix-ingress-ts6"; $script:wrong="$prefix-wrong"; $script:nginx="$prefix-nginx"; $script:controller="$prefix-controller"; $script:socket="$prefix-socket-proxy"; $script:pebble="$prefix-pebble"; $script:dns="$prefix-dns"
    $script:certVolume="$prefix-cert"; $script:webVolume="$prefix-web"; $script:configVolume="$prefix-config"; $script:selectedVolume="$prefix-selected"; $script:runtimeVolume="$prefix-runtime"; $script:authVolume="$prefix-auth"
    Invoke-Docker @('network','create','--internal',$control) 'create owned control network' | Out-Null
    Invoke-Docker @('network','create',$proxy) 'create owned proxy network' | Out-Null
    Invoke-Docker @('network','create',$stream) 'create owned stream metadata network' | Out-Null
    Invoke-Docker @('network','create',$wrong) 'create owned wrong-role network' | Out-Null

    foreach($volume in @($certVolume,$webVolume,$configVolume,$selectedVolume,$runtimeVolume,$authVolume)){Invoke-Docker @('volume','create',$volume) "create owned volume $volume" | Out-Null}
    $subnet=((Invoke-Docker @('network','inspect',$proxy) 'read owned proxy subnet' | ConvertFrom-Json)[0].IPAM.Config[0].Subnet); $parts=($subnet -split '/')[0].Split('.'); $script:dnsIp="$($parts[0]).$($parts[1]).$($parts[2]).2"; $script:pebbleIp="$($parts[0]).$($parts[1]).$($parts[2]).3"; $script:nginxIp="$($parts[0]).$($parts[1]).$($parts[2]).250"
    Invoke-Docker @('run','-d','--name',$dns,'--network',$proxy,'--ip',$dnsIp,'-p','127.0.0.1::8055/tcp',$challengeImage,'-defaultIPv4',$nginxIp,'-defaultIPv6','') 'start owned controlled DNS' | Out-Null; $script:owned += $dns
    Invoke-Docker @('run','-d','--name',$pebble,'--network',$proxy,'--ip',$pebbleIp,'--dns',$dnsIp,'-p','127.0.0.1::15000/tcp','--mount',"type=bind,source=$pebbleConfig,target=/test/pebble.json,readonly",'-e','PEBBLE_VA_NOSLEEP=1','-e','PEBBLE_WFE_NONCEREJECT=0','-e','PEBBLE_AUTHZREUSE=0',$pebbleImage,'-config','/test/pebble.json','-strict','-dnsserver',"$dnsIp`:8053") 'start pinned isolated Pebble' | Out-Null; $script:owned += $pebble
    Wait-Until { ((& docker.exe logs $pebble 2>&1) -join "`n") -match 'Pebble.*ready|Starting Pebble' } 30 'pinned Pebble' | Out-Null
    Invoke-Docker @('cp',"$pebble`:/test/certs/pebble.minica.pem",$endpointCa) 'copy Pebble endpoint trust root' | Out-Null
    New-Item -ItemType File -Path $issuedPath -Force | Out-Null
    Wait-Until { try { Invoke-Docker @('run','--rm','--network',$proxy,'--entrypoint','sh','--mount',"type=bind,source=$endpointCa,target=/run/endpoint.pem,readonly",'--mount',"type=bind,source=$issuedPath,target=/run/issued.pem",$Image,'-ec',"curl --noproxy '*' --connect-to localhost:15000:${pebbleIp}:15000 --fail --silent --show-error --cacert /run/endpoint.pem https://localhost:15000/roots/0 > /run/issued.pem; test -s /run/issued.pem") 'copy Pebble issued-certificate trust root' | Out-Null; $true } catch { $false } } 30 'Pebble issued-certificate trust root' | Out-Null
    Invoke-Docker @('run','--rm','--entrypoint','sh','--mount',"type=volume,source=$authVolume,target=/etc/nginx",$Image,'-ec','test -s /etc/nginx/mime.types') 'initialize Linux auth storage with stock NGINX files' | Out-Null
    Volume-Run $authVolume "apk add --no-cache apache2-utils >/dev/null; htpasswd -nbB fixture '$password' > /state/usersfile; chmod 0644 /state/usersfile; cp /state/usersfile /state/usersfile.valid" 'generate actual BCrypt bytes in Linux-owned auth storage' | Out-Null
    Run-Backend "$prefix-baseline" 'infra' 'baseline.test'; Run-Backend "$prefix-capture" 'infra' 'capture.test'; Run-Backend "$prefix-huginn" 'valheim' 'huginn.test' 'huginn'
    Invoke-Docker @('run','-d','--name',$socket,'--network',$control,'--network-alias','socket-proxy','--entrypoint','haproxy','--mount','type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly','--mount',"type=bind,source=$repo/infra/nginx/docker-socket-proxy.cfg,target=/opt/ingress/docker-socket-proxy.cfg,readonly",$socketImage,'-W','-db','-f','/opt/ingress/docker-socket-proxy.cfg') 'start narrow owned socket filter' | Out-Null; $script:owned += $socket
    Invoke-Docker @('run','-d','--name',$nginx,'--network',$proxy,'--ip',$nginxIp,'--label','com.docker.compose.project=infra','--label','com.docker.compose.service=nginx','--mount',"type=volume,source=$certVolume,target=/etc/letsencrypt,readonly",'--mount',"type=volume,source=$webVolume,target=/var/www/certbot,readonly",'--mount',"type=volume,source=$configVolume,target=/run/nginx-config,readonly",'--mount',"type=volume,source=$selectedVolume,target=/run/nginx-selected,readonly",'--mount',"type=volume,source=$runtimeVolume,target=/run/nginx-runtime",'--mount',"type=volume,source=$authVolume,target=/etc/nginx,readonly",$Image) 'start actual native ingress' | Out-Null; $script:owned += $nginx
    Invoke-Docker @('run','-d','--name',$controller,'--network',$control,'--pid',"container:$nginx",'--label','com.docker.compose.project=infra','--label','com.docker.compose.service=controller','--entrypoint','/usr/local/sbin/controller.sh','-e','DOCKER_HOST=tcp://socket-proxy:2375','-e','INGRESS_ENVIRONMENT=lab','-e',"INGRESS_LAB_NETWORK_PREFIX=$prefix-",'-e','CONTROLLER_RECONCILE_SECONDS=1','-e','ACME_ENVIRONMENT=lab','-e','ACME_DIRECTORY=https://localhost:14000/dir','-e','NGINX_MASTER_RUNTIME=/run/nginx-master-runtime','--mount',"type=volume,source=$certVolume,target=/etc/letsencrypt,readonly",'--mount',"type=volume,source=$webVolume,target=/var/www/certbot,readonly",'--mount',"type=volume,source=$configVolume,target=/run/nginx-config",'--mount',"type=volume,source=$selectedVolume,target=/run/nginx-selected",'--mount',"type=volume,source=$runtimeVolume,target=/run/nginx-master-runtime,readonly",'--mount',"type=volume,source=$authVolume,target=/etc/nginx,readonly",$Image,'run') 'start actual native controller' | Out-Null; $script:owned += $controller
    Wait-Selected 'baseline.test'; Wait-Selected 'capture.test'; Wait-Selected 'huginn.test'
}
function Invoke-Discovery {
    Start-Lab
    Check 'enabled selected route is controller-rendered from Docker metadata' { Assert (Selected-Has 'baseline.test') 'baseline was not selected' }
    Check 'absent labels do not expose or poison a loaded route' { Run-LabelOnly "$prefix-absent" 'infra' @(); Start-Sleep -Seconds 2; Assert (-not (Selected-Has 'absent.test')) 'unlabeled container exposed a route'; Assert ((Http-Code 'baseline.test' '/') -eq '308') 'unlabeled container disturbed baseline' }
    Check 'disabled, enabled, and wrong-project labels reconcile without poisoning selected routes' { Run-Backend "$prefix-disabled" 'infra' 'disabled.test' 'none' -Disabled; Run-Backend "$prefix-wrongproject" 'other' 'wrongproject.test'; Start-Sleep -Seconds 2; Assert (-not (Selected-Has 'disabled.test') -and -not (Selected-Has 'wrongproject.test')) 'disabled or untrusted project route was selected'; Assert ((Http-Code 'baseline.test' '/') -eq '308') 'ignored metadata poisoned baseline'; Remove-Owned "$prefix-disabled"; Run-Backend "$prefix-disabled" 'infra' 'enabled.test'; Wait-Selected 'enabled.test'; Remove-Owned "$prefix-disabled"; Wait-Selected 'enabled.test' $false }
    Check 'add, stop, remove and correct metadata reconcile through the actual controller' { Run-Backend "$prefix-added" 'infra' 'added.test'; Wait-Selected 'added.test'; Invoke-Docker @('stop',"$prefix-added") 'stop owned discovered backend' | Out-Null; Wait-Selected 'added.test' $false; Remove-Owned "$prefix-added"; Run-LabelOnly "$prefix-badport" 'infra' @('ingress.enabled=true','ingress.http.network=proxy','ingress.http.host=recovered.test','ingress.http.port=not-a-port'); $active=Selected-Fingerprint; Wait-Until { (Controller-Logs) -match 'invalid ingress.http.port|reconciliation rejected' } 20 'native invalid-label rejection'; Verify-Active-Still $active 'invalid port'; Remove-Owned "$prefix-badport"; Run-Backend "$prefix-recovered" 'infra' 'recovered.test'; Wait-Selected 'recovered.test'; Assert ((Http-Code 'recovered.test' '/') -eq '308') 'corrected metadata did not recover a route' }
    Check 'injected label text and normalized hostname collision leave active traffic untouched' { $active=Selected-Fingerprint; Run-LabelOnly "$prefix-injection" 'infra' @('ingress.enabled=true','ingress.http.network=proxy','ingress.http.host=evil.test;include /etc/nginx/x','ingress.http.port=8080'); Render-Now -ExpectFailure; Verify-Active-Still $active 'injection candidate'; Remove-Owned "$prefix-injection"; Run-Backend "$prefix-collision" 'infra' 'BASELINE.TEST'; Render-Now -ExpectFailure; Verify-Active-Still $active 'normalized collision'; Remove-Owned "$prefix-collision" }
    Check 'wrong physical network role and fixed stream tuple failures retain loaded unrelated routes' { $active=Selected-Fingerprint; Run-LabelOnly "$prefix-wrongnet" 'infra' @('ingress.enabled=true','ingress.http.network=proxy','ingress.http.host=wrongnet.test','ingress.http.port=8080') @($wrong); Render-Now -ExpectFailure; Verify-Active-Still $active 'wrong web network'; Remove-Owned "$prefix-wrongnet"; Run-LabelOnly "$prefix-wrongtuple" 'ts' @('ingress.enabled=true','ingress.stream.network=ingress-ts6','ingress.stream.udp=9988:9988') @($stream); Render-Now -ExpectFailure; Verify-Active-Still $active 'invalid fixed stream tuple'; Remove-Owned "$prefix-wrongtuple"; Run-LabelOnly "$prefix-stream-one" 'ts' @('ingress.enabled=true','ingress.stream.network=ingress-ts6','ingress.stream.udp=9987:9987') @($stream); Run-LabelOnly "$prefix-stream-two" 'ts' @('ingress.enabled=true','ingress.stream.network=ingress-ts6','ingress.stream.udp=9987:9987') @($stream); Render-Now -ExpectFailure; Verify-Active-Still $active 'duplicate stream listener'; Remove-Owned "$prefix-stream-one"; Remove-Owned "$prefix-stream-two" }
    Check 'stopped eligible container and controller restart perform complete reconciliation' { Run-Backend "$prefix-stopped" 'infra' 'stopped.test'; Wait-Selected 'stopped.test'; Invoke-Docker @('stop',"$prefix-stopped") 'stop owned selected backend' | Out-Null; Wait-Selected 'stopped.test' $false; Invoke-Docker @('restart',$controller) 'restart owned controller' | Out-Null; Wait-Until { (Http-Code 'baseline.test' '/') -eq '308' } 35 'post-restart complete reconciliation'; Assert (-not (Selected-Has 'stopped.test')) 'controller restart restored stopped route' }
    Write-Host 'PASS [discovery]: actual Docker filter/controller/selected-root lifecycle, rejection, nonpoisoning, physical network role, tuple, collision, stop, removal, and forward recovery.'
}
function Invoke-Alloy {
    $metrics = "$prefix-ts-metrics"; $lgtm = "$prefix-lgtm"; $alloy = "$prefix-alloy"; $unowned = "unowned-$([guid]::NewGuid().ToString('N').Substring(0,8))"; $metricsScript=Join-Path $temp 'metrics.py'; $alloyConfig=Join-Path $temp 'alloy.alloy'; $labRoot=Join-Path $temp 'alloy-root'; $labJournal=Join-Path $temp 'alloy-journal'
    New-Item -ItemType Directory -Force -Path "$labRoot/proc","$labRoot/sys",$labJournal | Out-Null
    @'
import socket
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('0.0.0.0',9100)); s.listen()
while True:
 c,_=s.accept(); c.recv(4096); b=b'owned_ts_metric 1\n'; c.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: '+str(len(b)).encode()+b'\r\n\r\n'+b); c.close()
'@ | Set-Content -LiteralPath $metricsScript -Encoding ascii -NoNewline
    Invoke-Docker @('run','-d','--name',$metrics,'--network',$proxy,'--label','com.docker.compose.project=ts','--label','com.docker.compose.service=metrics','--mount',"type=bind,source=$metricsScript,target=/run/metrics.py,readonly",'--entrypoint','python',$certbotImage,'/run/metrics.py') 'start private owned TS metric witness' | Out-Null; $script:owned += $metrics
    Invoke-Docker @('run','-d','--name',$lgtm,'--network',$proxy,$lgtmImage) 'start stock LGTM with its built-in remote-write receiver' | Out-Null; $script:owned += $lgtm
    Wait-Until { Invoke-Docker @('exec',$lgtm,'curl','-fsS','http://127.0.0.1:9090/-/ready') 'wait for actual stock Prometheus readiness' | Out-Null; Invoke-Docker @('exec',$lgtm,'curl','-fsS','http://127.0.0.1:3100/ready') 'wait for actual stock Loki readiness' | Out-Null; $true } 90 'stock LGTM metric and log backends' | Out-Null
    @"
discovery.docker "owned" { host = "unix:///var/run/docker.sock" }
discovery.relabel "owned" {
  targets = discovery.docker.owned.targets
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex = "/$prefix-.*"
    action = "keep"
  }
  rule {
    source_labels = ["__meta_docker_container_name"]
    regex = "/(.*)"
    target_label = "container"
  }
  rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_project"]
    target_label = "compose_project"
  }
  rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_service"]
    target_label = "compose_service"
  }
}
loki.source.docker "owned" {
  host = "unix:///var/run/docker.sock"
  targets = discovery.relabel.owned.output
  forward_to = [loki.write.lgtm.receiver]
}
loki.write "lgtm" {
  endpoint { url = "http://127.0.0.1:3100/loki/api/v1/push" }
}
prometheus.remote_write "lgtm" {
  endpoint { url = "http://127.0.0.1:9090/api/v1/write" }
}
prometheus.scrape "ts" {
  targets = [{"__address__" = "${metrics}:9100", "job" = "ts6"}]
  scrape_interval = "1s"
  scrape_timeout = "1s"
  forward_to = [prometheus.remote_write.lgtm.receiver]
}
prometheus.exporter.unix "scratch_host" {
  procfs_path = "/labroot/proc"
  sysfs_path = "/labroot/sys"
  rootfs_path = "/labroot"
}
loki.source.journal "scratch" {
  path = "/labjournal"
  matches = "_SYSTEMD_UNIT=nonexistent.service"
  labels = {service_namespace = "scratch"}
  forward_to = [loki.write.lgtm.receiver]
}
"@ | Set-Content -LiteralPath $alloyConfig -Encoding ascii
    Invoke-Docker @('run','-d','--name',$unowned,'--network',$proxy,$alpine,'sh','-ec','echo USER_CONTAINER_MARKER; sleep 300') 'start unrelated user-container privacy canary' | Out-Null; $script:owned += $unowned
    Invoke-Docker @('run','-d','--name',$alloy,'--network',"container:$lgtm",'--label','com.docker.compose.project=infra','--label','com.docker.compose.service=alloy','--mount','type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly','--mount',"type=bind,source=$alloyConfig,target=/etc/alloy/config.alloy,readonly",'--mount',"type=bind,source=$labRoot,target=/labroot,readonly",'--mount',"type=bind,source=$labJournal,target=/labjournal,readonly",$alloyImage,'run','/etc/alloy/config.alloy') 'start unprivileged exact-prefix Alloy scratch collector' | Out-Null; $script:owned += $alloy
    Assert (-not (((Invoke-Docker @('inspect',$alloy) 'inspect scratch Alloy privilege') -join "`n" | ConvertFrom-Json)[0].HostConfig.Privileged)) 'scratch Alloy ran privileged'
    Wait-Until {
        $response=((Invoke-Docker @('run','--rm','--network',"container:$lgtm",'curlimages/curl:8.12.1','-fsS','http://127.0.0.1:9090/api/v1/query?query=owned_ts_metric') 'query actual private TS metric') -join "`n") | ConvertFrom-Json
        $response.status -eq 'success' -and @($response.data.result | Where-Object { $_.metric.__name__ -eq 'owned_ts_metric' -and $_.metric.job -eq 'ts6' -and $_.value[1] -eq '1' }).Count -eq 1
    } 75 'private TS metric delivered through Alloy to LGTM' | Out-Null
    $logClient="$prefix-alloy-certbot"
    Start-Certbot $logClient $true
    foreach($role in @('nginx','controller','certbot')){
        $marker=switch($role){
            nginx {'nginx/|start worker process'}
            controller {'ingress controller:|ingress activate:'}
            certbot {'Renewing an existing certificate|Successfully received certificate|Saving debug log|Certificate is saved at'}
        }
        Wait-Until {
            $query='query={compose_project="infra",compose_service="'+$role+'"}'
            $response=((Invoke-Docker @('run','--rm','--network',"container:$lgtm",'curlimages/curl:8.12.1','-fsS','--get','--data-urlencode',$query,'--data-urlencode','limit=5000','http://127.0.0.1:3100/loki/api/v1/query_range') "query native $role logs through Alloy") -join "`n") | ConvertFrom-Json
            $response.status -eq 'success' -and $response.data.resultType -eq 'streams' -and @($response.data.result | Where-Object { $_.stream.compose_project -eq 'infra' -and $_.stream.compose_service -eq $role -and (($_.values | ForEach-Object { $_[1] }) -join "`n") -match $marker }).Count -gt 0
        } 90 "native $role markers delivered with correct project/service labels" | Out-Null
    }
    $logs=((Invoke-Docker @('run','--rm','--network',"container:$lgtm",'curlimages/curl:8.12.1','-fsS','--get','--data-urlencode','query={container=~".+"}','--data-urlencode','limit=5000','http://127.0.0.1:3100/loki/api/v1/query_range') 'query successful scratch privacy log stream') -join "`n") | ConvertFrom-Json
    Assert ($logs.status -eq 'success' -and $logs.data.resultType -eq 'streams') 'privacy query did not return successful log streams'
    $lines=@($logs.data.result | ForEach-Object { $_.values | ForEach-Object { $_[1] } })
    Assert ($lines.Count -lt 5000) 'privacy query was truncated'
    $text=$lines -join "`n"
    Assert ($text -notmatch [regex]::Escape($password) -and $text -notmatch 'owned-token' -and $text -notmatch 'USER_CONTAINER_MARKER') 'scratch Alloy leaked a secret, challenge body, or user-container log'
    foreach($private in @($metrics,$lgtm,$alloy)){
        $bindings=(((Invoke-Docker @('inspect',$private) 'inspect private scratch port bindings') -join "`n") | ConvertFrom-Json)[0].HostConfig.PortBindings
        Assert ($null -eq $bindings -or @($bindings.PSObject.Properties).Count -eq 0) "$private published monitoring ports"
    }
    Stop-Certbot $logClient
}
function Invoke-Web {
    Start-Lab
    Check 'actual stock Certbot and Pebble issue trusted hostname-valid TLS through the selected controller root' { Issue-Hosts @('baseline.test','capture.test','huginn.test'); foreach($domain in @('baseline.test','capture.test','huginn.test')){Wait-Tls $domain}; Wait-Until { (Trusted-Status 'capture.test' '/') -eq '200' } 45 'ready native capture backend through trusted TLS' | Out-Null; $uppercaseStatus=Trusted-Status 'CAPTURE.TEST' '/'; Assert ($uppercaseStatus -eq '200') "uppercase hostname did not pass the exact case-insensitive SNI guard ($uppercaseStatus)"; Assert ((Pebble-Accounts) -ge 1) 'stock Certbot did not create a Pebble account' }
    Check 'challenge handling precedes redirects and Huginn auth while plaintext application access stays closed' { Web-Run 'mkdir -p /state/.well-known/acme-challenge; printf owned-token > /state/.well-known/acme-challenge/owned' 'place owned challenge witness' | Out-Null; Assert ((Http-Code 'huginn.test' '/.well-known/acme-challenge/owned') -eq '200') 'challenge was blocked by Huginn auth'; $challenge=(Invoke-Docker @('run','--rm','--network',$proxy,'--add-host',"huginn.test`:$nginxIp",'curlimages/curl:8.12.1','-sS','http://huginn.test/.well-known/acme-challenge/owned') 'read challenge witness') -join ''; Assert ($challenge -eq 'owned-token') 'challenge body was not served directly'; $headers=Http-Headers 'huginn.test' '/' @{}; Assert ($headers -match 'HTTP/1[.]1 308' -and $headers -match '(?im)^location: https://huginn[.]test/') 'plaintext Huginn application was not redirected'; Assert ($headers -notmatch '200 OK') 'plaintext application content leaked' }
    Check 'unknown Host, unknown SNI, and valid-SNI cross-host combinations reject without serving either routed application' { $unknown=(Invoke-Docker @('run','--rm','--network',$proxy,'curlimages/curl:8.12.1','-sS','-o','/dev/null','-w','%{http_code}',"http://$nginxIp/") 'request unknown HTTP Host') -join ''; Assert ($unknown -eq '400') "unknown Host returned $unknown"; Assert-Tls-Reject 'unknown.test'; $unknownSniStatus=Trusted-Status 'capture.test' '/' @('-H','Host: unknown.test'); Assert (($unknownSniStatus -lt 200) -or ($unknownSniStatus -ge 300)) "valid-SNI unknown-Host served an application ($unknownSniStatus)"; $crossHostStatus=Trusted-Status 'capture.test' '/' @('-H','Host: baseline.test'); Assert (($crossHostStatus -lt 200) -or ($crossHostStatus -ge 300)) "crossed valid SNI/Host served a routed application ($crossHostStatus)" }
    Check 'Huginn BCrypt accepts only correct credentials and reaches the native proxy backend' {
        $missing=Trusted-Status 'huginn.test' '/'
        $wrong=Trusted-Status 'huginn.test' '/' @('-u','fixture:wrong')
        Assert ($missing -eq '401' -and $wrong -eq '401') "Huginn accepted missing or wrong BCrypt credentials ($missing/$wrong)"
        $response=Trusted-Get 'huginn.test' '/' @('-u',"fixture:$password",'-w',"`n%{http_code}")
        $separator=$response.LastIndexOf("`n")
        Assert ($separator -ge 0) 'correct-auth response omitted its HTTP status'
        $status=$response.Substring($separator+1).Trim()
        Assert ($status -eq '200') "correct BCrypt request returned HTTP $status before parsing its backend body"
        $correct=$response.Substring(0,$separator)
        Assert (($correct | ConvertFrom-Json).host -eq 'huginn.test') 'correct BCrypt credentials did not reach the selected backend'
    }
    Check 'spoofed forwarding headers are overwritten and Forwarded is cleared at the actual backend' { $spoofed=@('-H','X-Forwarded-For: 203.0.113.66','-H','X-Forwarded-Host: attacker.test','-H','X-Forwarded-Proto: http','-H','X-Forwarded-Port: 1','-H','Forwarded: for=evil'); $status=Trusted-Status 'capture.test' '/' $spoofed; Assert ($status -eq '200') "forwarding witness did not reach the backend ($status)"; $body=Trusted-Get 'capture.test' '/' $spoofed; $headers=$body | ConvertFrom-Json; Assert ($headers.host -eq 'capture.test' -and $headers.xfhost -eq 'capture.test' -and $headers.proto -eq 'https' -and $headers.port -eq '443' -and (($null -eq $headers.forwarded) -or ($headers.forwarded -eq ''))) "safe proxy headers were not overwritten: $body"; Assert ($headers.xff -notmatch '203[.]0[.]113[.]66' -and $headers.real -notmatch '203[.]0[.]113[.]66') "spoofed client IP propagated: $body" }
    Check 'actual bidirectional WebSocket upgrade exchanges a payload through TLS' { $echo=(Invoke-Docker @('run','--rm','--network',$proxy,'--add-host',"capture.test`:$nginxIp",'--entrypoint','python','--mount',"type=bind,source=$issuedPath,target=/run/issued.pem,readonly",'--mount',"type=bind,source=$websocketScript,target=/run/client.py,readonly",$certbotImage,'/run/client.py','capture.test') 'exchange an actual WebSocket payload') -join ''; Assert ($echo -eq 'owned-websocket-proof') 'WebSocket payload was not echoed end-to-end' }
    Check 'native Grafana authentication works through HTTPS without edge Huginn BasicAuth' { $grafana="$prefix-grafana"; $grafanaPassword='Grafana-'+[guid]::NewGuid().ToString('N')+'!'; Invoke-Docker @('run','-d','--name',$grafana,'--network',$proxy,'--label','com.docker.compose.project=infra','--label','ingress.enabled=true','--label','ingress.http.network=proxy','--label','ingress.http.host=grafana.test','--label','ingress.http.port=3000','--label','ingress.http.auth=none','-e','GF_AUTH_ANONYMOUS_ENABLED=false','-e','GF_USERS_ALLOW_SIGN_UP=false','-e','GF_SECURITY_ADMIN_USER=admin','-e',"GF_SECURITY_ADMIN_PASSWORD=$grafanaPassword",$lgtmImage) 'start native Grafana fixture' | Out-Null; $script:owned += $grafana; Wait-Selected 'grafana.test'; Issue-Hosts @('grafana.test'); Wait-Until { try { (Trusted-Status 'grafana.test' '/api/health') -eq '200' } catch {$false} } 90 'native Grafana through HTTPS'; $nativeHeaders=(Trusted-Get 'grafana.test' '/api/user' @('-D','-','-o','/dev/null')); Assert ($nativeHeaders -notmatch '(?i)Huginn') 'Grafana received unwanted edge Huginn auth'; $identity=Trusted-Get 'grafana.test' '/api/user' @('-u',"admin:$grafanaPassword"); Assert (($identity | ConvertFrom-Json).login -eq 'admin') 'native Grafana identity was not authenticated through the proxy' }
    Check 'malformed, empty, missing, invalid-cost, and worker-unreadable BCrypt files reject a changed candidate; forward repair recovers' {
        $active=Selected-Fingerprint
        $witness="$prefix-auth-witness"
        $cases=@(
            @{name='malformed'; command='printf "fixture:not-a-bcrypt\n" >/state/usersfile'},
            @{name='empty'; command=': >/state/usersfile'},
            @{name='missing'; command='rm -f /state/usersfile'},
            @{name='invalid cost'; command='cp /state/usersfile.valid /state/usersfile; sed -i -E ''s/\$2([aby])\$[0-9]{2}\$/\$2\1\$00\$/'' /state/usersfile'},
            @{name='worker unreadable'; command='cp /state/usersfile.valid /state/usersfile; cmp /state/usersfile /state/usersfile.valid; chmod 0600 /state/usersfile'}
        )
        foreach($fault in $cases){
            $logOffset=(Controller-Logs).Length
            Volume-Run $authVolume $fault.command "set owned Linux usersfile $($fault.name)" | Out-Null
            if($fault.name -eq 'malformed'){Run-Backend $witness 'infra' 'auth-witness.test'}
            if($fault.name -eq 'worker unreadable'){
                Invoke-Docker @('exec','--user','101:101',$controller,'sh','-ec','test "$(id -u)" = 101; test ! -r /etc/nginx/usersfile') 'prove actual worker UID cannot read unchanged valid BCrypt bytes' | Out-Null
            }
            Wait-Until { $logs=Controller-Logs; $logs.Length -gt $logOffset -and $logs.Substring($logOffset) -match 'candidate route inventory is malformed|reconciliation rejected' } 25 "fresh $($fault.name) rejection" | Out-Null
            Verify-Active-Still $active "$($fault.name) usersfile"
            Assert (-not (Selected-Has 'auth-witness.test')) "$($fault.name) usersfile allowed the changed candidate"
            Assert ((Trusted-Status 'capture.test' '/') -eq '200') "$($fault.name) usersfile disturbed unrelated loaded TLS traffic"
        }
        Volume-Run $authVolume 'cp /state/usersfile.valid /state/usersfile; chmod 0644 /state/usersfile' 'forward repair owned Linux usersfile' | Out-Null
        Wait-Selected 'auth-witness.test'
        Wait-Until { (Trusted-Status 'huginn.test' '/' @('-u',"fixture:$password")) -eq '200' } 40 'forward usersfile repair' | Out-Null
        Remove-Owned $witness
        Wait-Selected 'auth-witness.test' $false
    }
    Check 'source-rendered Manager enable/disable controls only certificate inventory and orders' { $previousPublic=$env:TS_MANAGER_PUBLIC; $previousDomain=$env:TS_MANAGER_DOMAIN; try { $env:TS_MANAGER_PUBLIC='false'; $env:TS_MANAGER_DOMAIN='manager.test'; $disabled=((Invoke-Docker @('compose','--env-file',"$repo/ts/.env.example",'-f',"$repo/ts/compose.yml",'config','--format','json') 'render source Manager disabled') -join "`n" | ConvertFrom-Json -AsHashtable).services['manager-frontend'].labels['ingress.enabled']; $env:TS_MANAGER_PUBLIC='true'; $enabled=((Invoke-Docker @('compose','--env-file',"$repo/ts/.env.example",'-f',"$repo/ts/compose.yml",'config','--format','json') 'render source Manager enabled') -join "`n" | ConvertFrom-Json -AsHashtable).services['manager-frontend'].labels['ingress.enabled']; Assert ($disabled -eq 'false' -and $enabled -eq 'true') 'source-rendered Manager visibility did not toggle exact ingress label'; Run-Backend "$prefix-manager-disabled" 'ts' 'manager.test' 'none' -Disabled; Start-Sleep -Seconds 2; Assert (-not (Selected-Has 'manager.test')) 'disabled Manager entered certificate inventory'; $orders=Pebble-Orders; $idle="$prefix-manager-idle"; Start-Certbot $idle $true; Start-Sleep -Seconds 4; Stop-Certbot $idle; Assert ((Pebble-Orders) -eq $orders) 'disabled Manager created a CA order'; Remove-Owned "$prefix-manager-disabled"; Run-Backend "$prefix-manager-enabled" 'ts' 'manager.test'; Wait-Selected 'manager.test'; Issue-Hosts @('manager.test'); Wait-Tls 'manager.test'; Remove-Owned "$prefix-manager-enabled"; Wait-Selected 'manager.test' $false; $orders=Pebble-Orders; $idle="$prefix-manager-renew"; Start-Certbot $idle $true; Start-Sleep -Seconds 4; Stop-Certbot $idle; Assert ((Pebble-Orders) -eq $orders) 'disabled Manager renewal inventory created an order' } finally { $env:TS_MANAGER_PUBLIC=$previousPublic; $env:TS_MANAGER_DOMAIN=$previousDomain } }
    Check 'unprivileged exact-prefix Alloy scratch scope delivers private TS metrics and ingress/controller/Certbot markers without log leakage' { Invoke-Alloy }
    Write-Host 'PASS [web]: pinned Pebble/stock Certbot trusted TLS, challenge boundary, Host/SNI, BCrypt, native Grafana, headers, WebSocket, usersfile forward recovery, and source-rendered Manager issuance inventory.'
}

$script:owned=@(); $temp=Join-Path ([IO.Path]::GetTempPath()) ('arazel-discovery-web-'+[guid]::NewGuid().ToString('N')); $backendScript=Join-Path $temp 'backend.py'; $websocketScript=Join-Path $temp 'websocket.py'; $pebbleConfig=Join-Path $temp 'pebble.json'; $endpointCa=Join-Path $temp 'endpoint.pem'; $issuedPath=Join-Path $temp 'issued.pem'; $password='Fixture-'+[guid]::NewGuid().ToString('N')
try {
    if($Case -eq 'all') { & $PSCommandPath -Case discovery -Image $Image; if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}; & $PSCommandPath -Case web -Image $Image; exit $LASTEXITCODE }
    if($Case -eq 'discovery'){Invoke-Discovery}else{Invoke-Web}
} catch {
    Write-Host "--- $Case native gate failure ---"; Write-Host $_
    $diagnosticContainers=@($controller,$nginx,$socket,$pebble,$dns)
    if($prefix){$diagnosticContainers+=@("$prefix-alloy","$prefix-ts-metrics","$prefix-alloy-certbot")}
    foreach($container in $diagnosticContainers){if($container){Write-Host "--- $container ---"; & docker.exe logs $container --tail 120 2>&1}}
    throw
} finally {
    if($prefix){foreach($container in @(& docker.exe ps -aq --filter "name=$prefix")){if($container){& docker.exe rm -f $container 2>$null|Out-Null}}}
    foreach($container in @($script:owned | Select-Object -Unique)){& docker.exe rm -f $container 2>$null | Out-Null}
    foreach($volume in @($certVolume,$webVolume,$configVolume,$selectedVolume,$runtimeVolume,$authVolume)){if($volume){& docker.exe volume rm $volume 2>$null | Out-Null}}
    foreach($network in @($control,$proxy,$stream,$wrong)){if($network){& docker.exe network rm $network 2>$null | Out-Null}}
    if(Test-Path $temp){Remove-Item -Force -Recurse $temp}
}
