$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Monitor-Ace.ps1'),[ref]$tokens,[ref]$errors)
$f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-GameActivity'},$true)
. ([scriptblock]::Create($f.Extent.Text))
$config=[pscustomobject]@{sessionExecutables=@('C:\Games\Example\Play.exe');blockerExecutables=@();gameDirectories=@('C:\Games\Example')}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction) return $script:fakeProcesses}
$script:fakeProcesses=@([pscustomobject]@{Name='Child.exe';ExecutablePath='C:\Games\Example\bin\Child.exe'})
if((Get-GameActivity).Blockers -ne 1){throw 'Unknown child process was not protected.'};Write-Output 'PASS: Newly introduced child process inside game directory blocks cleanup.'
$script:fakeProcesses=@([pscustomobject]@{Name='Child.exe';ExecutablePath='C:\Games\Example2\Child.exe'})
if((Get-GameActivity).Blockers -ne 0){throw 'Sibling directory was misclassified.'};Write-Output 'PASS: Similar sibling directory does not block cleanup.'
$script:fakeProcesses=@([pscustomobject]@{Name='ACE-Helper.exe';ExecutablePath='C:\Games\Example\AntiCheatExpert\ACE-Helper.exe'})
if((Get-GameActivity).Blockers -ne 0){throw 'ACE itself prevents cleanup.'};Write-Output 'PASS: ACE components do not count as running games.'
$script:fakeProcesses=@([pscustomobject]@{Name='Play.exe';ExecutablePath=$null})
if((Get-GameActivity).Blockers -ne 1){throw 'Inaccessible recognized process should block cleanup.'};Write-Output 'PASS: Recognized process with inaccessible path blocks cleanup conservatively.'
