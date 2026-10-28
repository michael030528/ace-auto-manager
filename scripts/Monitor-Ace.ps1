param([switch]$CheckOnly, [switch]$LibraryOnly, [switch]$RetryFailedCleanup)
$ErrorActionPreference = 'Stop'
# 独立的 Windows PowerShell 5.1 后台进程不会自动加载此程序集。
Add-Type -AssemblyName System.ServiceProcess -ErrorAction Stop

# 登录后及游戏退出后均等待连续静默期；完成清理后不循环重复停止。
function Get-NextSessionState {
    param([string]$State, [int]$SessionCount, [int]$BlockerCount,
          [double]$Now, [double]$QuietSince, [int]$GraceSeconds)
    if ($SessionCount -gt 0) {
        return @{ State = 'Active'; QuietSince = 0; Close = $false }
    }
    if ($State -eq 'Idle') {
        return @{ State = 'Idle'; QuietSince = 0; Close = $false }
    }
    if ($BlockerCount -gt 0) {
        return @{ State = 'Active'; QuietSince = 0; Close = $false }
    }
    if ($State -eq 'Active' -or $State -eq 'Startup') {
        return @{ State = 'Waiting'; QuietSince = $Now; Close = $false }
    }
    return @{ State = 'Waiting'; QuietSince = $QuietSince; Close = (($Now - $QuietSince) -ge $GraceSeconds) }
}

if ($LibraryOnly) { return }
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Encoding UTF8 | ConvertFrom-Json
# 缺少字段的旧配置也启用登录清理；显式 false 可保留开机预启动模式。
$closeOnLogin = $true
if ($null -ne $config.PSObject.Properties['closeOnLogin']) {
    if ($config.closeOnLogin -isnot [bool]) { throw 'closeOnLogin must be a JSON boolean.' }
    $closeOnLogin = $config.closeOnLogin
}
$dataRoot = Join-Path $env:ProgramData 'AceGameAutoClose'
$logPath = Join-Path $dataRoot 'monitor.log'
$statusPath = Join-Path $dataRoot 'status.json'

function Write-AceLog([string]$Message) {
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 2097152) {
        Move-Item -LiteralPath $logPath -Destination ($logPath + '.previous') -Force
    }
    Add-Content -LiteralPath $logPath -Encoding UTF8 -Value ('{0:o} {1}' -f (Get-Date), $Message)
}

function Save-AceStatus([string]$State, [string]$Detail) {
    [ordered]@{ updatedAt = (Get-Date).ToString('o'); state = $State; detail = $Detail; monitorPid = $PID } |
        ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

# 按已核对的游戏路径识别会话；同名但路径不可读的进程保守视为阻止关闭。
function Get-GameActivity {
    $paths = @($config.sessionExecutables) + @($config.blockerExecutables)
    $names = @($paths | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object -Unique)
    $filter = ($names | ForEach-Object { "Name='" + $_.Replace("'", "''") + "'" }) -join ' OR '
    $directories = @($config.gameDirectories | Where-Object { $_ })
    if($directories.Count -gt 0) {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $proc=$_
            $matched=$names -contains $proc.Name
            if(-not $matched -and $proc.ExecutablePath -and $proc.ExecutablePath -notmatch '(?i)\\AntiCheatExpert\\' -and $proc.Name -notmatch '(?i)^(ACE[-_]|SGuard)') {
                foreach($directory in $directories) { if($proc.ExecutablePath.StartsWith($directory.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {$matched=$true;break} }
            }
            $matched
        })
    } else { $processes = @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction Stop) }
    $sessions = @($processes | Where-Object { $_.ExecutablePath -and $config.sessionExecutables -contains $_.ExecutablePath })
    # 其他路径下的同名游戏同样阻止关闭，避免移动安装目录后误停共享 ACE。
    return @{ Sessions = $sessions.Count; Blockers = $processes.Count; Names = @($processes.Name) }
}

function Assert-NoGame {
    $activity = Get-GameActivity
    if ($activity.Blockers -gt 0) { throw 'A game or game client is running; cleanup cancelled.' }
}

function Get-AceTargets {
    $services = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
        $_.PathName -match '(?i)\\AntiCheatExpert\\'
    } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; State = $_.State; Kind = 'Service'; Rank = 0 } })
    $drivers = @(Get-CimInstance Win32_SystemDriver -ErrorAction Stop | Where-Object {
        $_.PathName -match '(?i)\\AntiCheatExpert\\|\\drivers\\ACE[-_]'
    } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; State = $_.State; Kind = 'Driver'; Rank = $(if ($_.Name -eq 'ACE-BOOT') { 2 } else { 1 }) } })
    return @($services + $drivers | Sort-Object Rank, Name)
}

