param(
    [string]$MonitorPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\Monitor-Ace.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# 仅加载类型与函数定义；不运行产品脚本、真实服务控制器或监测循环。
Add-Type -AssemblyName System.ServiceProcess
$parseTokens = $null
$parseErrors = $null
$sourceAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $MonitorPath, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('Product script has parse errors: ' + ($parseErrors.Message -join '; ')) }

# 新增真实系统调用必须先补 mock，避免未来修改意外越过隔离边界。
$allowedCommands = @(
    'Get-GameActivity', 'Assert-NoGame', 'Get-AceTargets', 'Get-AceProcesses',
    'New-Object', 'Get-CimInstance', 'Get-Process', 'Start-Sleep',
    'Write-AceLog', 'Save-AceStatus', 'Where-Object', 'Join-Path'
)
foreach ($functionName in @('Assert-NoGame', 'Close-AceAfterGame')) {
    $definitions = @($sourceAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
    }, $true))
    if ($definitions.Count -ne 1) { throw ('Expected one function definition: ' + $functionName) }
    foreach ($command in @($definitions[0].FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))) {
        $commandName = $command.GetCommandName()
        if (-not $commandName -or $allowedCommands -notcontains $commandName) {
            throw ('Unmocked command in product function: ' + $command.Extent.Text)
        }
    }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
}

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('ASSERTION FAILED: ' + $Message) }
}

function New-TestFixture([string]$CaseName) {
    $script:fixture = @{
        CaseName = $CaseName
        TargetName = $(if ($CaseName -eq 'PendingBootNeedsTray') { 'ACE-BOOT' } else { 'SIMULATED-ACE-SERVICE' })
        Stopped = $false
        TrayKilled = $false
        GamePresent = $false
        GameChecks = 0
        StopCalls = 0
        WaitCalls = 0
        KillCalls = 0
        DisposeCalls = 0
        ConstructorCalls = 0
        LastState = ''
        LastDetail = ''
        Logs = [System.Collections.Generic.List[string]]::new()
        EscapedError = ''
    }
    $script:mockTrayPath = Join-Path $env:ProgramFiles 'AntiCheatExpert\ACE-Tray.exe'
    $script:mockTray = [pscustomobject]@{ Path = $script:mockTrayPath }
    $script:mockTray | Add-Member -MemberType ScriptMethod -Name Kill -Value {
        $script:fixture.KillCalls++
        $script:fixture.TrayKilled = $true
    }
    $script:mockController = [pscustomobject]@{
        Status = [System.ServiceProcess.ServiceControllerStatus]::Running
        CanStop = ($CaseName -ne 'CannotStop')
        DependentServices = @()
    }
    $script:mockController | Add-Member -MemberType ScriptMethod -Name Refresh -Value {
        if ($script:fixture.CaseName -eq 'GameAppearsBeforeStop') {
            $script:fixture.GamePresent = $true
        }
    }
    $script:mockController | Add-Member -MemberType ScriptMethod -Name Stop -Value {
        $script:fixture.StopCalls++
        if ($script:fixture.CaseName -eq 'StopThrows') { throw 'SIMULATED: SCM rejected stop.' }
        $this.Status = [System.ServiceProcess.ServiceControllerStatus]::StopPending
    }
    $script:mockController | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
        param($DesiredStatus, $Timeout)
        $script:fixture.WaitCalls++
        Assert-Test ($DesiredStatus -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) 'WaitForStatus must wait for Stopped.'
        Assert-Test ($Timeout -is [TimeSpan] -and $Timeout.TotalSeconds -gt 0) 'WaitForStatus must have a finite positive timeout.'
        Assert-Test ($script:fixture.StopCalls -eq 1) 'WaitForStatus must follow the stop request.'
        if ($script:fixture.CaseName -eq 'PendingBootNeedsTray') {
            throw 'SIMULATED: WaitForStatus timed out while ACE-BOOT waits for tray exit.'
        }
        $this.Status = [System.ServiceProcess.ServiceControllerStatus]::Stopped
        $script:fixture.Stopped = $true
    }
    $script:mockController | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $script:fixture.DisposeCalls++
    }
}

# 所有系统边界均返回测试对象；不回退到真实命令。
function Get-GameActivity {
    $script:fixture.GameChecks++
    if ($script:fixture.GamePresent) {
        return @{ Sessions = 1; Blockers = 1; Names = @('SIMULATED-GAME.exe') }
    }
    return @{ Sessions = 0; Blockers = 0; Names = @() }
}

function Get-AceTargets {
    $targetState = if ($script:fixture.Stopped) { 'Stopped' } else { 'Running' }
    if ($script:fixture.CaseName -eq 'PendingBootNeedsTray' -and $script:fixture.StopCalls -gt 0) {
        $targetState = if ($script:fixture.TrayKilled) { 'Stopped' } else { 'Stop Pending' }
    }
    [pscustomobject]@{
        Name = $script:fixture.TargetName
        State = $targetState
        Kind = $(if ($script:fixture.CaseName -eq 'PendingBootNeedsTray') { 'Driver' } else { 'Service' })
        Rank = $(if ($script:fixture.CaseName -eq 'PendingBootNeedsTray') { 2 } else { 0 })
    }
}

function Get-AceProcesses {
    if (-not $script:fixture.TrayKilled) {
        [pscustomobject]@{ Name = 'ACE-Tray.exe'; ProcessId = 424242; ExecutablePath = $script:mockTrayPath }
    }
}

