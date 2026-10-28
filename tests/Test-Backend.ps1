$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Backend.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Backend syntax error'}
$definition=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-Request'},$true)
. ([scriptblock]::Create($definition.Extent.Text))
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('AceConfigTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$exe=Join-Path $testRoot 'VALORANT-Win64-Shipping.exe'
$RequestPath=Join-Path $testRoot 'request.json'
Set-Content -LiteralPath $exe -Value 'test fixture, never executed'
try {
    $base=@{userSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;graceSeconds=45;pollSeconds=5;closeOnLogin=$true;sessionExecutables=@($exe);blockerExecutables=@()}
    $base|ConvertTo-Json|Set-Content -LiteralPath $RequestPath -Encoding UTF8
    $null=Read-Request; Write-Output 'PASS: Valid supported game configuration accepted.'
    foreach($case in @('ZeroGames','InvalidGrace','InvalidLogin','UnsupportedExe','MissingExe','RelativePath')) {
        $c=$base.Clone()
        switch($case){
            ZeroGames {$c.sessionExecutables=@()}
            InvalidGrace {$c.graceSeconds=0}
            InvalidLogin {$c.closeOnLogin='false'}
            UnsupportedExe {$c.sessionExecutables=@((Join-Path $testRoot 'other.exe'))}
            MissingExe {$c.sessionExecutables=@((Join-Path $testRoot 'LeagueClient.exe'))}
            RelativePath {$c.sessionExecutables=@('VALORANT-Win64-Shipping.exe')}
        }
        $c|ConvertTo-Json|Set-Content -LiteralPath $RequestPath -Encoding UTF8
        $rejected=$false
        try {$null=Read-Request} catch {$rejected=$true}
        if(-not $rejected){throw ('Expected rejection: '+$case)}
        Write-Output ('PASS: '+$case+' rejected.')
    }
} finally {
    Remove-Item -LiteralPath $exe,$RequestPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -ErrorAction SilentlyContinue
}
