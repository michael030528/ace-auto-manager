$ErrorActionPreference = 'Stop'
$packageRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'
. (Join-Path $packageRoot 'Monitor-Ace.ps1') -LibraryOnly
$script:stateCheckCount = 0

function Assert-State([string]$Name, $Result, [string]$Expected, [bool]$ShouldClose) {
    if ($Result.State -ne $Expected -or $Result.Close -ne $ShouldClose) {
        throw ('FAILED: {0}: {1}' -f $Name, ($Result | ConvertTo-Json -Compress))
    }
    $script:stateCheckCount++
    Write-Output ('PASS: ' + $Name)
}

# 登录首次清理必须重新计时，不能沿用进程启动前或其他会话的时间。
$result = Get-NextSessionState Startup 0 0 10000 0 45
Assert-State 'Startup with no game begins a fresh quiet period instead of closing immediately' $result Waiting $false
if ($result.QuietSince -ne 10000) { throw 'Startup did not begin its quiet period at the current observation time' }
$result = Get-NextSessionState Waiting 0 0 10044.99 10000 45
Assert-State 'Startup cleanup does not run before 45 continuous quiet seconds' $result Waiting $false
$result = Get-NextSessionState Waiting 0 0 10045 10000 45
Assert-State 'Startup cleanup becomes eligible at exactly 45 continuous quiet seconds' $result Waiting $true

$result = Get-NextSessionState Startup 1 1 10 123 45
Assert-State 'A real game present at startup enters the active session without closing ACE' $result Active $false
if ($result.QuietSince -ne 0) { throw 'A game at startup did not reset the quiet period' }
$result = Get-NextSessionState Startup 0 1 10000 123 45
Assert-State 'A launcher at startup blocks cleanup and resets any prior quiet time' $result Active $false
if ($result.QuietSince -ne 0) { throw 'A startup launcher did not reset the quiet period' }
$result = Get-NextSessionState $result.State 0 0 10010 $result.QuietSince 45
Assert-State 'Startup cleanup starts its timer only after the blocking launcher exits' $result Waiting $false
if ($result.QuietSince -ne 10010) { throw 'Launcher exit did not start a fresh startup quiet period' }
$result = Get-NextSessionState Waiting 0 0 10054.99 10010 45
Assert-State 'Time spent waiting for the startup launcher does not count as quiet time' $result Waiting $false

# 登录清理期间游戏重新出现，退出后必须再完整等待45秒。
$result = Get-NextSessionState Waiting 1 1 10054.995 10010 45
Assert-State 'A game starting during startup cleanup cancels the pending shutdown' $result Active $false
if ($result.QuietSince -ne 0) { throw 'A game during startup cleanup did not cancel the old timer' }
$result = Get-NextSessionState $result.State 0 0 10060 $result.QuietSince 45
Assert-State 'After the newly started game exits, cleanup begins another full quiet period' $result Waiting $false
if ($result.QuietSince -ne 10060) { throw 'The game exit reused an obsolete startup quiet time' }
$result = Get-NextSessionState Waiting 0 0 10090 10060 45
Assert-State 'An interrupted startup timer cannot cause early cleanup after the game exits' $result Waiting $false
$result = Get-NextSessionState Waiting 0 0 10105 10060 45
Assert-State 'Cleanup after the startup interruption becomes eligible only after the new 45 seconds' $result Waiting $true

$result = Get-NextSessionState Idle 0 0 10000 0 45
Assert-State 'Idle after completed cleanup never loops into another shutdown, even after a long wait' $result Idle $false
$result = Get-NextSessionState Idle 0 1 10000 0 45
Assert-State 'A launcher alone does not rearm shutdown after cleanup has returned to Idle' $result Idle $false
$result = Get-NextSessionState Idle 1 1 10 0 45
Assert-State 'An observed game arms the session' $result Active $false
$result = Get-NextSessionState Active 1 1 20 0 45
Assert-State 'Another game still running prevents cleanup' $result Active $false
$result = Get-NextSessionState Active 0 1 30 0 45
Assert-State 'A remaining lobby or launcher blocks cleanup' $result Active $false
$result = Get-NextSessionState Active 0 0 40 0 45
Assert-State 'After all games exit the quiet period starts' $result Waiting $false
if ($result.QuietSince -ne 40) { throw 'Wrong grace period start' }
$result = Get-NextSessionState Waiting 0 0 84.99 40 45
Assert-State 'Cleanup cannot run early' $result Waiting $false
$result = Get-NextSessionState Waiting 0 0 85 40 45
Assert-State 'Cleanup becomes eligible after 45 continuous seconds' $result Waiting $true
$result = Get-NextSessionState Waiting 1 1 84 40 45
Assert-State 'A restarted game cancels pending cleanup' $result Active $false
if ($result.QuietSince -ne 0) { throw 'Relaunch did not reset the quiet period' }
$result = Get-NextSessionState Waiting 0 1 84 40 45
Assert-State 'A new launcher cancels pending cleanup' $result Active $false
$result = Get-NextSessionState Idle 0 0 200 0 45
Assert-State 'A completed cleanup is not retried without a new game' $result Idle $false
Write-Output ('All {0} startup/session-state checks passed. No services or drivers were changed.' -f $script:stateCheckCount)
