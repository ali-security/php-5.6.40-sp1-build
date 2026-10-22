# Builds the sealed PHP 5.6.40+sp1 CLI for Windows (NTS, VC11) the way the official 5.6 release
# zips were built: Visual Studio 2012, php-sdk-binary-tools-20110915, deps-5.6-vc11-<arch>_2018-12,
# configure --enable-snapshot-build, nmake snap. php-cgi.exe and phpdbg are dropped from the result
# (CLI only); the Oracle extensions are not built (the 12c Instant Client SDK is no longer downloadable).
param(
    [Parameter(Mandatory = $true)][ValidateSet('x64', 'x86')][string]$Arch,
    [ValidateSet('install', 'build', 'test', 'all')][string]$Stage = 'all'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Version = '5.6.40'
$SealVersion = '5.6.40+sp1'
$RepoDir = (Resolve-Path "$PSScriptRoot\..").Path
$Sdk = 'C:\php-sdk'
$Work = "$Sdk\phpdev\vc11\$Arch"
$CodeDir = "$Work\php-$Version"
$ObjDir = "$Work\obj"
$OutDir = "$RepoDir\out"
$BundleName = "php-$SealVersion-win-$Arch"

$Downloads = @{
    'php.tar.xz'   = @('https://www.php.net/distributions/php-5.6.40.tar.xz', '1369a51eee3995d7fbd1c5342e5cc917760e276d561595b6052b21ace2656d1c')
    'sdk.zip'      = @('https://downloads.php.net/~windows/php-sdk/php-sdk-binary-tools-20110915.zip', '8a52c80d80cc35b013fdd1d2616a08c739cd4da69f4e2ddeda3d69bf2d1d424b')
    'deps-x64.7z'  = @('https://downloads.php.net/~windows/php-sdk/archives/deps-5.6-vc11-x64_2018-12.7z', 'e6142c1ae5e4c5fddc7d8080dac5b6172d7e5d65de5287920fdeba23cf6015cd')
    'deps-x86.7z'  = @('https://downloads.php.net/~windows/php-sdk/archives/deps-5.6-vc11-x86_2018-12.7z', '641a4f39f7a7fff4fbcfdccabc12e0845b451d8cdb1e834a937488a40b2539ab')
    'official-x64.zip' = @('https://downloads.php.net/~windows/releases/archives/php-5.6.40-nts-Win32-VC11-x64.zip', '3d7668280fa4b16f70705539ba1e4ea17eef344c81e82881cbeca26fb7f181f1')
    'official-x86.zip' = @('https://downloads.php.net/~windows/releases/archives/php-5.6.40-nts-Win32-VC11-x86.zip', 'a7ad5a445d74da9c5b6e3e85d922a62cd808477a4a0b3bb24b8ee945ffc620a7')
}

function Get-Verified([string]$Name) {
    $url, $sha = $Downloads[$Name]
    $dest = "$Sdk\dl\$Name"
    if (-not (Test-Path $dest)) {
        New-Item -ItemType Directory -Force -Path "$Sdk\dl" | Out-Null
        Invoke-WebRequest -Uri $url -OutFile $dest
    }
    $actual = (Get-FileHash -Algorithm SHA256 $dest).Hash.ToLower()
    if ($actual -ne $sha) { throw "sha256 mismatch for $url`: $actual" }
    return $dest
}

function Invoke-Checked([string]$File, [string[]]$Arguments) {
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File $Arguments failed with $LASTEXITCODE" }
}

function Install-VS2012 {
    $vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio 11.0\VC\vcvarsall.bat'
    if (Test-Path $vcvars) { return }
    $iso = "$env:RUNNER_TEMP\VS2012_WDX_ENU.iso"
    # Visual Studio Express 2012 for Windows Desktop, still served by Microsoft; the setup's Authenticode
    # signature is checked below.
    Invoke-WebRequest -Uri 'https://download.microsoft.com/download/1/F/5/1F519CC5-0B90-4EA3-8159-33BFB97EF4D9/VS2012_WDX_ENU.iso' -OutFile $iso
    Write-Host "VS2012_WDX_ENU.iso sha256: $((Get-FileHash -Algorithm SHA256 $iso).Hash)"
    $drive = (Mount-DiskImage -ImagePath $iso -PassThru | Get-Volume).DriveLetter
    $setup = "${drive}:\wdexpress_full.exe"
    $sig = Get-AuthenticodeSignature $setup
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "unexpected signature on $setup`: $($sig.Status) $($sig.SignerCertificate.Subject)"
    }
    $p = Start-Process -FilePath $setup -ArgumentList '/Q', '/NoRestart', '/Full', '/Log', "$env:RUNNER_TEMP\vs2012.log" -PassThru
    # A silent setup that hits a prompt never exits; fail with its logs instead of hanging the job.
    if (-not $p.WaitForExit(45 * 60 * 1000)) {
        Get-ChildItem "$env:RUNNER_TEMP\vs2012*.log" | ForEach-Object { Write-Host "== $_"; Get-Content $_ -Tail 60 }
        Stop-Process -Id $p.Id -Force
        throw 'VS2012 setup did not finish in 45 minutes'
    }
    Write-Host "VS2012 setup exit code: $($p.ExitCode)"
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        Get-ChildItem "$env:RUNNER_TEMP\vs2012*.log" | ForEach-Object { Get-Content $_ -Tail 80 }
        throw 'VS2012 setup failed'
    }
    if (-not (Test-Path $vcvars)) { throw "VS2012 installed but $vcvars is missing" }
}