function Get-AceProcesses {
    return @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.ExecutablePath -match '(?i)\\AntiCheatExpert\\' -or
        (@('ACE-Helper.exe', 'ACE-Service64.exe', 'ACE-Tray.exe', 'SGuard64.exe', 'SGuardSvc64.exe') -contains $_.Name)
    })
}

# 只向 Windows 请求正常停止，拒绝停止或超时均如实记录，不强制卸载驱动。
function Close-AceAfterGame {
    Assert-NoGame
    $targets = @(Get-AceTargets)
    foreach ($target in $targets) {
        Assert-NoGame
        $controller = $null
        try {
            $controller = New-Object System.ServiceProcess.ServiceController($target.Name)
            $controller.Refresh()
            if ($controller.Status -eq 'Stopped') { continue }
            if (-not $controller.CanStop) {
                Write-AceLog ('REFUSED: {0} does not accept a normal stop.' -f $target.Name)
                continue
            }
            $runningDependents = @($controller.DependentServices | Where-Object { $_.Status -ne 'Stopped' })
            if ($runningDependents.Count -gt 0) {
                Write-AceLog ('SKIPPED: {0} has running dependents: {1}' -f $target.Name, ($runningDependents.ServiceName -join ', '))
                continue
            }
            Assert-NoGame
            $controller.Stop()
            $controller.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(8))
            Write-AceLog ('STOPPED: {0}' -f $target.Name)
        } catch {
            if ($target.Name -eq 'ACE-BOOT' -and $controller -and $controller.Status -eq 'StopPending') {
                Write-AceLog 'STOP PENDING: ACE-BOOT accepted the stop request; the remaining tray process will be closed before verification.'
            } else {
                Write-AceLog ('STOP FAILED: {0}: {1}' -f $target.Name, $_.Exception.Message)
            }
        } finally { if ($null -ne $controller) { $controller.Dispose() } }
    }
    Assert-NoGame
    $stillRunning = @(Get-AceTargets | Where-Object { $_.State -ne 'Stopped' })
    # 本机实测：BOOT 已接受停止但仍 Pending 时，退出托盘后才完成卸载。
    # 仅放行此明确状态；其他服务或驱动仍运行时继续保留托盘并报告未完全关闭。
    $onlyBootPending = $stillRunning.Count -eq 1 -and $stillRunning[0].Name -eq 'ACE-BOOT' -and $stillRunning[0].State -eq 'Stop Pending'
    if ($stillRunning.Count -eq 0 -or $onlyBootPending) {
        $trayPath = Join-Path $env:ProgramFiles 'AntiCheatExpert\ACE-Tray.exe'
        foreach ($tray in @(Get-CimInstance Win32_Process -Filter "Name='ACE-Tray.exe'")) {
            Assert-NoGame
            if ($tray.ExecutablePath -eq $trayPath) {
                # 再核对 PID 对应路径，避免进程退出后 PID 被其他程序复用。
                $liveTray = Get-Process -Id $tray.ProcessId -ErrorAction SilentlyContinue
                if ($liveTray -and $liveTray.Path -eq $trayPath) { $liveTray.Kill() }
            }
        }
    }
    Start-Sleep -Seconds 5
    Assert-NoGame
    $remainingTargets = @(Get-AceTargets | Where-Object { $_.State -ne 'Stopped' })
    $remainingProcesses = @(Get-AceProcesses)
    if ($remainingTargets.Count -eq 0 -and $remainingProcesses.Count -eq 0) {
        Write-AceLog 'CLOSED: all discovered ACE services, drivers and processes are stopped. A reboot may be needed for the next game.'
        Save-AceStatus 'Closed' 'All discovered ACE components stopped. The next game may require a reboot.'
    } else {
        $detail = 'Remaining services/drivers: {0}; processes: {1}' -f ($remainingTargets.Name -join ', '), ($remainingProcesses.Name -join ', ')
        Write-AceLog ('PARTIAL: ' + $detail)
        Save-AceStatus 'Partial' $detail
    }
}