function New-Object {
    param(
        [Parameter(Position = 0)][string]$TypeName,
        [Parameter(Position = 1)][object[]]$ArgumentList
    )
    if ($TypeName -ne 'System.ServiceProcess.ServiceController') { throw ('Unexpected constructor: ' + $TypeName) }
    if ($ArgumentList.Count -ne 1 -or $ArgumentList[0] -ne $script:fixture.TargetName) { throw 'Unexpected service constructor arguments.' }
    $script:fixture.ConstructorCalls++
    return $script:mockController
}

function Get-CimInstance {
    param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    if ($ClassName -ne 'Win32_Process' -or $Filter -ne "Name='ACE-Tray.exe'") { throw 'Unexpected CIM query.' }
    if (-not $script:fixture.TrayKilled) {
        [pscustomobject]@{ Name = 'ACE-Tray.exe'; ProcessId = 424242; ExecutablePath = $script:mockTrayPath }
    }
}

function Get-Process {
    [CmdletBinding()]
    param([int]$Id)
    if ($Id -ne 424242) { throw 'Unexpected process lookup.' }
    if (-not $script:fixture.TrayKilled) { return $script:mockTray }
}

function Start-Sleep { param([int]$Seconds) }
function Write-AceLog([string]$Message) { $script:fixture.Logs.Add($Message) }
function Save-AceStatus([string]$State, [string]$Detail) {
    $script:fixture.LastState = $State
    $script:fixture.LastDetail = $Detail
}

$caseResults = foreach ($caseName in @('Normal', 'CannotStop', 'StopThrows', 'GameAppearsBeforeStop', 'PendingBootNeedsTray')) {
    New-TestFixture $caseName
    $cleanupResult = $null
    try { $cleanupResult = Close-AceAfterGame } catch { $script:fixture.EscapedError = $_.Exception.Message }
    $assertionError = ''
    try {
        Assert-Test ($script:fixture.ConstructorCalls -eq 1) 'Exactly one mocked controller must be constructed.'
        Assert-Test ($script:fixture.DisposeCalls -eq 1) 'Controller must be disposed on every path.'
        switch ($caseName) {
            'Normal' {
                Assert-Test ($script:fixture.EscapedError -eq '') ('Unexpected error: ' + $script:fixture.EscapedError)
                Assert-Test ($script:fixture.StopCalls -eq 1) 'Normal target must receive Stop.'
                Assert-Test ($script:fixture.WaitCalls -eq 1) 'Normal target must call WaitForStatus.'
                Assert-Test ($script:fixture.KillCalls -eq 1) 'Tray must close after all targets stop.'
                Assert-Test ($script:fixture.LastState -eq 'Closed') 'Successful cleanup must report Closed.'
                Assert-Test ($cleanupResult -eq $true) 'Success must cancel retry scheduling.'
            }
            'CannotStop' {
                Assert-Test ($script:fixture.EscapedError -eq '') ('Unexpected error: ' + $script:fixture.EscapedError)
                Assert-Test ($script:fixture.StopCalls -eq 0 -and $script:fixture.WaitCalls -eq 0) 'CannotStop target must receive no stop or wait.'
                Assert-Test ($script:fixture.KillCalls -eq 0) 'Tray must remain while target is running.'
                Assert-Test ($script:fixture.LastState -eq 'Partial') 'CannotStop must report Partial.'
                Assert-Test ($cleanupResult -eq $false) 'Partial cleanup must allow bounded retries.'
            }
            'StopThrows' {
                Assert-Test ($script:fixture.EscapedError -eq '') ('Stop exception should be handled: ' + $script:fixture.EscapedError)
                Assert-Test ($script:fixture.StopCalls -eq 1 -and $script:fixture.WaitCalls -eq 0) 'Rejected stop must not wait.'
                Assert-Test ($script:fixture.KillCalls -eq 0) 'Rejected stop must not kill tray.'
                Assert-Test ($script:fixture.LastState -eq 'Partial') 'Rejected stop must report Partial.'
            }
            'GameAppearsBeforeStop' {
                Assert-Test ($script:fixture.GameChecks -ge 3) 'Game state must be rechecked after controller inspection.'
                Assert-Test ($script:fixture.StopCalls -eq 0 -and $script:fixture.WaitCalls -eq 0) 'A newly started game must prevent Stop.'
                Assert-Test ($script:fixture.KillCalls -eq 0) 'A newly started game must prevent tray termination.'
                Assert-Test ($script:fixture.LastState -ne 'Closed') 'Cancellation must never report Closed.'
            }
            'PendingBootNeedsTray' {
                Assert-Test ($script:fixture.EscapedError -eq '') ('Unexpected error: ' + $script:fixture.EscapedError)
                Assert-Test ($script:fixture.StopCalls -eq 1 -and $script:fixture.WaitCalls -eq 1) 'Pending ACE-BOOT must receive exactly one stop and timed wait.'
                Assert-Test ($script:fixture.KillCalls -eq 1) 'Pending ACE-BOOT must allow exactly one tray termination.'
                Assert-Test ($script:fixture.LastState -eq 'Closed') 'ACE-BOOT that stops after tray exit must report Closed.'
            }
        }
    } catch { $assertionError = $_.Exception.Message }
    [pscustomobject]@{
        Case = $caseName
        Passed = ($assertionError -eq '')
        StopCalls = $script:fixture.StopCalls
        WaitCalls = $script:fixture.WaitCalls
        KillCalls = $script:fixture.KillCalls
        FinalState = $script:fixture.LastState
        Error = $assertionError
        CleanupException = $script:fixture.EscapedError
        Logs = @($script:fixture.Logs.ToArray())
    }
}
$caseResults | ConvertTo-Json -Depth 5
if (@($caseResults | Where-Object { -not $_.Passed }).Count -gt 0) { exit 1 }
exit 0
