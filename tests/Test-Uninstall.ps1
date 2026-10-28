$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Remove-Launcher.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Removal script parse error'}
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-VerifiedLauncher'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
$folder=Join-Path ([IO.Path]::GetTempPath()) ('AceRemovalTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $folder | Out-Null
$target=Join-Path $folder "app with ' quote.exe"
$other=Join-Path $folder 'other.exe'
try {
    [IO.File]::WriteAllText($target,'fixture'); [IO.File]::WriteAllText($other,'keep')
    $hash=(Get-FileHash -LiteralPath $target).Hash
    $lock=[IO.File]::Open($target,'Open','Read','None')
    try {
        $failed=$false
        try {$null=Remove-VerifiedLauncher $target $hash} catch {$failed=$true}
        if(-not $failed -or -not (Test-Path -LiteralPath $target)){throw 'Locked executable should be retained for retry'}
    } finally {$lock.Dispose()}
    Write-Output 'PASS: Locked executable waits for retry'
    [IO.File]::WriteAllText($target,'replacement')
    $result=Remove-VerifiedLauncher $target $hash
    if($result.Removed -or $result.Retry -or -not (Test-Path -LiteralPath $target)){throw 'Replacement must be preserved'}
    Write-Output 'PASS: Changed executable cancels deletion'
    $hash=(Get-FileHash -LiteralPath $target).Hash
    $result=Remove-VerifiedLauncher $target $hash
    if(-not $result.Removed -or (Test-Path -LiteralPath $target) -or -not (Test-Path -LiteralPath $other)){throw 'Must remove only exact verified target'}
    Write-Output 'PASS: Exact path with spaces and quotes removed; other copy retained'
    $result=Remove-VerifiedLauncher $target $hash
    if(-not $result.Removed){throw 'Already removed file should succeed'}
    Write-Output 'PASS: Already absent executable succeeds'
} finally {
    Remove-Item -LiteralPath $target,$other -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $folder
}
