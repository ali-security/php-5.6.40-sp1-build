# Verifies a sealed PHP 5.6.40+sp1 Windows CLI bundle: version, that every extension DLL of the official
# 5.6.40 NTS zip (minus the Oracle ones) is present and loads, the CVE-2026-109618 OOM exit and the
# multipart limits through the built-in server (php -S).
param(
    [Parameter(Mandatory = $true)][string]$Bundle
)
$ErrorActionPreference = 'Stop'
$Tests = (Resolve-Path "$PSScriptRoot\..\tests").Path
$Php = "$Bundle\php.exe"
$Tmp = New-Item -ItemType Directory -Force -Path "$env:RUNNER_TEMP\verify-$([guid]::NewGuid())"
$Port = 8089

# ext\ of php-5.6.40-nts-Win32-VC11-*.zip, without php_oci8_12c and php_pdo_oci.
$Extensions = 'bz2 com_dotnet curl enchant exif fileinfo gd2 gettext gmp imap intl ldap mbstring mysql mysqli openssl pdo_mysql pdo_odbc pdo_pgsql pdo_sqlite pgsql shmop snmp soap sockets sqlite3 tidy xmlrpc xsl'.Split(' ')
# These link a vendor client DLL that the official zip does not ship either (fbclient.dll, libct.dll),
# so they can only be checked for presence.
$VendorClientExtensions = 'interbase pdo_firebird sybase_ct'.Split(' ')

function Fail([string]$Message) {
    Write-Host "FAIL: $Message"
    exit 1
}

# Runs php.exe and returns stdout+stderr as one string; native stderr must not become a terminating error.
function Invoke-Php([string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $out = & $Php @Arguments 2>&1 | Out-String
    $script:PhpExit = $LASTEXITCODE
    return $out
}

Write-Host '== php -v'
$v = Invoke-Php @('-n', '-v')
Write-Host $v
if ($v -notmatch '^PHP 5\.6\.40 ') { Fail 'unexpected version' }

Write-Host '== extensions load one by one'
foreach ($e in $Extensions) {
    $dll = "$Bundle\ext\php_$e.dll"
    if (-not (Test-Path $dll)) { Fail "$dll missing" }
    $out = Invoke-Php @('-n', '-d', "extension_dir=$Bundle\ext", '-d', "extension=php_$e.dll", '-r', 'exit(0);')
    if ($PhpExit -ne 0 -or $out -match 'Unable to load|Warning') { Fail "php_$e.dll does not load: $out" }
}
foreach ($e in $VendorClientExtensions) {
    if (-not (Test-Path "$Bundle\ext\php_$e.dll")) { Fail "php_$e.dll missing" }
}
$out = Invoke-Php @('-n', '-d', "zend_extension=$Bundle\ext\php_opcache.dll", '-v')
if ($out -notmatch 'Zend OPcache') { Fail "php_opcache.dll does not load: $out" }

$ini = "$Tmp\php.ini"
(@("extension_dir=`"$Bundle\ext`"") + ($Extensions | ForEach-Object { "extension=php_$_.dll" })) | Set-Content -Encoding ascii $ini
Write-Host '== php -m (all extensions)'
Write-Host (Invoke-Php @('-c', $ini, '-m'))

Write-Host '== sealed INI default'
if ((Invoke-Php @('-n', '-r', 'echo ini_get("max_multipart_body_parts");')).Trim() -ne '-1') { Fail 'max_multipart_body_parts missing' }

Write-Host '== OOM: memory_limit exhaustion must _exit(1) without running shutdown functions'
$out = Invoke-Php @('-n', '-d', 'memory_limit=4M', "$Tests\oom.php")
Write-Host $out
if ($PhpExit -ne 1) { Fail "expected exit 1 on memory_limit, got $PhpExit" }
if ($out -notmatch 'Allowed memory size of') { Fail 'OOM message missing' }
if ($out -match 'shutdown ran') { Fail 'shutdown function ran after OOM' }

Write-Host '== php -S: multipart body parts limit and duplicate part headers'
New-Item -ItemType Directory -Force -Path "$Tmp\docroot" | Out-Null
Copy-Item "$Tests\post.php" "$Tmp\docroot\post.php"
$server = Start-Process -FilePath $Php -PassThru -NoNewWindow `
    -RedirectStandardOutput "$Tmp\server.out" -RedirectStandardError "$Tmp\server.err" `
    -ArgumentList '-n', '-d', 'max_multipart_body_parts=3', '-d', 'display_errors=0', '-d', 'log_errors=1', `
        '-d', "error_log=$Tmp\server.log", '-S', "127.0.0.1:$Port", '-t', "$Tmp\docroot"
Start-Sleep -Seconds 3
$resp = & curl.exe -fsS -H 'Content-Type: multipart/form-data; boundary=sealboundary' --data-binary "@$Tests\multipart-body.bin" "http://127.0.0.1:$Port/post.php"
Stop-Process -Id $server.Id -Force
Start-Sleep -Seconds 1
Write-Host "response: $resp"
$log = (Get-Content -Raw -ErrorAction SilentlyContinue "$Tmp\server.out", "$Tmp\server.err", "$Tmp\server.log") -join "`n"
Write-Host $log
if ($resp -ne '{"post":["a","b"],"files":{"f":"text\/plain"}}') { Fail 'unexpected php -S response' }
if ($log -notmatch 'Multipart body parts limit exceeded 3') { Fail 'body parts warning missing' }

Write-Host 'verify-bundle: OK'
exit 0
