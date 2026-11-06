<#
.SYNOPSIS
    让笔记本在「屏幕熄灭 / 合上盖子」时继续在后台运行（不进入睡眠）。
.DESCRIPTION
    只调整当前电源方案的三处设置：
      1) 合上盖子操作   -> 不采取任何操作（交流电 + 电池）
      2) 在此时间后睡眠 -> 从不（交流电固定；电池由 -BatterySleepMinutes 控制）
      3) 取消「合上盖子操作」的隐藏属性，便于之后在图形界面里核对
    -Apply 会先把原值备份成 JSON，-Revert 按备份还原。
    通常不需要管理员：标准用户一般可以写自己当前电源方案的设置。
.PARAMETER BatterySleepMinutes
    电池供电下的睡眠超时（分钟）。默认 0 = 从不睡眠；填 15 即保留「电池下 15 分钟睡眠」。
.PARAMETER BackupPath
    备份 JSON 路径，默认脚本同目录下的 keep-awake-backup.json。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\keep-awake.ps1 -Verify
    只检查，不改任何东西；不符合预期时退出码为 1。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\keep-awake.ps1 -Apply
    插电和电池都不睡眠，合盖不动作。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\keep-awake.ps1 -Apply -BatterySleepMinutes 15
    插电不睡眠，电池下 15 分钟仍然睡眠（合盖依旧不动作）。
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\keep-awake.ps1 -Revert
    按最近一次 -Apply 的备份还原。
#>
[CmdletBinding(DefaultParameterSetName = 'Apply')]
param(
    [Parameter(ParameterSetName = 'Apply')][switch]$Apply,
    [Parameter(ParameterSetName = 'Revert', Mandatory = $true)][switch]$Revert,
    [Parameter(ParameterSetName = 'Verify', Mandatory = $true)][switch]$Verify,
    [Parameter(ParameterSetName = 'Apply')][ValidateRange(0, 1440)][int]$BatterySleepMinutes = 0,
    [string]$BackupPath = (Join-Path $PSScriptRoot 'keep-awake-backup.json')
)

$ErrorActionPreference = 'Stop'

# 标准电源设置的 GUID（Windows Vista 至今未变）
$SUB_BUTTONS = '4f971e89-eebd-4455-a8de-9e59040e7347'   # 电源按钮和盖子
$SUB_SLEEP   = '238c9fa8-0aad-41ed-83f4-97be242c8f20'   # 睡眠
$SUB_VIDEO   = '7516b95f-f776-4464-8c53-06167f40cc99'   # 显示
$LIDACTION   = '5ca83367-6e45-459f-a27b-476b1d01c936'   # 合上盖子操作
$STANDBYIDLE = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'   # 在此时间后睡眠
$VIDEOIDLE   = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'   # 在此时间后关闭显示

$SCHEMES  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
$LID_ATTR = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$SUB_BUTTONS\$LIDACTION"

function Get-ActiveSchemeGuid {
    $text = (& powercfg /getactivescheme) -join "`n"
    if ($text -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
        return $Matches[1].ToLower()
    }
    throw '无法解析当前电源方案 GUID'
}

function Get-Index {
    param([string]$Sub, [string]$Setting)
    $path = "$SCHEMES\$(Get-ActiveSchemeGuid)\$Sub\$Setting"
    if (-not (Test-Path $path)) { return @{ AC = $null; DC = $null } }
    $item = Get-ItemProperty -Path $path
    @{
        AC = $(if ($item.PSObject.Properties['ACSettingIndex']) { $item.ACSettingIndex })
        DC = $(if ($item.PSObject.Properties['DCSettingIndex']) { $item.DCSettingIndex })
    }
}

function Set-Index {
    param([string]$Sub, [string]$Setting, [string]$Bus, [int]$Value)
    $verb = if ($Bus -eq 'AC') { '/setacvalueindex' } else { '/setdcvalueindex' }
    $null = & powercfg $verb SCHEME_CURRENT $Sub $Setting $Value
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg $verb 失败（退出码 $LASTEXITCODE）：可能被组策略或权限限制"
    }
}

function Remove-Index {
    param([string]$Sub, [string]$Setting, [string]$Bus)
    $path = "$SCHEMES\$(Get-ActiveSchemeGuid)\$Sub\$Setting"
    $name = if ($Bus -eq 'AC') { 'ACSettingIndex' } else { 'DCSettingIndex' }
    if (Test-Path $path) {
        Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue
    }
}

function Format-Lid {
    param([object]$Value)
    if ($null -eq $Value) { return '默认（未显式设置）' }
    switch ([int]$Value) {
        0 { '不采取任何操作' }
        1 { '睡眠' }
        2 { '休眠' }
        3 { '关机' }
        default { "未知索引 $Value" }
    }
}

function Format-Seconds {
    param([object]$Value)
    if ($null -eq $Value) { return '默认（未显式设置）' }
    $n = [int64]$Value
    if ($n -eq 0 -or $n -ge 2147483647) { return '从不' }
    return ('{0} 分钟' -f [int]($n / 60))
}

function Write-Facts {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Host ("系统      : {0} {1} build {2}" -f $os.Caption, $os.Version, $os.BuildNumber)

    $chassis = @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes | ForEach-Object { [int]$_ })
    $isLaptop = @($chassis | Where-Object { $_ -in 8, 9, 10, 14 }).Count -gt 0
    $tag = if ($isLaptop) { '(笔记本)' } else { '(机箱类型不像笔记本，合盖设置可能无效)' }
    Write-Host ("机箱类型  : {0} {1}" -f ($chassis -join ','), $tag)

    $avail = (& powercfg /a) -join ' '
    $model = if ($avail -match 'S0') { '现代待机 (S0 低电量待机)' }
             elseif ($avail -match 'S3') { '传统待机 (S3)' }
             else { '见 powercfg /a 输出' }
    Write-Host "睡眠模型  : $model"
    Write-Host ("当前方案  : {0}" -f ((& powercfg /getactivescheme) -join ''))
}

