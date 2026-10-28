$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Discover-AceGames.ps1')
$base=Join-Path ([IO.Path]::GetTempPath()) ('AceDiscoveryTest-'+[guid]::NewGuid().ToString('N'))
$game=Join-Path $base 'Launcher\games\FutureGame'
$marker=Join-Path $game 'AntiCheatExpert'
$fake=Join-Path $base 'NotAceGame\AntiCheatExpert'
$empty=Join-Path $base 'Unresolved\AntiCheatExpert'
$files=@((Join-Path $marker 'ACE-Setup64.exe'),(Join-Path $game 'FutureGame.exe'),(Join-Path $game 'QtWebEngineProcess.exe'),(Join-Path $game 'CrashReport.exe'),(Join-Path $base 'NotAceGame\OtherGame.exe'),(Join-Path $empty 'ACE-Helper.exe'))
$dirs=@($base,(Join-Path $base 'Launcher'),(Join-Path $base 'Launcher\games'),$game,$marker,(Join-Path $base 'NotAceGame'),$fake,(Join-Path $base 'Unresolved'),$empty)
foreach($d in $dirs){New-Item -ItemType Directory -Path $d -Force|Out-Null}
foreach($f in $files){Set-Content -LiteralPath $f -Value 'test fixture, never executed'}
try {
    $r=Find-AceGames -ExtraRoots @((Join-Path $base 'Launcher'),(Join-Path $base 'NotAceGame'),(Join-Path $base 'Unresolved')) -OnlyExtraRoots
    if($r.sessionExecutables -notcontains (Join-Path $game 'FutureGame.exe')){throw 'Unknown game with ACE marker was not discovered.'};Write-Output 'PASS: Unknown game discovered from ACE component evidence.'
    if($r.sessionExecutables.Count -ne 1){throw 'Helpers or unverified folders were misclassified.'};Write-Output 'PASS: Helpers and marker-free directories excluded.'
    if($r.gameDirectories -notcontains $game){throw 'Game root was not scoped below launcher.'};Write-Output 'PASS: Generic platform launcher excluded from game directory guard.'
    if($r.unresolved -ne 1){throw 'Unresolved ACE component was not reported.'};Write-Output 'PASS: ACE components without a game executable are reported.'
} finally {
    foreach($f in $files){Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue}
    foreach($d in ($dirs|Sort-Object Length -Descending)){Remove-Item -LiteralPath $d -ErrorAction SilentlyContinue}
}