function Initialize-Tree {
    New-Item -ItemType Directory -Force -Path $Work, $OutDir | Out-Null
    Expand-Archive -Force -Path (Get-Verified 'sdk.zip') -DestinationPath $Sdk
    Invoke-Checked 7z @('x', '-y', "-o$Work", (Get-Verified "deps-$Arch.7z"))
    if (Test-Path $CodeDir) { Remove-Item -Recurse -Force $CodeDir }
    Invoke-Checked tar @('-xf', (Get-Verified 'php.tar.xz'), '-C', $Work)
    Push-Location $CodeDir
    Invoke-Checked git @('apply', '-p1', '--whitespace=nowarn', '--verbose', "$RepoDir\patches\CVE-2026-109618+CVE-2026-109619.patch")
    Pop-Location
}

function Invoke-Build {
    $vcvarsArch = if ($Arch -eq 'x64') { 'x86_amd64' } else { 'x86' }
    $bat = "$Work\build.bat"
    @"
@echo on
call "C:\Program Files (x86)\Microsoft Visual Studio 11.0\VC\vcvarsall.bat" $vcvarsArch || exit /b 1
call "$Sdk\bin\phpsdk_setvars.bat" || exit /b 1
cd /d "$CodeDir" || exit /b 1
call buildconf.bat || exit /b 1
call configure.bat --enable-snapshot-build --disable-zts --enable-object-out-dir="$ObjDir" --with-php-build="$Work\deps" --without-analyzer --with-mcrypt=static --enable-com-dotnet=shared --with-enchant=shared --without-oci8 --without-oci8-11g --without-oci8-12c --without-pdo-oci --disable-phpdbg || exit /b 1
nmake || exit /b 1
nmake snap || exit /b 1
"@ | Set-Content -Encoding ascii $bat
    Invoke-Checked cmd.exe @('/c', $bat)
}

function New-Bundle {
    $snap = Get-ChildItem -Recurse -Path $ObjDir -Filter "php-$Version-nts-Win32-VC11-$Arch.zip" | Select-Object -First 1
    if (-not $snap) { throw 'nmake snap zip not found' }
    $bundle = "$Work\$BundleName"
    if (Test-Path $bundle) { Remove-Item -Recurse -Force $bundle }
    Expand-Archive -Path $snap.FullName -DestinationPath $bundle
    # Keep php-cgi.exe aside for the .phpt run, then drop the non-CLI SAPIs.
    Copy-Item "$bundle\php-cgi.exe" "$Work\php-cgi.exe"
    Remove-Item -Force -ErrorAction SilentlyContinue "$bundle\php-cgi.exe", "$bundle\phpdbg.exe", "$bundle\php5phpdbg.dll"
    Copy-Item "$RepoDir\patches\CVE-2026-109618+CVE-2026-109619.patch" $bundle
    $zip = "$OutDir\$BundleName.zip"
    if (Test-Path $zip) { Remove-Item -Force $zip }
    Compress-Archive -Path "$bundle\*" -DestinationPath $zip
    "$((Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower())  $BundleName.zip" | Tee-Object -FilePath "$zip.sha256"
    return $bundle
}

# Runs the same .phpt suites against the sealed build and the official (pristine) 5.6.40 zip, both VC11 NTS.
function Test-Phpt([string]$Bundle) {
    $official = "$Work\official"
    if (Test-Path $official) { Remove-Item -Recurse -Force $official }
    Expand-Archive -Path (Get-Verified "official-$Arch.zip") -DestinationPath $official
    $sealedCgi = "$Bundle\php-cgi.exe"
    Copy-Item "$Work\php-cgi.exe" $sealedCgi
    $suites = @('ext\session\tests', 'Zend\tests', 'tests')
    foreach ($run in @(@('pristine', "$official\php.exe", "$official\php-cgi.exe"), @('sealed', "$Bundle\php.exe", $sealedCgi))) {
        $name, $php, $cgi = $run
        Push-Location $CodeDir
        $env:TEST_PHP_EXECUTABLE = $php
        $env:TEST_PHP_CGI_EXECUTABLE = $cgi
        $env:NO_INTERACTION = '1'
        & $php -n run-tests.php -n -q @suites 2>&1 | Tee-Object -FilePath "$OutDir\phpt-$name-win-$Arch.log" | Out-Null
        Pop-Location
        Get-Content "$OutDir\phpt-$name-win-$Arch.log" | Where-Object { $_ -match '^(FAIL|SKIP)' } |
            ForEach-Object { ($_ -replace ' \[.*$', '').Trim() } | Sort-Object -Unique |
            Set-Content "$Work\phpt-$name.results"
    }
    Remove-Item -Force $sealedCgi
    $pristine = Get-Content "$Work\phpt-pristine.results"
    $sealed = Get-Content "$Work\phpt-sealed.results"
    Write-Host '== phpt results only in sealed (new failures/skips):'
    $sealed | Where-Object { $pristine -notcontains $_ } | Tee-Object -FilePath "$OutDir\phpt-sealed-only-win-$Arch.txt"
    Write-Host '== phpt results only in pristine (fixed by the seal):'
    $pristine | Where-Object { $sealed -notcontains $_ } | Tee-Object -FilePath "$OutDir\phpt-pristine-only-win-$Arch.txt"
}

if ($Stage -in 'install', 'all') {
    Install-VS2012
}
if ($Stage -in 'build', 'all') {
    Initialize-Tree
    Invoke-Build
    New-Bundle | Out-Null
}
if ($Stage -in 'test', 'all') {
    $bundle = "$Work\$BundleName"
    & "$RepoDir\scripts\verify-bundle.ps1" -Bundle $bundle
    if ($LASTEXITCODE -ne 0) { throw 'verify-bundle.ps1 failed' }
    Test-Phpt -Bundle $bundle
}