function Write-State {
    $lid   = Get-Index $SUB_BUTTONS $LIDACTION
    $sleep = Get-Index $SUB_SLEEP   $STANDBYIDLE
    $video = Get-Index $SUB_VIDEO   $VIDEOIDLE
    Write-Host ''
    Write-Host ('{0,-24}{1,-24}{2}' -f '项目', '交流电（插电）', '电池')
    Write-Host ('{0,-24}{1,-24}{2}' -f '合上盖子时', (Format-Lid $lid.AC), (Format-Lid $lid.DC))
    Write-Host ('{0,-24}{1,-24}{2}' -f '在此时间后睡眠', (Format-Seconds $sleep.AC), (Format-Seconds $sleep.DC))
    Write-Host ('{0,-24}{1,-24}{2}' -f '在此时间后关闭显示', (Format-Seconds $video.AC), (Format-Seconds $video.DC))
}

function Invoke-Apply {
    $scheme = Get-ActiveSchemeGuid
    $lid    = Get-Index $SUB_BUTTONS $LIDACTION
    $sleep  = Get-Index $SUB_SLEEP   $STANDBYIDLE

    $attr = $null
    if (Test-Path $LID_ATTR) {
        $entry = Get-ItemProperty -Path $LID_ATTR -Name Attributes -ErrorAction SilentlyContinue
        if ($null -ne $entry) { $attr = $entry.Attributes }
    }

    $backup = [ordered]@{
        createdAt     = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        computer      = $env:COMPUTERNAME
        schemeGuid    = $scheme
        lidAction     = [ordered]@{ AC = $lid.AC; DC = $lid.DC }
        standbyIdle   = [ordered]@{ AC = $sleep.AC; DC = $sleep.DC }
        lidAttributes = $attr
    }
    ($backup | ConvertTo-Json -Depth 5) | Set-Content -Path $BackupPath -Encoding UTF8
    Write-Host "原值已备份 -> $BackupPath"

    Set-Index $SUB_BUTTONS $LIDACTION   'AC' 0
    Set-Index $SUB_BUTTONS $LIDACTION   'DC' 0
    Set-Index $SUB_SLEEP   $STANDBYIDLE 'AC' 0
    Set-Index $SUB_SLEEP   $STANDBYIDLE 'DC' ([int]$BatterySleepMinutes * 60)

    $null = & powercfg /attributes $SUB_BUTTONS $LIDACTION -ATTRIB_HIDE
    if ($LASTEXITCODE -ne 0) {
        Write-Warning '取消隐藏「合上盖子操作」失败（可能需要管理员），不影响设置本身。'
    }
    $null = & powercfg /setactive SCHEME_CURRENT
    Write-Host '设置已写入当前电源方案。'
}

function Invoke-Revert {
    if (-not (Test-Path $BackupPath)) {
        throw "找不到备份文件: $BackupPath；只能手工还原（见方案文档的回滚一节）"
    }
    $b = Get-Content -Path $BackupPath -Raw | ConvertFrom-Json
    if ($b.schemeGuid -and (Get-ActiveSchemeGuid) -ne ([string]$b.schemeGuid).ToLower()) {
        Write-Warning '当前电源方案与备份时不同，将把备份值写入当前方案。'
    }

    foreach ($bus in 'AC', 'DC') {
        $v = $b.lidAction.$bus
        if ($null -ne $v) { Set-Index $SUB_BUTTONS $LIDACTION $bus ([int]$v) }
        else { Remove-Index $SUB_BUTTONS $LIDACTION $bus }
    }
    foreach ($bus in 'AC', 'DC') {
        $v = $b.standbyIdle.$bus
        if ($null -ne $v) { Set-Index $SUB_SLEEP $STANDBYIDLE $bus ([int]$v) }
        else { Remove-Index $SUB_SLEEP $STANDBYIDLE $bus }
    }
    if ($null -ne $b.lidAttributes) {
        if ([int]$b.lidAttributes -eq 0) { $null = & powercfg /attributes $SUB_BUTTONS $LIDACTION -ATTRIB_HIDE }
        else { $null = & powercfg /attributes $SUB_BUTTONS $LIDACTION +ATTRIB_HIDE }
    }
    $null = & powercfg /setactive SCHEME_CURRENT
    Write-Host '已按备份还原。'
}

function Test-DesiredState {
    $lid   = Get-Index $SUB_BUTTONS $LIDACTION
    $sleep = Get-Index $SUB_SLEEP   $STANDBYIDLE
    $ok = $true
    if ($null -eq $lid.AC -or [int]$lid.AC -ne 0) { $ok = $false }
    if ($null -eq $lid.DC -or [int]$lid.DC -ne 0) { $ok = $false }
    if ($null -eq $sleep.AC -or [int]$sleep.AC -ne 0) { $ok = $false }
    $ok
}

Write-Facts
switch ($PSCmdlet.ParameterSetName) {
    'Apply'  { Invoke-Apply }
    'Revert' { Invoke-Revert; Write-State; exit 0 }
}
Write-State

if (Test-DesiredState) {
    Write-Host ''
    Write-Host '结果：合盖不睡眠、插电不睡眠，符合预期。'
    exit 0
}
Write-Host ''
Write-Warning '结果不符合预期：合盖动作或睡眠超时未生效，请检查组策略、厂商电源工具或电源计划切换。'
exit 1
