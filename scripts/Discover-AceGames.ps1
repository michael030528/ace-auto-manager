# 从安装记录和游戏平台目录寻找 ACE 组件，不遍历整个磁盘，不执行候选文件。
function Find-AceGames {
    param([string[]]$ExtraRoots=@(), [switch]$OnlyExtraRoots)
    $roots=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($r in $ExtraRoots){if($r -and (Test-Path -LiteralPath $r -PathType Container)){$null=$roots.Add([IO.Path]::GetFullPath($r).TrimEnd('\'))}}
    if(-not $OnlyExtraRoots){
        foreach($key in @('HKCU:\Software\Tencent\valorant.live','HKCU:\Software\Tencent\LOL','HKLM:\Software\Tencent\LOL','HKLM:\Software\WOW6432Node\Tencent\LOL')){
            $v=Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            foreach($name in @('InstallLocation','InstallPath','InstallDir')){if($v -and $v.$name -and (Test-Path -LiteralPath $v.$name -PathType Container)){$null=$roots.Add(([string]$v.$name).TrimEnd('\'))}}
        }
        foreach($pattern in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')){
            foreach($app in @(Get-ItemProperty $pattern -ErrorAction SilentlyContinue)){
                $p=[string]$app.InstallLocation
                if($p -and (Test-Path -LiteralPath $p -PathType Container) -and $p.TrimEnd('\') -ne [IO.Path]::GetPathRoot($p).TrimEnd('\')){$null=$roots.Add($p.TrimEnd('\'))}
            }
        }
        $libraries=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($key in @('HKCU:\Software\Valve\Steam','HKLM:\Software\WOW6432Node\Valve\Steam')){
            $v=Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            if($v){foreach($p in @($v.SteamPath,$v.InstallPath)){if($p){$null=$libraries.Add([string]$p)}}}
        }
        foreach($drive in [IO.DriveInfo]::GetDrives()){
            if($drive.DriveType -ne 'Fixed'){continue}
            foreach($relative in @('SteamLibrary','Steam')){$null=$libraries.Add((Join-Path $drive.Name $relative))}
            foreach($relative in @('WeGameApps','WeGameApps\rail_apps')){
                $base=Join-Path $drive.Name $relative
                if(Test-Path -LiteralPath $base){foreach($dir in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)){
                    if($dir.Name -notin @('rail_apps','rail_user_data','common_apps','downloading')){$null=$roots.Add($dir.FullName)}
                }}
            }
        }
        foreach($lib in @($libraries)){
            $vdf=Join-Path $lib 'steamapps\libraryfolders.vdf'
            if(Test-Path -LiteralPath $vdf){foreach($m in [regex]::Matches([IO.File]::ReadAllText($vdf),'"path"\s+"([^"]+)"')){$null=$libraries.Add($m.Groups[1].Value.Replace('\\','\'))}}
        }
        foreach($lib in $libraries){$common=Join-Path $lib 'steamapps\common';if(Test-Path -LiteralPath $common){foreach($dir in @(Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue)){$null=$roots.Add($dir.FullName)}}}
    }
    $sessions=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $blockers=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $gameRoots=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $evidence=[Collections.Generic.List[object]]::new()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $skipped=0
    foreach($root in $roots){
        if([IO.Path]::GetFileName($root) -eq 'AntiCheatExpert'){continue}
        $queue=[Collections.Generic.Queue[object]]::new();$queue.Enqueue(@{path=$root;depth=0});$visited=0
        while($queue.Count -gt 0 -and $visited -lt 400){
            $node=$queue.Dequeue();$visited++
            if(-not $seen.Add($node.path)){continue}
            $item=Get-Item -LiteralPath $node.path -ErrorAction SilentlyContinue
            if(-not $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
            if($item.Name -eq 'AntiCheatExpert'){
                $marker=@('ACE-Setup64.exe','ACE-Service64.exe','ACE-Helper.exe','SGuard\x64\SGuardSvc64.exe') | Where-Object {Test-Path -LiteralPath (Join-Path $item.FullName $_) -PathType Leaf} | Select-Object -First 1
                if(-not $marker){continue}
                $parent=$item.Parent.FullName
                $candidates=@(Get-ChildItem -LiteralPath $parent -Filter '*.exe' -File -ErrorAction SilentlyContinue | Where-Object {$_.Name -notmatch '(?i)^(ACE[-_]|SGuard|QtWebEngineProcess|PlatformProcess|LeagueClientUx)|uninstall|crash|report|helper|setup|redist|update|patch'})
                foreach($relative in @('LeagueClient\LeagueClient.exe','Game\League of Legends.exe','live\ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe','ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe','TFT\TFT\Binaries\Win64\TFTTencentClient-Win64-Shipping.exe')){
                    $p=Join-Path $root $relative;if(Test-Path -LiteralPath $p -PathType Leaf){$candidates+=Get-Item -LiteralPath $p}
                }
                if($candidates.Count -eq 0){$skipped++;continue}
                foreach($candidate in $candidates){$null=$sessions.Add($candidate.FullName)}
                $gameRoot=$root
                $container=[regex]::Match($parent,'(?i)^(.+\\(?:games|steamapps\\common|rail_apps)\\[^\\]+)')
                if($container.Success -and $container.Groups[1].Value.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) {$gameRoot=$container.Groups[1].Value}
                $null=$gameRoots.Add($gameRoot)
                $evidence.Add([pscustomobject]@{root=$gameRoot;component=(Join-Path $item.FullName $marker);executables=@($candidates.FullName)})
                continue
            }
            if($node.depth -ge 7){continue}
            foreach($child in @(Get-ChildItem -LiteralPath $node.path -Directory -ErrorAction SilentlyContinue)){
                if($child.Name -match '(?i)^(Content|Paks|Engine|Cache|Caches|Logs|node_modules|\.git|Python.*|Cross|assets|resources|locales)$'){continue}
                $queue.Enqueue(@{path=$child.FullName;depth=($node.depth+1)})
            }
        }
    }
    foreach($p in $sessions){$null=$blockers.Add($p)}
    [pscustomobject]@{sessionExecutables=@($sessions | Sort-Object);blockerExecutables=@($blockers | Sort-Object);gameDirectories=@($gameRoots | Sort-Object);evidence=@($evidence.ToArray());unresolved=$skipped;scannedRoots=$roots.Count}
}
