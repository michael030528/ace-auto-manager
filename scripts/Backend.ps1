param([ValidateSet('Discover','Status','Install','Pause','Remove','Validate','Clean')][string]$Mode = 'Status', [string]$RequestPath)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = Join-Path $env:ProgramFiles 'AceGameAutoClose'
$data = Join-Path $env:ProgramData 'AceGameAutoClose'
$taskName = 'ACE Game Auto Close'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# 配置作为数据读取，绝不拼入可执行命令。
function Read-Request {
    $c = Get-Content -LiteralPath $RequestPath -Encoding UTF8 | ConvertFrom-Json
    $null = [Security.Principal.SecurityIdentifier]::new([string]$c.userSid)
    if ($c.graceSeconds -isnot [int] -or $c.graceSeconds -lt 15 -or $c.graceSeconds -gt 300) { throw '等待时间必须为 15 至 300 秒。' }
    if ($c.closeOnLogin -isnot [bool]) { throw '登录清理设置无效。' }
    if (@($c.sessionExecutables).Count -lt 1 -or @($c.sessionExecutables).Count -gt 100) { throw '请先添加至少一个支持的游戏。' }
    foreach ($p in @($c.sessionExecutables) + @($c.blockerExecutables)) {
        if (-not [IO.Path]::IsPathRooted($p) -or [IO.Path]::GetExtension($p) -ne '.exe' -or $p -match '[\r\n]') { throw '游戏路径格式无效。' }
    }
    foreach ($p in $c.sessionExecutables) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ('游戏文件不存在：' + $p) }
    }
    foreach($p in @($c.gameDirectories)) { if($p -and (-not [IO.Path]::IsPathRooted($p) -or -not (Test-Path -LiteralPath $p -PathType Container) -or [IO.Path]::GetPathRoot($p).TrimEnd('\') -eq $p.TrimEnd('\'))) { throw '游戏目录必须是有效的独立目录，不能是整个磁盘。' } }
    $c.pollSeconds = 5
    return $c
}

# 持久的高权限代码只放在管理员和 SYSTEM 可写的目录。
function Protect-Directory([string]$path) {
    if (Test-Path -LiteralPath $path) {
        Assert-Protected $path
        return
    }
    New-Item -ItemType Directory -Path $path | Out-Null
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-32-545')) {
        $rights = if ($sid -eq 'S-1-5-32-545') { 'ReadAndExecute' } else { 'FullControl' }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,'ContainerInherit,ObjectInherit','None','Allow'))
    }
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -LiteralPath $path -AclObject $acl
}
function Assert-Protected([string]$path) {
    if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '安装位置不能是目录链接。' }
    $acl = Get-Acl -LiteralPath $path
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')) { throw '安装位置所有者不符合安全要求。' }
    $mask = [Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    foreach ($a in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($a.AccessControlType -eq 'Allow' -and ($a.FileSystemRights -band $mask) -and $a.IdentityReference.Value -notin @('S-1-5-18','S-1-5-32-544')) { throw '安装目录允许普通用户写入，请先修复目录权限。' }
    }
}
function Read-OwnedTask {
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($t -and (@($t.Actions).Count -ne 1 -or $t.Actions.Execute -ne $psExe -or $t.Actions.Arguments -notlike ('*"' + (Join-Path $root 'Monitor-Ace.ps1') + '"*'))) { throw '发现同名的其他任务，操作已取消。' }
    return $t
}
function Stop-OwnedTask {
    $t = Read-OwnedTask
    if ($t) {
        Stop-ScheduledTask -TaskName $taskName
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
            if ($watch.Elapsed.TotalSeconds -gt 15) { throw '后台任务停止超时，未继续修改文件。' }
            Start-Sleep -Milliseconds 250
        }
    }
    return $t
}

