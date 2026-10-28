$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw '需要 Windows .NET Framework 4.x 编译器。' }
$dist = Join-Path $PSScriptRoot 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
# 使用系统 .NET Framework 编译器，脚本作为资源嵌入单文件 EXE。
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'scripts') -Filter '*.ps1' | ForEach-Object {
    [IO.File]::WriteAllText($_.FullName,[IO.File]::ReadAllText($_.FullName),[Text.UTF8Encoding]::new($true))
}
$compilerArguments = @('/nologo','/target:winexe','/platform:x64','/optimize+',('/out:'+(Join-Path $dist 'ACE-Auto-Manager.exe')),('/win32manifest:'+(Join-Path $PSScriptRoot 'src\app.manifest')),
    ('/win32icon:'+(Join-Path $PSScriptRoot 'assets\app.ico')),('/resource:'+(Join-Path $PSScriptRoot 'assets\app.ico')+',app.ico'),
    '/reference:System.dll','/reference:System.Core.dll','/reference:System.Drawing.dll','/reference:System.Windows.Forms.dll','/reference:System.Web.Extensions.dll',
    ('/resource:'+(Join-Path $PSScriptRoot 'scripts\Backend.ps1')+',Backend.ps1'),('/resource:'+(Join-Path $PSScriptRoot 'scripts\Monitor-Ace.ps1')+',Monitor-Ace.ps1'),('/resource:'+(Join-Path $PSScriptRoot 'scripts\Discover-AceGames.ps1')+',Discover-AceGames.ps1'),(Join-Path $PSScriptRoot 'src\Program.cs'))
& $compiler @compilerArguments
if ($LASTEXITCODE -ne 0) { throw '编译失败。' }
$exe = Join-Path $dist 'ACE-Auto-Manager.exe'
$test = Start-Process -FilePath $exe -ArgumentList '--self-test' -WindowStyle Hidden -PassThru -Wait
if ($test.ExitCode -ne 0) { throw 'EXE 自检失败。' }
(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLower() + '  ACE-Auto-Manager.exe' | Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding ASCII
Write-Output ('Build OK: '+$exe)