if ($CheckOnly) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    # 预检实际创建关闭路径使用的控制器；已停止的目标只验证等待接口，不发送停止请求。
    $controllerChecks = @(foreach ($target in @(Get-AceTargets)) {
        $controller = $null
        try {
            $controller = New-Object System.ServiceProcess.ServiceController($target.Name)
            $controller.Refresh()
            if ($controller.Status -eq 'Stopped') {
                $controller.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(1))
            }
            [pscustomobject]@{ name = $target.Name; status = [string]$controller.Status; canStop = $controller.CanStop;
                dependentServices = @($controller.DependentServices | ForEach-Object { $_.ServiceName }) }
        } finally { if ($null -ne $controller) { $controller.Dispose() } }
    })
    [ordered]@{ account = $identity.Name; elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);
        closeOnLogin = $closeOnLogin;
        serviceControllerAssembly = [System.ServiceProcess.ServiceController].Assembly.FullName; controllerChecks = $controllerChecks;
        activity = (Get-GameActivity); targets = @(Get-AceTargets); processes = @(Get-AceProcesses | Select-Object Name, ProcessId);
        missingGameFiles = @((@($config.sessionExecutables) + @($config.blockerExecutables)) | Where-Object { -not (Test-Path -LiteralPath $_) }) } |
        ConvertTo-Json -Depth 5
    exit 0
}

$mutex = New-Object Threading.Mutex($false, 'Global\AceGameAutoClose-Monitor-v1')
try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
if (-not $ownsMutex) { $mutex.Dispose(); exit 0 }
try {
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    if ($RetryFailedCleanup) {
        # 仅重试本次开机内已观察到游戏、且因缺失程序集而失败的清理。
        $previous = Get-Content -LiteralPath $statusPath -Encoding UTF8 | ConvertFrom-Json
        $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        if ($previous.state -ne 'Attention' -or $previous.detail -notmatch 'System.ServiceProcess.ServiceController' -or
            ([DateTimeOffset]::Parse($previous.updatedAt)).LocalDateTime -lt $bootTime) {
            throw 'No eligible failed cleanup from this boot; automatic retry skipped.'
        }
        Write-AceLog 'REPAIR RETRY: waiting for a fresh uninterrupted quiet period before retrying the observed failed game-session cleanup.'
        Save-AceStatus 'Waiting' 'Repair installed; verifying that no game restarts before retrying the failed cleanup.'
        $retryTimer = [Diagnostics.Stopwatch]::StartNew()
        while ($retryTimer.Elapsed.TotalSeconds -lt $config.graceSeconds) {
            Assert-NoGame
            Start-Sleep -Seconds $config.pollSeconds
        }
        Close-AceAfterGame
        return
    }
    if ($closeOnLogin) {
        Write-AceLog 'STARTED: login cleanup enabled; waiting for a continuous no-game grace period. Game startup postpones cleanup.'
        Save-AceStatus 'Startup' 'Login cleanup enabled. ACE will close after a continuous no-game grace period; original boot settings are unchanged.'
        $state = 'Startup'
    } else {
        Write-AceLog 'STARTED: login cleanup disabled; waiting to observe a game session before cleanup.'
        Save-AceStatus 'Idle' 'Login cleanup disabled. Waiting for a game session; original ACE boot settings are unchanged.'
        $state = 'Idle'
    }
    $quietSince = 0
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $lastHeartbeat = -30
    while ($true) {
        if ($timer.Elapsed.TotalSeconds - $lastHeartbeat -ge 30) {
            @{time=(Get-Date).ToString('o');pid=$PID} | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $dataRoot 'heartbeat.json') -Encoding UTF8
            $lastHeartbeat = $timer.Elapsed.TotalSeconds
        }
        try {
            $activity = Get-GameActivity
            $next = Get-NextSessionState -State $state -SessionCount $activity.Sessions -BlockerCount $activity.Blockers -Now $timer.Elapsed.TotalSeconds -QuietSince $quietSince -GraceSeconds $config.graceSeconds
            if ($next.State -ne $state) {
                Write-AceLog ('STATE: {0} -> {1}; game processes: {2}' -f $state, $next.State, ($activity.Names -join ', '))
                Save-AceStatus $next.State ($activity.Names -join ', ')
            }
            $state = $next.State
            $quietSince = $next.QuietSince
            if ($next.Close) {
                # 登录后的初次清理和每次游戏会话各执行一次，不反复停止。
                $state = 'Idle'
                $quietSince = 0
                Close-AceAfterGame
            }
        } catch {
            Write-AceLog ('CHECK/CLEANUP CANCELLED: ' + $_.Exception.Message)
            # 检测失败后重新累计安静时间，不能把不可见进程误判为游戏退出。
            if ($state -eq 'Waiting') { $state = 'Active'; $quietSince = 0 }
            Save-AceStatus 'Attention' $_.Exception.Message
        }
        Start-Sleep -Seconds $config.pollSeconds
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