try {
    if($Mode -eq 'Discover') {
        . (Join-Path $PSScriptRoot 'Discover-AceGames.ps1')
        $discovery=Find-AceGames
        @{ok=$true;discovery=$discovery}|ConvertTo-Json -Depth 7 -Compress
        exit 0
    }
    if ($Mode -eq 'Validate') { $null = Read-Request; @{ok=$true} | ConvertTo-Json; exit 0 }
    if ($Mode -eq 'Status') {
        $status = $null
        $statusPath = Join-Path $data 'status.json'
        if (Test-Path -LiteralPath $statusPath) { try { $status = Get-Content -LiteralPath $statusPath -Encoding UTF8 | ConvertFrom-Json } catch {} }
        $heartbeat = Join-Path $data 'heartbeat.json'
        $alive = $false
        if (Test-Path -LiteralPath $heartbeat) {
            try {
                $h = Get-Content -LiteralPath $heartbeat -Encoding UTF8 | ConvertFrom-Json
                $age = ([DateTimeOffset]::Now - [DateTimeOffset]::Parse($h.time)).TotalSeconds
                $p = Get-Process -Id $h.pid -ErrorAction SilentlyContinue
                $alive = $age -ge 0 -and $age -lt 90 -and $p -and $p.ProcessName -eq 'powershell'
            } catch {}
        }
        $drivers = @(Get-CimInstance Win32_SystemDriver | Where-Object { $_.PathName -match '(?i)\\AntiCheatExpert\\|\\drivers\\ACE[-_]' -and $_.State -ne 'Stopped' } | Select-Object Name,State)
        $services = @(Get-CimInstance Win32_Service | Where-Object { $_.PathName -match '(?i)\\AntiCheatExpert\\' -and $_.State -ne 'Stopped' } | Select-Object Name,State)
        $processes = @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -match '(?i)\\AntiCheatExpert\\' -or $_.Name -in @('ACE-Helper.exe','ACE-Service64.exe','ACE-Tray.exe','SGuard64.exe','SGuardSvc64.exe') } | Select-Object Name,ProcessId)
        @{ok=$true;installed=(Test-Path -LiteralPath (Join-Path $root 'Monitor-Ace.ps1'));monitorAlive=[bool]$alive;status=$status;drivers=$drivers;services=$services;processes=$processes} | ConvertTo-Json -Depth 6 -Compress
        exit 0
    }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '此操作需要 Windows 管理员授权。' }
    if ($Mode -eq 'Clean') {
        Assert-Protected $root
        Assert-Protected $data
        $monitor = Join-Path $root 'Monitor-Ace.ps1'
        Assert-Protected $monitor
        if (-not ([IO.File]::ReadAllText($monitor).Contains('cleanup-request.json'))) { throw '请先点击一键开启自动管理，安装当前版本的后台。' }
        $t = Read-OwnedTask
        if (-not $t -or $t.State -ne 'Running') { throw '请先开启自动管理，再立即清理。' }
        $requestFile = Join-Path $data 'cleanup-request.json'
        if (Test-Path -LiteralPath $requestFile) { Assert-Protected $requestFile }
        @{createdAt=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath ($requestFile+'.tmp') -Encoding UTF8
        Move-Item -LiteralPath ($requestFile+'.tmp') -Destination $requestFile -Force
        @{ok=$true;message='清理请求已提交，后台会先检查游戏，再执行清理。'} | ConvertTo-Json -Compress
        exit 0
    }
    if ($Mode -eq 'Pause' -or $Mode -eq 'Remove') {
        Protect-Directory $data
        $t = Stop-OwnedTask
        if ($t) {
            if ($Mode -eq 'Remove') { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
            else { Disable-ScheduledTask -TaskName $taskName | Out-Null }
        }
        if (Test-Path -LiteralPath $data) {
            Assert-Protected $data
            $pending = Join-Path $data 'cleanup-request.json'
            if (Test-Path -LiteralPath $pending) { Assert-Protected $pending; Remove-Item -LiteralPath $pending -Force }
            @{state=$(if($Mode -eq 'Pause'){'Paused'}else{'Removed'});updatedAt=(Get-Date).ToString('o');detail='Automatic management stopped; ACE itself and its boot settings were not changed.';monitorPid=0} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $data 'status.json') -Encoding UTF8
        }
        @{ok=$true;message='自动管理已停止。ACE 本体未卸载，安装文件和日志保留。'} | ConvertTo-Json -Compress
        exit 0
    }
    $c = Read-Request
    $sourceMonitor = Join-Path $PSScriptRoot 'Monitor-Ace.ps1'
    Protect-Directory $root
    Protect-Directory $data
    foreach ($file in @('Monitor-Ace.ps1','config.json')) {
        $target = Join-Path $root $file
        if (Test-Path -LiteralPath $target) { Assert-Protected $target }
    }
    # 完成只读预检后才替换正在使用的代码。
    $c | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Encoding UTF8
    $preflight = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $sourceMonitor -CheckOnly
    if ($LASTEXITCODE -ne 0) { throw '服务控制预检失败，原任务未更改。' }
    $oldTask = Read-OwnedTask
    $oldXml = if ($oldTask) { Export-ScheduledTask -TaskName $taskName } else { $null }
    $backup = @{}
    foreach ($file in @('Monitor-Ace.ps1','config.json')) {
        $target = Join-Path $root $file
        if (Test-Path -LiteralPath $target) { $backup[$file] = [IO.File]::ReadAllBytes($target) }
    }
    $wasRunning = $oldTask -and $oldTask.State -eq 'Running'
    $null = Stop-OwnedTask
    try {
        $pending = Join-Path $data 'cleanup-request.json'
        if (Test-Path -LiteralPath $pending) { Assert-Protected $pending; Remove-Item -LiteralPath $pending -Force }
        Copy-Item -LiteralPath $sourceMonitor -Destination (Join-Path $root 'Monitor-Ace.ps1') -Force
        $c | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding UTF8
        $action = New-ScheduledTaskAction -Execute $psExe -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $root 'Monitor-Ace.ps1')) -WorkingDirectory $root
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $c.userSid
        $identity = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $identity -Settings $settings -Description 'ACE Auto Manager: safely close ACE after a no-game grace period at login and after supported games exit.' -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 4
        if ((Get-ScheduledTask -TaskName $taskName).State -ne 'Running') { throw '后台任务未能持续运行。' }
    } catch {
        $failure = $_
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        foreach ($file in @('Monitor-Ace.ps1','config.json')) {
            if ($backup.ContainsKey($file)) { [IO.File]::WriteAllBytes((Join-Path $root $file),$backup[$file]) }
        }
        if ($oldXml) { Register-ScheduledTask -TaskName $taskName -Xml $oldXml -Force | Out-Null; if ($wasRunning) { Start-ScheduledTask -TaskName $taskName } }
        else { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
        throw $failure
    }
    @{ok=$true;message='自动管理已开启。关闭此窗口后，后台仍会继续工作。'} | ConvertTo-Json -Compress
} catch {
    @{ok=$false;message=$_.Exception.Message} | ConvertTo-Json -Compress
    exit 1
}
