param(
    [ValidateSet('all','acme-lifecycle','discovery','web','transparency','routing-lifecycle','compose-boundary')]
    [string]$Case = 'acme-lifecycle',
    [string]$Image = 'arazel-nginx:local'
)

$ErrorActionPreference = 'Stop'
if($Case -ne 'acme-lifecycle'){
    switch($Case){
        'all' {
            & $PSCommandPath -Case acme-lifecycle -Image $Image
            & "$PSScriptRoot/test-nginx-discovery-web.ps1" -Case all -Image $Image
            & "$PSScriptRoot/test-nginx-transparency.ps1" -Image $Image
            & $PSCommandPath -Case routing-lifecycle -Image $Image
            & "$PSScriptRoot/test-nginx-compose-boundary.ps1" -Image $Image
        }
        {$_ -in 'discovery','web'} { & "$PSScriptRoot/test-nginx-discovery-web.ps1" -Case $Case -Image $Image }
        'transparency' { & "$PSScriptRoot/test-nginx-transparency.ps1" -Image $Image }
        'routing-lifecycle' {
            foreach($routingCase in 'policy','readiness','serve-readiness','lifecycle'){ & "$PSScriptRoot/nginx-routing-lab.ps1" -Case $routingCase }
        }
        'compose-boundary' { & "$PSScriptRoot/test-nginx-compose-boundary.ps1" -Image $Image }
    }
    return
}
$certbotImage = 'certbot/certbot:v5.8.0@sha256:f70ad0adbb7e117f0fe42a63c553f28ea451edabc0148757b6efcd9735acaa20'
$pebbleImage = 'ghcr.io/letsencrypt/pebble@sha256:ddf230642b1a584f519f32e347de1b05a6e4c1f6c35c1863b33effeab5f78199'
$challengeImage = 'ghcr.io/letsencrypt/pebble-challtestsrv@sha256:12ce21884def456bcf9786542113949e1f19dc7738d2c70e156c2d0c38a1405b'
$repo = Split-Path -Parent $PSScriptRoot

