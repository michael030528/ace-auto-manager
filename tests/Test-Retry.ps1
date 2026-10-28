$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Monitor-Ace.ps1') -LibraryOnly
function Assert($condition,$message) { if(-not $condition){throw $message}; Write-Output ('PASS: '+$message) }
$p=Get-CleanupRetryPlan $true 1 100 45
Assert ($p.State -eq 'Idle' -and $p.Attempts -eq 0) 'Success cancels retries'
foreach($attempt in 1..3) {
    $p=Get-CleanupRetryPlan $false $attempt 100 45
    Assert ($p.State -eq 'Retrying' -and $p.Due -eq 160) ('Failure schedules bounded retry '+$attempt)
}
$p=Get-CleanupRetryPlan $false 4 100 45
Assert ($p.State -eq 'Idle') 'Initial attempt plus three retries exhausts the budget'
$p=Get-CleanupRetryPlan $false 1 100 180
Assert ($p.Due -eq 280) 'Long configured grace is respected'
$s=Get-CleanupStep Retrying 0 0 159 0 45 $false 160
Assert (-not $s.Close -and $s.State -eq 'Retrying') 'Retry does not run early'
$s=Get-CleanupStep Retrying 0 0 160 0 45 $false 160
Assert $s.Close 'Retry becomes eligible at deadline'
$s=Get-CleanupStep Retrying 1 1 160 0 45 $false 160
Assert (-not $s.Close -and $s.State -eq 'Active') 'Game cancels due retry'
$s=Get-CleanupStep Retrying 0 1 160 0 45 $true 160
Assert (-not $s.Close -and $s.State -eq 'Active') 'Client blocks even a manual retry'
$s=Get-CleanupStep Idle 0 0 1 0 45 $true 0
Assert $s.Close 'Manual cleanup bypasses grace only with no blockers'
$s=Get-CleanupStep Active 1 1 1 0 45 $true 0
Assert (-not $s.Close) 'Manual cleanup cannot bypass game guard'
$s=Get-CleanupStep Active 0 0 200 0 45 $false 0
Assert (-not $s.Close -and $s.QuietSince -eq 200) 'Game exit starts fresh grace after interrupted retry'
