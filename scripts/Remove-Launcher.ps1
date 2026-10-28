$ErrorActionPreference = 'Stop'
# 路径通过 Base64 数据传入，只删除启动卸载操作的那个 EXE。
$target = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('__TARGET_BASE64__'))
$expectedHash = '__EXPECTED_HASH__'
$receipt = Join-Path $env:ProgramData 'AceGameAutoClose\uninstall-result.json'
$removed = $false
$detail = ''
function Remove-VerifiedLauncher([string]$Path, [string]$Hash) {
    if (-not (Test-Path -LiteralPath $Path)) { return @{Removed=$true;Retry=$false;Detail=''} }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return @{Removed=$false;Retry=$false;Detail='Executable path became a link; deletion cancelled.'} }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash) {
        return @{Removed=$false;Retry=$false;Detail='Executable changed; deletion cancelled.'}
    }
    Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    return @{Removed=$true;Retry=$false;Detail=''}
}
for ($attempt=0; $attempt -lt 30; $attempt++) {
    Start-Sleep -Seconds 2
    try {
        $result=Remove-VerifiedLauncher $target $expectedHash
        $removed=$result.Removed; $detail=$result.Detail
        if (-not $result.Retry) { break }
    } catch { $detail=$_.Exception.Message }
}
@{removed=$removed;path=$target;detail=$detail;updatedAt=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $receipt -Encoding UTF8
if (-not $removed) {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show(('后台任务已卸载，但 EXE 未能自动删除，请手动删除：'+$target),'卸载结果') | Out-Null
}