function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Invoke-Docker([string[]]$Arguments, [string]$Description) {
    $output = & docker @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Docker failed ($Description): $($output -join [Environment]::NewLine)" }
    return $output
}
function Wait-Until([scriptblock]$Probe, [int]$Seconds, [string]$Description) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds); $last = $null
    while ([DateTime]::UtcNow -lt $until) { try { $value = & $Probe; if ($value) { return $value } } catch { $last = $_ }; Start-Sleep -Milliseconds 500 }
    if ($last) { throw "Timed out waiting for ${Description}: $last" }; throw "Timed out waiting for $Description"
}
function Port([string]$Container, [string]$Port) { return [int]((Invoke-Docker @('port',$Container,$Port) "port $Port" | Select-Object -First 1) -replace '^.*:','') }
function Ip([string]$Subnet,[byte]$Offset) { $b=[Net.IPAddress]::Parse(($Subnet -split '/')[0]).GetAddressBytes(); $b[3]+=$Offset; return ([Net.IPAddress]::new($b)).ToString() }
function Orders { return @((& docker logs $pebble 2>&1) | Where-Object { $_ -match 'POST /order-plz' }).Count }
function Accounts { return @((& docker logs $pebble 2>&1) | Where-Object { $_ -match 'POST /sign-me-up' }).Count }
function Account-Fingerprint {
    return ((Invoke-Docker @('run','--rm','--mount',"type=volume,source=$certVolume,target=/state,readonly",'alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0','sh','-ec','test -d /state/accounts; find /state/accounts -type f -exec sha256sum {} + | sort | sha256sum') 'fingerprint persisted account contents without disclosure') -join '')
}
function Workers { return ((Invoke-Docker @('exec',$nginx,'sh','-ec','pgrep -P $(cat /var/run/nginx.pid) -f "nginx: worker process" | sort | tr "\n" " "') 'read nginx workers') -join '') }
function Master { return ((Invoke-Docker @('exec',$nginx,'sh','-ec','pid=$(cat /var/run/nginx.pid); printf "%s:" "$pid"; awk "{print \$22}" /proc/$pid/stat') 'read stable nginx master identity') -join '') }
function Expiry([string]$Certificate) {
    $value=[regex]::Replace($Certificate.Split(';')[1].Substring(9), '\s+', ' ')
    return [DateTimeOffset]::ParseExact($value, "MMM d HH:mm:ss yyyy 'GMT'", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
}
function Set-DnsDefault([string]$Ip) { $port=Port $dns '8055/tcp'; $result=& curl.exe --noproxy '*' --fail --silent --show-error -X POST --data ('{"ip":"'+$Ip+'"}') "http://127.0.0.1:$port/set-default-ipv4" 2>&1; if($LASTEXITCODE -ne 0){throw "could not set challenge DNS default: $($result -join [Environment]::NewLine)"} }
function Token { return (Invoke-Docker @('run','--rm','--mount',"type=volume,source=$certVolume,target=/state,readonly",'alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0','sh','-ec','test -s /state/.ingress-renewed && cat /state/.ingress-renewed') 'read publication hint') }
function Cert([string]$Domain='app.test') {
    $probe='openssl s_client -connect app.test:443 -servername app.test -verify_return_error -verify_hostname app.test -CAfile /run/acme-test/issued.pem -showcerts </dev/null > /tmp/handshake 2>/tmp/verify; status=$?; printf "HANDSHAKE_STATUS=%s\n" "$status" >&2; cat /tmp/verify >&2; awk ''/BEGIN CERTIFICATE/{keep=1} keep {print} /END CERTIFICATE/{exit}'' /tmp/handshake >/tmp/leaf.pem; openssl x509 -noout -serial -enddate -in /tmp/leaf.pem'
    $probe=$probe.Replace('app.test',$Domain)
    try { $output=Invoke-Docker @('run','--rm','--network',$network,'--add-host',"${Domain}:$nginxIp",'--entrypoint','sh','--mount',"type=bind,source=$issuedPath,target=/run/acme-test/issued.pem,readonly",$certbotImage,'-ec',$probe) 'verify and inspect the TLS wire leaf' } catch { $script:TlsDiagnostic=$_.Exception.Message; return $null }
    $wire=[string]::Join("`n", @($output)); if ($wire -notmatch '(?m)^HANDSHAKE_STATUS=0\r?$') { $script:TlsDiagnostic="stock TLS handshake status: $wire"; return $null }; $serial=$output | Where-Object { "$_" -like 'serial=*' } | Select-Object -First 1; $enddate=$output | Where-Object { "$_" -like 'notAfter=*' } | Select-Object -First 1; if ($serial -and $enddate) { return "$serial;$enddate" }; return $null
}
function Rejects-Tls {
    $probe='openssl s_client -connect app.test:443 -servername app.test -verify_return_error -verify_hostname app.test -CAfile /run/acme-test/issued.pem -showcerts </dev/null >/tmp/reject.out 2>/tmp/reject.err; status=$?; cat /tmp/reject.out /tmp/reject.err; [ "$status" -ne 0 ] && grep -q "SSL alert number 112" /tmp/reject.err && ! grep -q "BEGIN CERTIFICATE" /tmp/reject.out'
    try { Invoke-Docker @('run','--rm','--network',$network,'--add-host',"app.test:$nginxIp",'--entrypoint','sh','--mount',"type=bind,source=$issuedPath,target=/run/acme-test/issued.pem,readonly",$certbotImage,'-c',$probe) 'observe actual bootstrap TLS rejection alert' | Out-Null; return $true }
    catch { $script:TlsDiagnostic=$_.Exception.Message; return $false }
}
function Start-Filter([string]$Configuration="$repo/infra/nginx/docker-socket-proxy.cfg") {
    Invoke-Docker @('run','-d','--name',$socketProxy,'--user','0:0','--network',$controlNetwork,'--network-alias','socket-proxy','--entrypoint','haproxy','--mount','type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock,readonly','--mount',"type=bind,source=$Configuration,target=/opt/ingress/docker-socket-proxy.cfg,readonly",'tecnativa/docker-socket-proxy@sha256:1f5038b54f06c3e18422902cf00ba21803d1c97805aae032e5e6673d532d3459','-W','-db','-f','/opt/ingress/docker-socket-proxy.cfg') 'start actual narrow metadata filter' | Out-Null
}
function Render-Labels {
    return Invoke-Docker @('run','--rm','--network',$controlNetwork,'--entrypoint','docker-gen','--mount',"type=volume,source=$configVolume,target=/run/nginx-config",'-e','DOCKER_HOST=tcp://socket-proxy:2375','-e','INGRESS_ENVIRONMENT=lab','-e',"INGRESS_LAB_NETWORK_PREFIX=$prefix-",$Image,'-config','/etc/docker-gen/docker-gen-once.cfg') 'render actual filtered Docker labels'
}
function Set-Hosts([string[]]$Hosts, [switch]$ExpectInvalid, [int]$BackendPort=8080, [switch]$Recreate) {
    foreach($hostName in @($backends.Keys)){
        if($Recreate -or $hostName -notin $Hosts){Invoke-Docker @('rm','-f',$backends[$hostName]) 'remove owned label publisher' | Out-Null; $backends.Remove($hostName)}
    }
    foreach($hostName in $Hosts){
        if($backends.ContainsKey($hostName)){continue}
        $name="$prefix-backend-$($backends.Count)-$([guid]::NewGuid().ToString('N').Substring(0,6))"
        Invoke-Docker @('run','-d','--name',$name,'--network',$network,'--label','com.docker.compose.project=infra','--label','ingress.enabled=true','--label','ingress.http.network=proxy','--label',"ingress.http.host=$hostName",'--label',"ingress.http.port=$BackendPort",'--label','ingress.http.auth=none','--mount',"type=bind,source=$responderPath,target=/run/responder.sh,readonly",'alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0','sh','-ec',"exec nc -lk -p $BackendPort -e sh /run/responder.sh") 'start real opted-in HTTP backend' | Out-Null
        $backends[$hostName]=$name
    }
    if($script:filterStarted){
        $failed=$false; try { Render-Labels | Out-Null } catch { if(-not $ExpectInvalid){throw}; $failed=$true }
        if($ExpectInvalid){Assert $failed 'invalid labelled snapshot was accepted'}
    }
}
function Start-Nginx([string]$CertificatesVolume, [switch]$AssertWaitingForController) {
    & docker.exe rm -f $controller 2>$null | Out-Null
    Invoke-Docker @('run','-d','--name',$nginx,'--network',"container:$netnsHost",'--mount',"type=volume,source=$CertificatesVolume,target=/etc/letsencrypt,readonly",'--mount',"type=volume,source=$webVolume,target=/var/www/certbot,readonly",'--mount',"type=volume,source=$configVolume,target=/run/nginx-config,readonly",'--mount',"type=volume,source=$selectedVolume,target=/run/nginx-selected,readonly",'--mount',"type=volume,source=$runtimeVolume,target=/run/nginx-runtime",$Image) 'start actual ingress in owned host network namespace' | Out-Null
    if ($AssertWaitingForController) {
        Start-Sleep -Seconds 2
        Assert ($null -eq (Cert)) 'new ingress served persisted TLS before its own controller authorized startup'
    }
    Invoke-Docker @('run','-d','--name',$controller,'--network',$controlNetwork,'--pid',"container:$nginx",'--entrypoint','/usr/local/sbin/controller.sh','--mount',"type=volume,source=$CertificatesVolume,target=/etc/letsencrypt,readonly",'--mount',"type=volume,source=$webVolume,target=/var/www/certbot,readonly",'--mount',"type=volume,source=$configVolume,target=/run/nginx-config",'--mount',"type=volume,source=$selectedVolume,target=/run/nginx-selected",'--mount',"type=volume,source=$runtimeVolume,target=/run/nginx-master-runtime,readonly",'-e','NGINX_MASTER_RUNTIME=/run/nginx-master-runtime','-e','DOCKER_HOST=tcp://socket-proxy:2375','-e','INGRESS_ENVIRONMENT=lab','-e',"INGRESS_LAB_NETWORK_PREFIX=$prefix-",'-e','CONTROLLER_RECONCILE_SECONDS=1','-e','ACME_ENVIRONMENT=lab','-e','ACME_DIRECTORY=https://localhost:14000/dir',$Image,'run') 'start sole real label controller' | Out-Null
    Wait-Until { try { Master } catch { $null } } 45 'NGINX master after actual controller bootstrap' | Out-Null
}
function Invoke-Certbot([string]$Mode, [bool]$Consent, [bool]$Force=$false, [int]$Timeout=180, [string]$Name='', [string[]]$ExtraArguments=@(), [string]$CertificatesVolume=$certVolume) {
    $args=@('run','--rm','--network',$network,'--dns',$dnsIp,'--add-host',"localhost:$pebbleIp",'--entrypoint','sh',
        '--mount',"type=volume,source=$CertificatesVolume,target=/etc/letsencrypt",'--mount',"type=volume,source=$webVolume,target=/var/www/certbot",'--mount',"type=volume,source=$selectedVolume,target=/run/nginx-selected,readonly",'--mount',"type=bind,source=$caPath,target=/run/acme-test/endpoint-ca.pem,readonly",'--mount',"type=bind,source=$repo/infra/nginx/certificates.sh,target=/opt/ingress/certificates.sh,readonly",
        '-e','REQUESTS_CA_BUNDLE=/run/acme-test/endpoint-ca.pem','-e','ACME_EMAIL=lab@example.test','-e','ACME_ENVIRONMENT=lab','-e','ACME_DIRECTORY=https://localhost:14000/dir','-e','ACME_TERMS_DIRECTORY=https://localhost:14000/dir','-e',"ACME_ACCEPT_TERMS=$($Consent.ToString().ToLowerInvariant())",'-e',"CERTBOT_COMMAND_TIMEOUT_SECONDS=$Timeout",'-e','CERTBOT_POLL_SECONDS=1','-e','CERTBOT_RENEW_SECONDS=3600','-e','CERTBOT_RETRY_SECONDS=2')
    if ($Name) { $args += @('-d','--name',$Name) }
    if ($Force) { $args += @('-e','CERTBOT_FORCE_RENEWAL=true') }
    $args += $ExtraArguments
    $args += @($certbotImage,'/opt/ingress/certificates.sh',$Mode)
    return Invoke-Docker $args "Certbot $Mode"
}
function Invoke-Activation([string[]]$ExtraArguments=@(), [string]$Name='') {
    $args=@('run','--network','none','--pid',"container:$nginx",'--entrypoint','sh','--mount',"type=volume,source=$certVolume,target=/etc/letsencrypt,readonly",'--mount',"type=volume,source=$webVolume,target=/var/www/certbot,readonly",'--mount',"type=volume,source=$configVolume,target=/run/nginx-config",'--mount',"type=volume,source=$selectedVolume,target=/run/nginx-selected",'--mount',"type=volume,source=$runtimeVolume,target=/run/nginx-master-runtime,readonly",'-e','NGINX_MASTER_RUNTIME=/run/nginx-master-runtime','-e','ACME_ENVIRONMENT=lab','-e','ACME_DIRECTORY=https://localhost:14000/dir')
    if ($Name) { $args += @('-d','--name',$Name) } else { $args += '--rm' }
    $args += $ExtraArguments
    $args += @($Image,'/usr/local/sbin/activate.sh','activate')
    return Invoke-Docker $args 'activate actual candidate against the shared master'
}
function Controller-Signal([string]$Signal) {
    if($Signal -eq 'CONT'){Invoke-Docker @('unpause',$controller) 'resume only the owned controller' | Out-Null; return}
    if($Signal -ne 'STOP'){throw 'Unsupported controller control'}
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    do {
        Invoke-Docker @('pause',$controller) 'freeze only the owned controller' | Out-Null
        $probe=& docker.exe run --rm --network none --entrypoint flock --mount "type=volume,source=$configVolume,target=/run/nginx-config" $Image -n -E 75 /run/nginx-config/.activate.lock true 2>&1
        $status=$LASTEXITCODE
        if($status -eq 0){return}
        Invoke-Docker @('unpause',$controller) 'allow current transaction to release its native lock' | Out-Null
        if($status -ne 75){throw "Native activation-lock probe failed: $($probe -join ' ')"}
        Start-Sleep -Milliseconds 100
    } while([DateTime]::UtcNow -lt $deadline)
    throw 'Could not freeze controller between activation transactions'
}
function Client-Child([string]$Container) {
    $output=& docker top $Container -eo pid,args 2>$null
    return $LASTEXITCODE -eq 0 -and @($output | Where-Object { "$_" -match 'certbot (renew|certonly)( |$)' }).Count -gt 0
}
function Wait-New-Cert([string]$Before, [string]$Description, [string]$Domain='app.test') {
    return Wait-Until { $value=Cert $Domain; if ($value -and $value.Split(';')[0] -ne $Before.Split(';')[0]) { $value } } 90 $Description
}
function Cert-Files([string]$Command) {
    return Invoke-Docker @('run','--rm','--mount',"type=volume,source=$certVolume,target=/state",'alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0','sh','-ec',$Command) 'inspect or fault only the owned certificate tree'
}
function State { return ((Invoke-Docker @('exec',$nginx,'cat','/run/nginx-config/.certificate-state') 'read acknowledged generation') -join '') }
function Selection { return ((Invoke-Docker @('exec',$nginx,'sha256sum','/run/nginx-selected/nginx.conf') 'fingerprint selected full root') -join '') }

$id=[guid]::NewGuid().ToString('N').Substring(0,12); $prefix="arazel-certbot-$id"; $network="$prefix-proxy"; $controlNetwork="$prefix-control"; $socketProxy="$prefix-socket-proxy"; $netnsHost="$prefix-netns"; $controller="$prefix-controller"; $pebble="$prefix-pebble"; $dns="$prefix-dns"; $nginx="$prefix-nginx"; $certVolume="$prefix-cert"; $webVolume="$prefix-web"; $configVolume="$prefix-config"; $selectedVolume="$prefix-selected"; $runtimeVolume="$prefix-runtime"; $lostVolume="$prefix-lost"; $temp=Join-Path ([IO.Path]::GetTempPath()) $prefix; $caPath=Join-Path $temp 'endpoint-ca.pem'; $issuedPath=Join-Path $temp 'issued.pem'; $configPath=Join-Path $temp 'pebble.json'; $responderPath=Join-Path $temp 'responder.sh'; $backends=@{}; $filterStarted=$false; $created=@(); $paused=$false
try {
    Invoke-Docker @('image','inspect',$Image) 'inspect built nginx image' | Out-Null
    Invoke-Docker @('run','--rm','--entrypoint','sh','--mount',"type=bind,source=$repo/infra/nginx/certificates.sh,target=/opt/ingress/certificates.sh,readonly",$certbotImage,'-ec','command -v sh; command -v certbot; sh -n /opt/ingress/certificates.sh') 'verify stock Certbot shell and wrapper' | Out-Null
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    @'
#!/bin/sh
while IFS= read -r line; do
    [ -n "$line" ] && [ "$line" != "$(printf '\r')" ] || break
done
printf 'HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nbackend'
'@ | Set-Content -LiteralPath $responderPath -Encoding ascii -NoNewline
    @'
{"pebble":{"listenAddress":"0.0.0.0:14000","managementListenAddress":"0.0.0.0:15000","certificate":"test/certs/localhost/cert.pem","privateKey":"test/certs/localhost/key.pem","httpPort":80,"tlsPort":443,"ocspResponderURL":"","externalAccountBindingRequired":false,"domainBlocklist":["aaa-blocked.test"],"retryAfter":{"authz":1,"order":1},"keyAlgorithm":"ecdsa","profiles":{"default":{"description":"lab","validityPeriod":3600}}}}
'@ | Set-Content -LiteralPath $configPath -Encoding ascii
    Invoke-Docker @('network','create',$network) 'create isolated proxy network' | Out-Null; $created += $network
    Invoke-Docker @('network','create','--internal',$controlNetwork) 'create isolated metadata control network' | Out-Null; $created += $controlNetwork
    $subnet=((Invoke-Docker @('network','inspect',$network) 'inspect network' | ConvertFrom-Json)[0].IPAM.Config[0].Subnet); $dnsIp=Ip $subnet 2; $pebbleIp=Ip $subnet 3; $nginxIp=Ip $subnet 4
    foreach($v in @($certVolume,$webVolume,$configVolume,$selectedVolume,$runtimeVolume,$lostVolume)) { Invoke-Docker @('volume','create',$v) "create isolated volume $v" | Out-Null; $created += $v }

    Invoke-Docker @('run','-d','--name',$dns,'--network',$network,'--ip',$dnsIp,'-p','127.0.0.1::8055/tcp',$challengeImage,'-defaultIPv4',$nginxIp,'-defaultIPv6','') 'start controlled DNS' | Out-Null; $created += $dns
    Invoke-Docker @('run','-d','--name',$pebble,'--network',$network,'--ip',$pebbleIp,'--dns',$dnsIp,'-p','127.0.0.1::15000/tcp','--mount',"type=bind,source=$configPath,target=/test/pebble.json,readonly",'-e','PEBBLE_VA_NOSLEEP=1','-e','PEBBLE_WFE_NONCEREJECT=0','-e','PEBBLE_AUTHZREUSE=0',$pebbleImage,'-config','/test/pebble.json','-strict','-dnsserver',"$dnsIp`:8053") 'start Pebble' | Out-Null; $created += $pebble
    Wait-Until { ((& docker logs $pebble 2>&1) -join "`n") -match 'Pebble.*ready|Starting Pebble' } 30 'Pebble startup' | Out-Null
    Invoke-Docker @('cp',"$pebble`:/test/certs/pebble.minica.pem",$caPath) 'copy endpoint CA' | Out-Null
    $management=Port $pebble '15000/tcp'; & curl.exe --noproxy '*' --ssl-no-revoke --fail --silent --cacert $caPath "https://localhost:$management/roots/0" --output $issuedPath; if($LASTEXITCODE -ne 0){throw 'could not read issued certificate root'}
    Invoke-Docker @('run','-d','--name',$netnsHost,'--network',$network,'--ip',$nginxIp,'-p','127.0.0.1::80/tcp','-p','127.0.0.1::443/tcp','alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0','sleep','900') 'create owned ingress host network namespace' | Out-Null
    Set-Hosts -Hosts @('app.test')
    Start-Filter | Out-Null
    $filterStarted=$true
    Start-Nginx $certVolume | Out-Null; $created += $nginx; $http=Port $netnsHost '80/tcp'
    Assert (Rejects-Tls) 'pre-issuance default TLS did not reject handshakes'
    $challengeCode=& curl.exe --noproxy '*' --silent --output NUL --write-out '%{http_code}' --resolve "app.test:$http`:127.0.0.1" "http://app.test:$http/.well-known/acme-challenge/missing"; Assert ($challengeCode -eq '404') "challenge bootstrap was unavailable ($challengeCode)"
    Write-Host 'CASE: explicit consent and complete inventory trust boundary'
    Invoke-Certbot -Mode run -Consent $false -Name "$prefix-client" | Out-Null
    Start-Sleep -Seconds 3
    Assert ((Orders) -eq 0 -and (Accounts) -eq 0) 'false-consent scheduler contacted the account or order endpoint'
    Invoke-Docker @('rm','-f',"$prefix-client") 'stop false-consent scheduler' | Out-Null
    foreach ($directory in @('', 'https://localhost:14000/wrong-directory')) {
        $failed=$false
        try { Invoke-Certbot -Mode renew -Consent $true -ExtraArguments @('-e',"ACME_TERMS_DIRECTORY=$directory") | Out-Null } catch { $failed=$true }
        Assert $failed 'absent or mismatched explicit terms directory was accepted'
        Assert ((Orders) -eq 0 -and (Accounts) -eq 0) 'invalid explicit terms contacted the CA'
    }
    $selection=Selection
    Set-Hosts -Hosts @('app.test','bad!.test') -ExpectInvalid
    Assert ((Selection) -eq $selection) 'invalid whole label snapshot replaced the selected full root'
    $invalidInventory=Join-Path $temp 'invalid-inventory.conf'
    $root=Invoke-Docker @('exec',$nginx,'cat','/run/nginx-selected/nginx.conf') 'copy actual selected root for issuer-only negative fault'
    (($root -join "`n")+"`n# ingress-certificate: bad!.test`n") | Set-Content -LiteralPath $invalidInventory -Encoding ascii
    $failed=$false
    try { Invoke-Certbot renew $true -ExtraArguments @('--mount',"type=bind,source=$invalidInventory,target=/run/nginx-selected/nginx.conf,readonly") | Out-Null } catch { $failed=$true }
    Assert $failed 'mixed valid/invalid selected issuer inventory was accepted'
    Assert ((Orders) -eq 0 -and (Accounts) -eq 0) 'invalid inventory contacted the CA'
    Set-Hosts -Hosts @('app.test')

    Write-Host 'CASE: same initial client across CA pause and trusted bootstrap transition'
    Invoke-Docker @('pause',$pebble) 'pause owned CA' | Out-Null; $paused=$true
    Invoke-Certbot -Mode run -Consent $true -Name "$prefix-client" | Out-Null
    Start-Sleep -Seconds 2
    Assert (Rejects-Tls) 'TLS accepted before initial issuance completed'
    Invoke-Docker @('unpause',$pebble) 'resume the same CA and client' | Out-Null; $paused=$false
    $leaf=Wait-Until { Cert } 90 'trusted initial TLS'
    $hint=Wait-Until { try { Token } catch { $null } } 30 'real initial deploy hook'
    Invoke-Docker @('rm','-f',"$prefix-client") 'stop initial scheduler' | Out-Null
    $master=Master; $workers=Workers; $ack=State
    Assert ((Accounts) -eq 1) 'initial successful issuance did not create exactly one account'

    Write-Host 'CASE: unchanged scheduler does not invoke Certbot or rotate workers'
    $orders=Orders
    Invoke-Certbot -Mode run -Consent $true -Name "$prefix-watch" | Out-Null
    for ($i=0; $i -lt 6; $i++) {
        Assert (-not (Client-Child "$prefix-watch")) 'idle scheduler started a client'
        Start-Sleep -Milliseconds 500
    }
    Invoke-Docker @('rm','-f',"$prefix-watch") 'stop idle scheduler' | Out-Null
    Assert ((Orders) -eq $orders -and (Token) -eq $hint -and (Workers) -eq $workers -and (Master) -eq $master) 'idle scheduler changed CA/publication/native workers'

    Write-Host 'CASE: live controller restart preserves an unchanged acknowledged generation'
    $readyBefore=(Invoke-Docker @('exec',$controller,'cat','/run/nginx-config/.controller-ready') 'read validated ready generation') -join ''
    Start-Sleep -Seconds 1
    Invoke-Docker @('restart',$controller) 'restart only owned live controller' | Out-Null
    Wait-Until { $readyNow=(Invoke-Docker @('exec',$controller,'cat','/run/nginx-config/.controller-ready') 'observe new validated reconciliation') -join ''; $readyNow -ne $readyBefore } 30 'fresh successful reconciliation after live controller restart' | Out-Null
    Assert ((Orders) -eq $orders -and (Token) -eq $hint -and (Workers) -eq $workers -and (Master) -eq $master) 'unchanged controller restart invoked client or rotated native workers'

    Write-Host 'CASE: cached discovery cannot bless controller startup during Docker API outage'
    Invoke-Docker @('stop','--time','1',$socketProxy) 'stop only owned metadata filter' | Out-Null
    Invoke-Docker @('restart',$controller) 'restart controller with cached inventory and unavailable API' | Out-Null
    Start-Sleep -Seconds 4
    Invoke-Docker @('exec',$nginx,'test','!','-e','/run/nginx-config/.controller-ready') 'reject stale cached readiness' | Out-Null
    Assert ((Cert).Split(';')[0] -eq $leaf.Split(';')[0] -and (Workers) -eq $workers -and (Master) -eq $master -and (Orders) -eq $orders) 'metadata outage replaced loaded TLS/workers or invoked the CA'
    Invoke-Docker @('start',$socketProxy) 'restore actual metadata filter' | Out-Null
    Invoke-Docker @('restart',$controller) 'reconcile fresh metadata after outage' | Out-Null
    Wait-Until { Invoke-Docker @('exec',$nginx,'test','-s','/run/nginx-config/.controller-ready') 'observe fresh ready reconciliation' | Out-Null; $true } 30 'fresh metadata recovery' | Out-Null
    Assert ((Workers) -eq $workers -and (Master) -eq $master) 'metadata recovery reloaded unchanged inputs'

    Write-Host 'CASE: successful Docker list/version cannot hide failed container inspections'
    $denyInspect=Join-Path $temp 'deny-inspect.cfg'
    $filter=[IO.File]::ReadAllText("$repo/infra/nginx/docker-socket-proxy.cfg")
    $filter.Replace('    http-request deny unless METH_GET', "    http-request deny unless METH_GET"+"`n"+'    http-request deny if { path_reg ^(/v[0-9]+[.][0-9]+)?/containers/[a-zA-Z0-9_.-]+/json$ }') | Set-Content -LiteralPath $denyInspect -Encoding ascii
    Invoke-Docker @('rm','-f',$socketProxy) 'replace only owned metadata filter for inspect fault' | Out-Null
    Start-Filter $denyInspect | Out-Null
    foreach($endpoint in 'version','containers/json'){
        $code=Wait-Until { (Invoke-Docker @('exec',$controller,'curl','--noproxy','*','--silent','--output','/dev/null','--write-out','%{http_code}',"http://socket-proxy:2375/$endpoint") 'probe healthy list/version under inspect fault') -join '' } 10 'fault filter listening'
        Assert ($code -eq '200') 'partial-inspection fault also broke Docker list/version preflight'
    }
    $code=(Invoke-Docker @('exec',$controller,'curl','--noproxy','*','--silent','--output','/dev/null','--write-out','%{http_code}',"http://socket-proxy:2375/containers/$($backends['app.test'])/json") 'observe actual inspect denial') -join ''
    Assert ($code -eq '403') 'container-inspection fault was not installed'
    $selection=Selection
    Invoke-Docker @('restart',$controller) 'restart controller while list succeeds and inspect fails' | Out-Null
    Start-Sleep -Seconds 4
    Invoke-Docker @('exec',$nginx,'test','!','-e','/run/nginx-config/.controller-ready') 'reject partial metadata readiness' | Out-Null
    Assert ((Cert).Split(';')[0] -eq $leaf.Split(';')[0] -and (Selection) -eq $selection -and (Workers) -eq $workers -and (Master) -eq $master -and (Orders) -eq $orders) 'partial metadata removed a loaded route or changed TLS/workers/CA'
    Invoke-Docker @('rm','-f',$socketProxy) 'remove only owned inspect-fault filter' | Out-Null
    Start-Filter | Out-Null
    Invoke-Docker @('restart',$controller) 'recover controller from fresh complete Docker inspection' | Out-Null
    Wait-Until { Invoke-Docker @('exec',$nginx,'test','-s','/run/nginx-config/.controller-ready') 'observe complete metadata readiness' | Out-Null; $true } 30 'complete metadata forward recovery' | Out-Null
    Assert ((Cert).Split(';')[0] -eq $leaf.Split(';')[0] -and (Workers) -eq $workers -and (Master) -eq $master) 'complete metadata recovery changed unchanged loaded routes'
    Write-Host 'CASE: real renewal, strict validity advancement and stable native master'
    Invoke-Certbot renew $true $true | Out-Null
    $next=Wait-New-Cert $leaf 'forced stock-client renewal'
    Assert ((Expiry $next) -gt (Expiry $leaf)) 'renewal validity did not advance'
    Assert ((Workers) -ne $workers -and (Master) -eq $master) 'renewal lacked a stable-master worker acknowledgement'
    $leaf=$next; $workers=Workers; $hint=Token

    Write-Host 'CASE: genuine failed deploy hook with successful publication and fingerprint reload'
    $hintPath=Join-Path $temp 'blocked-hint'; Set-Content -LiteralPath $hintPath -Value $hint -NoNewline -Encoding ascii
    $orders=Orders
    try { Invoke-Certbot -Mode renew -Consent $true -Force $true -ExtraArguments @('--mount',"type=bind,source=$hintPath,target=/etc/letsencrypt/.ingress-renewed,readonly") | Out-Null } catch { Write-Host 'Stock client reported the intentionally failed hook.' }
    $next=Wait-New-Cert $leaf 'new published leaf despite failed hint rename'
    Assert ((Token) -eq $hint -and (Orders) -eq ($orders+1)) 'failed-hook case changed the original hint or did not perform exactly one real order'
    Assert ((Workers) -ne $workers -and (Master) -eq $master -and (Expiry $next) -gt (Expiry $leaf)) 'fingerprint-only recovery lacked native acknowledgement or validity advancement'
    $leaf=$next; $workers=Workers
    Invoke-Certbot notify $false | Out-Null; Start-Sleep -Seconds 2
    Assert ((Workers) -eq $workers -and (Master) -eq $master -and (Orders) -eq ($orders+1)) 'hint-only notification caused a reload or order'

    foreach ($fault in @('CA','HTTP01')) {
        Write-Host "CASE: $fault failure and automatic recovery in the SAME scheduler"
        $hint=Token; $workers=Workers; $orders=Orders
        if ($fault -eq 'CA') { Invoke-Docker @('pause',$pebble) 'pause CA for scheduled renewal' | Out-Null; $paused=$true }
        else { Set-DnsDefault '192.0.2.1' }
        Invoke-Certbot -Mode run -Consent $true -Force $true -Timeout 15 -Name "$prefix-watch" -ExtraArguments @('-e','CERTBOT_RENEW_SECONDS=3','-e','CERTBOT_RETRY_SECONDS=10') | Out-Null
        Wait-Until { Client-Child "$prefix-watch" } 20 'actual scheduled renewal child entering the fault' | Out-Null
        Wait-Until { -not (Client-Child "$prefix-watch") } 25 'actual scheduled renewal child exiting under the fault' | Out-Null
        $retryWindow=[Diagnostics.Stopwatch]::StartNew()
        do {
            Assert (-not (Client-Child "$prefix-watch")) 'normal interval bypassed the failed-host retry deadline'
            Start-Sleep -Milliseconds 100
        } while($retryWindow.Elapsed.TotalSeconds -lt 5)
        Assert ((Cert).Split(';')[0] -eq $leaf.Split(';')[0] -and (Token) -eq $hint -and (Workers) -eq $workers -and (Master) -eq $master) "$fault failure replaced loaded TLS/publication/workers"
        if ($fault -eq 'CA') { Invoke-Docker @('unpause',$pebble) 'restore CA for same scheduler' | Out-Null; $paused=$false }
        else { Assert ((Orders) -gt $orders) 'HTTP01 fault did not reach real ordering'; Set-DnsDefault $nginxIp }
        $next=Wait-New-Cert $leaf "automatic $fault recovery without scheduler recreation"
        Invoke-Docker @('rm','-f',"$prefix-watch") 'stop automatically recovered scheduler' | Out-Null
        Assert ((Expiry $next) -gt (Expiry $leaf) -and (Master) -eq $master) "$fault recovery lacked validity advancement/stable master"
        $leaf=$next
    }

    Write-Host 'CASE: account contents and server account reuse after role recreation'
    $accountDigest=Account-Fingerprint; $accounts=Accounts
    Invoke-Docker @('rm','-f',$nginx) 'recreate only owned ingress' | Out-Null
    Start-Nginx $certVolume | Out-Null
    $persisted=Wait-Until { Cert } 30 'persisted TLS after ingress recreation'
    Assert ($persisted.Split(';')[0] -eq $leaf.Split(';')[0]) 'ingress recreation lost the persisted certificate'
    $master=Master
    Invoke-Certbot renew $true $true | Out-Null
    $leaf=Wait-New-Cert $leaf 'successful CA operation after both role recreations'
    Assert ((Account-Fingerprint) -eq $accountDigest -and (Accounts) -eq $accounts) 'recreated client replaced account contents or registered another account'

    Write-Host 'CASE: saved CA-directory mismatch rejects cold TLS and client before CA calls'
    $orders=Orders; $accounts=Accounts
    Invoke-Docker @('rm','-f',$controller) 'retain prior readiness without a running controller' | Out-Null
    Invoke-Docker @('run','--rm','--mount',"type=volume,source=$configVolume,target=/state",'alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0','sh','-ec','set -- $(cat /state/.controller-ready); printf "%s %s %s\n" "$1" "$(date +%s)" "$3" >/state/.controller-ready') 'keep a fresh marker from the previous ingress incarnation' | Out-Null
    Cert-Files 'cp /state/renewal/app.test.conf /state/app.test.saved; sed -i "s#^server = .*#server = https://localhost:14000/wrong-directory#" /state/renewal/app.test.conf' | Out-Null
    Invoke-Docker @('rm','-f',$nginx) 'cold start with incompatible saved directory' | Out-Null
    Start-Nginx $certVolume -AssertWaitingForController | Out-Null
    Assert (Rejects-Tls) 'cold ingress accepted a lineage from the wrong selected CA directory'
    $failed=$false; try { Invoke-Certbot renew $true $true | Out-Null } catch { $failed=$true }
    Assert ($failed -and (Orders) -eq $orders -and (Accounts) -eq $accounts) 'incompatible saved directory was not rejected before the client'
    Cert-Files 'mv /state/app.test.saved /state/renewal/app.test.conf' | Out-Null
    $leaf=Wait-Until { Cert } 30 'forward recovery after restoring the selected directory metadata'
    $master=Master

    Write-Host 'CASE: incomplete forward publication retains acknowledged workers'
    Controller-Signal STOP; Start-Sleep -Seconds 1
    $ack=State; $selection=Selection; $workers=Workers
    Invoke-Certbot renew $true $true | Out-Null
    $newKey=(Cert-Files 'readlink /state/live/app.test/privkey.pem') -join ''
    Cert-Files 'rm /state/live/app.test/privkey.pem' | Out-Null
    Controller-Signal CONT; Start-Sleep -Seconds 2
    Assert ((Cert).Split(';')[0] -eq $leaf.Split(';')[0] -and (State) -eq $ack -and (Selection) -eq $selection -and (Workers) -eq $workers) 'incomplete publication replaced acknowledged TLS/configuration/workers'
    Write-Host 'CASE: live controller restart during partial publication retains loaded TLS'
    Invoke-Docker @('restart',$controller) 'restart owned controller with incomplete client publication' | Out-Null
    Start-Sleep -Seconds 2
    Assert (((Invoke-Docker @('inspect',$controller) 'observe supervising controller during rejected candidate' | ConvertFrom-Json)[0].State.Running)) 'partial publication stopped controller supervision'
    Assert ((Cert).Split(';')[0] -eq $leaf.Split(';')[0] -and (State) -eq $ack -and (Selection) -eq $selection -and (Workers) -eq $workers) 'controller restart downgraded loaded TLS during incomplete publication'
    Cert-Files "ln -s '$newKey' /state/live/app.test/privkey.pem" | Out-Null
    $leaf=Wait-New-Cert $leaf 'completion of the NEW private-key link'
    Assert ((Master) -eq $master) 'partial-publication recovery replaced the master'

    Write-Host 'CASE: native candidate validation failure preserves selected config and recovers'
    Controller-Signal STOP; Start-Sleep -Seconds 1
    $badTemplate=Join-Path $temp 'invalid.tmpl'
    Invoke-Docker @('cp',"$nginx`:/opt/ingress/nginx.conf.tmpl",$badTemplate) 'copy actual owned template for syntax fault' | Out-Null
    Add-Content -LiteralPath $badTemplate -Value 'deliberately_invalid_directive yes;' -Encoding ascii
    $ack=State; $selection=Selection; $workers=Workers
    $failed=$false
    try { Invoke-Activation -ExtraArguments @('--mount',"type=bind,source=$badTemplate,target=/opt/ingress/nginx.conf.tmpl,readonly") | Out-Null } catch { $failed=$true }
    Assert ($failed -and (State) -eq $ack -and (Selection) -eq $selection -and (Workers) -eq $workers -and (Cert).Split(';')[0] -eq $leaf.Split(';')[0]) 'real nginx-t failure changed the serving generation'
    Invoke-Activation | Out-Null

    Write-Host 'CASE: kernel-denied HUP, selected B, incomplete A reversion and forward repair'
    $denyPath=Join-Path $temp 'deny-hup.json'
    '{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{"names":["kill"],"action":"SCMP_ACT_ERRNO","errnoRet":1}]}' | Set-Content -LiteralPath $denyPath -Encoding ascii
    Set-Hosts -Hosts @(); $failed=$false
    try { Invoke-Activation -ExtraArguments @('--security-opt',"seccomp=$denyPath") | Out-Null } catch { $failed=$true }
    Assert ($failed -and (State) -eq $ack -and (Selection) -ne $selection -and (Cert).Split(';')[0] -eq $leaf.Split(';')[0]) 'kernel-denied HUP did not preserve loaded A with selected B pending'
    Set-Hosts -Hosts @('app.test')
    $currentKey=(Cert-Files 'readlink /state/live/app.test/privkey.pem') -join ''; Cert-Files 'rm /state/live/app.test/privkey.pem' | Out-Null
    $failed=$false; try { Invoke-Activation | Out-Null } catch { $failed=$true }
    Assert ($failed -and (State) -eq $ack -and (Cert).Split(';')[0] -eq $leaf.Split(';')[0]) 'pending B erased the acknowledged-A incomplete-publication guard'
    Cert-Files "ln -s '$currentKey' /state/live/app.test/privkey.pem" | Out-Null
    Invoke-Activation | Out-Null
    Assert ((Workers) -ne $workers -and (Master) -eq $master) 'input A reversion skipped the required pending forward reload'
    Invoke-Docker @('exec',$nginx,'test','!','-e','/run/nginx-config/.certificate-pending') 'verify pending repair acknowledged' | Out-Null

    Write-Host 'CASE: stable stopped master does NOT acknowledge selected generation'
    $ack=State; $selection=Selection
    Invoke-Docker @('kill','--signal','STOP',$nginx) 'stop only owned master while its workers remain live' | Out-Null
    Set-Hosts -Hosts @(); Invoke-Activation -Name "$prefix-actor" | Out-Null
    Wait-Until { (Selection) -ne $selection } 10 'real candidate B selection before native acknowledgement' | Out-Null
    Wait-Until { -not ((Invoke-Docker @('inspect',"$prefix-actor") 'inspect no-ack actor' | ConvertFrom-Json)[0].State.Running) } 30 'real acknowledgement timeout' | Out-Null
    $exit=((Invoke-Docker @('inspect',"$prefix-actor") 'inspect no-ack outcome' | ConvertFrom-Json)[0].State.ExitCode)
    Assert ($exit -ne 0 -and (State) -eq $ack -and (Cert).Split(';')[0] -eq $leaf.Split(';')[0]) 'stopped master produced a false reload acknowledgement'
    Invoke-Docker @('rm','-f',"$prefix-actor") 'remove completed no-ack actor' | Out-Null
    Set-Hosts -Hosts @('app.test'); Invoke-Docker @('kill','--signal','CONT',$nginx) 'resume owned master' | Out-Null
    Invoke-Activation | Out-Null
    Wait-Until { Cert } 30 'forward A after timed-out B' | Out-Null

    Write-Host 'CASE: overlapping real publication/input change is not acknowledged as stale snapshot'
    $ack=State; $selection=Selection
    Invoke-Docker @('kill','--signal','STOP',$nginx) 'park master for controlled overlap' | Out-Null
    Set-Hosts -Hosts @('app.test') -BackendPort 8081 -Recreate; Invoke-Activation -Name "$prefix-actor" | Out-Null
    Wait-Until { (Selection) -ne $selection } 10 'snapshot B selected during overlap' | Out-Null
    Set-Hosts -Hosts @('app.test') -Recreate; Invoke-Certbot renew $true $true | Out-Null
    Assert (((Invoke-Docker @('inspect',"$prefix-actor") 'inspect in-flight overlap' | ConvertFrom-Json)[0].State.Running)) 'publication did not overlap the actual pending activation'
    Invoke-Docker @('kill','--signal','CONT',$nginx) 'release master after new publication' | Out-Null
    Wait-Until { -not ((Invoke-Docker @('inspect',"$prefix-actor") 'inspect overlap completion' | ConvertFrom-Json)[0].State.Running) } 10 'overlapping activation outcome' | Out-Null
    $exit=((Invoke-Docker @('inspect',"$prefix-actor") 'inspect stale snapshot outcome' | ConvertFrom-Json)[0].State.ExitCode)
    Assert ($exit -ne 0) 'overlapping unseen inputs were incorrectly treated as converged'
    Invoke-Docker @('exec',$nginx,'test','-e','/run/nginx-config/.certificate-pending') 'retain pending forward reconciliation' | Out-Null
    Invoke-Docker @('rm','-f',"$prefix-actor") 'remove completed overlap actor' | Out-Null
    $overlapWorkers=Workers
    Invoke-Activation | Out-Null; $leaf=Wait-New-Cert $leaf 'current forward generation after overlap'
    $body=(Invoke-Docker @('run','--rm','--network',$network,'--add-host',"app.test:$nginxIp",'--entrypoint','curl','--mount',"type=bind,source=$issuedPath,target=/run/issued.pem,readonly",$Image,'--noproxy','*','--fail','--silent','--cacert','/run/issued.pem','https://app.test/') 'exercise current backend after overlap') -join ''
    Assert ($body -eq 'backend' -and (Workers) -ne $overlapWorkers -and (Master) -eq $master) 'current inputs failed to replace loaded stale backend/certificate generation'

    Write-Host 'CASE: newly loaded hostname retains trusted TLS when publication changes during HUP'
    Set-Hosts -Hosts @('app.test','loaded.test'); Invoke-Activation | Out-Null
    Invoke-Certbot -Mode run -Consent $true -Name "$prefix-client" | Out-Null
    Wait-Until { Cert-Files 'test -s /state/live/loaded.test/fullchain.pem && test -s /state/live/loaded.test/privkey.pem && test -s /state/renewal/loaded.test.conf' | Out-Null; $true } 90 'real initial loaded.test publication' | Out-Null
    Wait-Until { -not (Client-Child "$prefix-client") } 15 'new-host native client completed publication' | Out-Null
    Invoke-Docker @('rm','-f',"$prefix-client") 'stop completed new-host scheduler' | Out-Null
    $loadedKey=(Cert-Files 'readlink /state/live/loaded.test/privkey.pem') -join ''
    $selection=Selection
    Invoke-Docker @('kill','--signal','STOP',$nginx) 'park master before first ready loaded.test activation' | Out-Null
    Invoke-Activation -Name "$prefix-actor" | Out-Null
    Wait-Until { (Selection) -ne $selection } 10 'new hostname TLS candidate selected' | Out-Null
    Cert-Files 'rm /state/live/loaded.test/privkey.pem' | Out-Null
    Invoke-Docker @('kill','--signal','CONT',$nginx) 'load immutable new-host snapshot after live alias disappears' | Out-Null
    Wait-Until { -not ((Invoke-Docker @('inspect',"$prefix-actor") 'observe new-host overlap actor' | ConvertFrom-Json)[0].State.Running) } 10 'new-host overlap completion' | Out-Null
    Assert (((Invoke-Docker @('inspect',"$prefix-actor") 'inspect incomplete reconciliation' | ConvertFrom-Json)[0].State.ExitCode) -ne 0) 'missing newer publication was incorrectly marked converged'
    Invoke-Docker @('rm','-f',"$prefix-actor") 'remove completed new-host actor' | Out-Null
    $loadedLeaf=Wait-Until { Cert 'loaded.test' } 30 'genuinely loaded trusted new-host TLS'
    $workers=Workers; $selection=Selection; $failed=$false
    try { Invoke-Activation | Out-Null } catch { $failed=$true }
    Assert ($failed -and (Cert 'loaded.test') -eq $loadedLeaf -and (Selection) -eq $selection -and (Workers) -eq $workers -and (Master) -eq $master) 'incomplete publication downgraded actually loaded new-host TLS'
    Cert-Files "ln -s '$loadedKey' /state/live/loaded.test/privkey.pem" | Out-Null
    Invoke-Activation | Out-Null
    Assert ((Cert 'loaded.test') -eq $loadedLeaf) 'forward completion lost the loaded new-host lineage'
    Set-Hosts -Hosts @('app.test'); Invoke-Activation | Out-Null
    $leaf=Wait-Until { Cert } 30 'remaining app after new-host removal'

    Write-Host 'CASE: killed native flock holder releases persisted lock'
    $selection=Selection
    Invoke-Docker @('kill','--signal','STOP',$nginx) 'park master while actual activator holds flock' | Out-Null
    Set-Hosts -Hosts @(); Invoke-Activation -Name "$prefix-actor" | Out-Null
    Wait-Until { (Selection) -ne $selection } 10 'lock holder entered actual reload transaction' | Out-Null
    Invoke-Docker @('rm','-f',"$prefix-actor") 'kill only owned in-flight lock holder' | Out-Null
    Set-Hosts -Hosts @('app.test'); Invoke-Docker @('kill','--signal','CONT',$nginx) 'resume master after holder crash' | Out-Null
    Invoke-Activation | Out-Null
    Invoke-Docker @('exec',$nginx,'test','!','-e','/run/nginx-config/.certificate-pending') 'verify native lock crash recovery' | Out-Null
    Controller-Signal CONT

    Write-Host 'CASE: removed queued B is skipped while first real A issuance is in flight'
    Set-Hosts -Hosts @('a.test','app.test','b.test')
    $orders=Orders
    Invoke-Docker @('pause',$pebble) 'block first queued real issuance at CA' | Out-Null; $paused=$true
    Invoke-Certbot -Mode run -Consent $true -Timeout 30 -Name "$prefix-client" | Out-Null
    Wait-Until { $top=& docker top "$prefix-client" -eo pid,args 2>$null; @($top | Where-Object { "$_" -match 'certbot certonly .*--cert-name a[.]test' }).Count -gt 0 } 15 'first queued A native client in flight' | Out-Null
    Set-Hosts -Hosts @('a.test','app.test')
    Invoke-Docker @('unpause',$pebble) 'release queued A without recreating scheduler' | Out-Null; $paused=$false
    Wait-Until { Cert 'a.test' } 90 'actual queued A issuance completed' | Out-Null
    Start-Sleep -Seconds 2; Invoke-Docker @('rm','-f',"$prefix-client") 'stop completed queue scheduler' | Out-Null
    Assert ((Orders) -eq ($orders+1)) 'removed queued B or an unrelated existing lineage created another order'
    Cert-Files 'test ! -e /state/renewal/b.test.conf; test ! -e /state/live/b.test' | Out-Null

    Write-Host 'CASE: one permanently rejected host does not starve healthy issuance or renewal'
    Set-Hosts -Hosts @('aaa-blocked.test','app.test','good.test')
    Invoke-Certbot -Mode run -Consent $true -Force $true -Timeout 30 -Name "$prefix-client" -ExtraArguments @('-e','CERTBOT_RENEW_SECONDS=3','-e','CERTBOT_RETRY_SECONDS=2') | Out-Null
    $good=Wait-Until { Cert 'good.test' } 90 'healthy issuance after blocked first host'
    $newGood=Wait-New-Cert $good 'healthy scheduled renewal while blocked host keeps failing' 'good.test'
    Assert ((Expiry $newGood) -gt (Expiry $good)) 'failed independent host suppressed healthy scheduled renewal'
    Invoke-Docker @('rm','-f',"$prefix-client") 'stop independent-host scheduler' | Out-Null
    Cert-Files 'test ! -e /state/renewal/aaa-blocked.test.conf; test ! -e /state/live/aaa-blocked.test' | Out-Null
    Set-Hosts -Hosts @('app.test')
    $leaf=Wait-Until { Cert } 30 'remaining active app certificate'

    Write-Host 'CASE: persisted TLS selection plus lost certificate volume repairs to bootstrap and reissues'
    $selected=Invoke-Docker @('exec',$nginx,'cat','/run/nginx-selected/nginx.conf') 'confirm real persisted TLS selection'
    Assert (($selected -join "`n") -match 'ssl_certificate /etc/letsencrypt/archive/app.test/') 'lost-volume setup did not persist the actual TLS-selected root'
    Invoke-Docker @('rm','-f',$nginx) 'cold restart with replacement empty certificate volume' | Out-Null
    Start-Nginx $lostVolume | Out-Null
    Assert (Rejects-Tls) 'lost volume did not repair persisted TLS selection to rejecting bootstrap'
    $lostHttp=Port $netnsHost '80/tcp'
    $code=& curl.exe --noproxy '*' --silent --output NUL --write-out '%{http_code}' --resolve "app.test:$lostHttp`:127.0.0.1" "http://app.test:$lostHttp/.well-known/acme-challenge/missing"
    Assert ($code -eq '404') 'lost-volume repair removed HTTP01 challenge handling'
    Invoke-Certbot -Mode run -Consent $true -Name "$prefix-client" -CertificatesVolume $lostVolume | Out-Null
    $replacement=Wait-New-Cert $leaf 'automatic replacement-volume issuance'
    Invoke-Docker @('rm','-f',"$prefix-client") 'stop replacement-volume scheduler' | Out-Null
    Assert ((Expiry $replacement) -gt (Expiry $leaf)) 'lost-volume reissuance did not produce a fresh validity interval'
    Write-Host 'PASS: real stock Certbot/Pebble lifecycle, consent/account guards, idle schedule, hook failure, same-scheduler CA/HTTP01 recovery, account reuse, immutable publication, validation/HUP/no-ack/overlap/lock forward repair, in-flight queue removal, independent host renewal, and persisted-selection lost-volume reissuance.'
} catch {
    Write-Host '--- lifecycle failure ---'; Write-Host $_
    if($script:TlsDiagnostic){ Write-Host '--- TLS diagnostic ---'; Write-Host $script:TlsDiagnostic }; if($nginx){ Write-Host '--- selected full root ---'; & docker.exe exec $nginx cat /run/nginx-selected/nginx.conf 2>&1 }
    & docker.exe volume inspect $configVolume --format '{{.Name}}' 2>$null | Out-Null
    if($LASTEXITCODE -eq 0){
        Write-Host '--- actual discovered records ---'
        & docker.exe run --rm --network none --mount "type=volume,source=$configVolume,target=/state,readonly" alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0 cat /state/discovery.conf 2>&1
    }
    foreach($c in @($nginx,$controller,$socketProxy,"$prefix-client","$prefix-watch","$prefix-actor",$pebble,$dns)){ if($c){ Write-Host "--- $c diagnostics ---"; & docker logs $c --tail 100 2>&1 } }
    throw
} finally {
    & docker.exe unpause $controller 2>$null | Out-Null
    & docker.exe kill --signal CONT $nginx 2>$null | Out-Null
    if($paused){ & docker.exe unpause $pebble 2>$null | Out-Null }
    foreach($c in @("$prefix-actor","$prefix-client","$prefix-watch",$controller,$nginx,$socketProxy,$netnsHost,$pebble,$dns)+@($backends.Values)){ if($c){ & docker.exe rm -f $c 2>$null | Out-Null } }
    foreach($v in @($certVolume,$webVolume,$configVolume,$selectedVolume,$runtimeVolume,$lostVolume)){ if($v){ & docker volume rm $v 2>$null | Out-Null } }
    foreach($n in @($network,$controlNetwork)){if($n){ & docker.exe network rm $n 2>$null | Out-Null }}; if(Test-Path $temp){Remove-Item -Recurse -Force $temp}
}
