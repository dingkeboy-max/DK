<#
.SYNOPSIS
    NetToggle - 一键断网 / 一键联网 Windows GUI 工具
.DESCRIPTION
    纯 PowerShell + WinForms 实现，无需编译。需要管理员权限（会自动 UAC 提权）。
    功能：枚举网络适配器、一键断网/联网、在线探测、自动守护（掉线自动重连）、系统托盘、操作日志。
#>

# ---------- 0. 自提权 (UAC) ----------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    $psi.Verb = 'runas'
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch { exit 1 }
    exit
}

# ---------- 0.5 全局异常兜底：记录日志 + 弹窗提示，而不是默默闪退 ----------
trap {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts][FATAL] $($_)`n$($_.InvocationInfo.PositionMessage)`n$($_.ScriptStackTrace)`n"
    try { $entry | Out-File (Join-Path $PSScriptRoot 'NetToggle_error.log') -Append -Encoding UTF8 } catch {}
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show("NetToggle 遇到错误并退出：`n`n$($_)`n`n(详细已保存到同目录 NetToggle_error.log)", "NetToggle 错误", 'OK', 'Error') | Out-Null
    } catch {}
    exit 1
}

# ---------- 1. 加载 WinForms 程序集 ----------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# 必须在创建任何控件之前调用，窗体才会使用系统视觉样式
[System.Windows.Forms.Application]::EnableVisualStyles() | Out-Null

# ---------- 2. 共享状态 ----------
$script:adapters = @()
$script:watchdogOn = $false
$script:closing = $false
$script:guardInterval = 5
$script:tickCount = 0
$script:probing = $false   # 是否正在后台探测
$script:busy = $false      # 是否正在后台执行断/联网
$script:bgJobs = @()       # 活动后台作业（独立 Runspace）
$script:lastOnline = $null # 外网可达性：null=未知, $true=可达, $false=不可达
$script:liveStates = @{}    # 后台实时探测得到的各网卡“是否启用”状态（名称→bool），状态灯优先用此值
$script:schedOffEnabled = $false   # 定时断网 是否启用
$script:schedOnEnabled  = $false   # 定时联网 是否启用
$script:schedOffLast = $null       # 定时断网上次触发的日期（同天不重复触发）
$script:schedOnLast  = $null       # 定时联网上次触发的日期（同天不重复触发）
$script:errLock = New-Object System.Object   # 异常日志文件写入锁

# ---------- 3. 核心函数 ----------
function Get-AdapterList {
    $list = @()
    try {
        # 主数据源：Get-NetAdapter。它的 Name 与 netsh 接口名 100% 一致，
        # 避免旧版用 WMI NetConnectionID 导致的“名字对不上 → 此网络连接不存在”问题。
        $adapters = @(Get-NetAdapter -ErrorAction Stop)
        foreach ($a in $adapters) {
            # Status: Up=已启用已连接, Disconnected=已启用未连接, Disabled=已禁用
            $disabled = ($a.Status -eq 'Disabled')
            $obj = [pscustomobject]@{
                Name       = $a.Name
                NetEnabled = (-not $disabled)   # 仅“已禁用”视为未启用（断网态）
                Status     = if ($disabled) { '已断开' } else { '已连接' }
            }
            $obj | Add-Member -MemberType ScriptProperty -Name Label -Value { "$($this.Name)   [$($this.Status)]" } -Force
            $list += $obj
        }
    } catch {
        # 回退：解析 netsh interface show interface（接口名含空格也能正确提取）
        try {
            $raw = & netsh interface show interface 2>$null
            foreach ($line in $raw) {
                if ($line -match '(已启用|已禁用)\s+(已连接|已断开连接|connected|disconnected)\s+\S+\s+(.+)$') {
                    $name = $Matches[3].Trim()
                    $disabled = ($line -match '已禁用|Disabled')
                    $obj = [pscustomobject]@{
                        Name       = $name
                        NetEnabled = (-not $disabled)
                        Status     = if ($disabled) { '已断开' } else { '已连接' }
                    }
                    $obj | Add-Member -MemberType ScriptProperty -Name Label -Value { "$($this.Name)   [$($this.Status)]" } -Force
                    $list += $obj
                }
            }
        } catch {
            Write-ExceptionLog -Source '枚举适配器' -ErrorObject $_
        }
    }
    return $list
}

# 网卡操作 / 在线探测已改为在“独立 PowerShell 运行空间”中执行（见下方“后台执行基础设施”），
# 主运行空间不再保留这两个会触发跨线程崩溃的函数。

# ---------- 3.5 后台执行基础设施 ----------
# 关键点：PowerShell 脚本块若在 .NET 后台线程（如 BackgroundWorker.DoWork、线程池 Timer 回调）
# 执行，会因缺少运行空间上下文而抛 GetContextFromTLS 异常并崩溃。
# 因此所有后台工作都放到【独立的 PowerShell 运行空间】中执行，完成后通过 $form.BeginInvoke
# 切回 UI 线程更新控件，彻底避免跨线程崩溃。

# 自包含探测脚本（在新 Runspace 中执行，不依赖主运行空间的函数/变量）
# 用 HTTP 204 检测外网可达性，比裸 TCP 53 更可靠（TCP 53 常被防火墙拦截而误报断网）
# 同时【实时查询选中网卡的启用状态】——这是修复“联网后一直显示已断开”的关键：
# 网卡从禁用切换为连接需要一两秒，若只看操作完成瞬间的旧快照就会一直误报红色。
$probeScript = {
    param([string]$AdapterName)
    $urls = @(
        'http://www.gstatic.com/generate_204',
        'http://connectivitycheck.gstatic.com/generate_204',
        'http://www.msftconnecttest.com/connecttest.txt'
    )
    $online = $false
    foreach ($u in $urls) {
        try {
            $req = [System.Net.WebRequest]::Create($u)
            $req.Timeout = 3000
            $req.Method = 'GET'
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $resp.Close()
            if ($code -ge 200 -and $code -lt 400) { $online = $true; break }
        } catch {}
    }
    # 实时查网卡真实启用状态（优先 Get-NetAdapter，带回退）
    $netEnabled = $null
    if ($AdapterName) {
        try {
            $a = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
            if ($a) { $netEnabled = ($a.Status -ne 'Disabled') }
        } catch {}
        if ($null -eq $netEnabled) {
            try {
                $raw = & netsh interface show interface 2>$null
                foreach ($line in $raw) {
                    if ($line -match '(已启用|已禁用)\s+(已连接|已断开连接|connected|disconnected)\s+\S+\s+(.+)$') {
                        if ($Matches[3].Trim() -eq $AdapterName) {
                            $netEnabled = ($line -notmatch '已禁用|Disabled')
                            break
                        }
                    }
                }
            } catch {}
        }
    }
    [PSCustomObject]@{ Online = $online; NetEnabled = $netEnabled }
}

# 自包含网卡操作脚本：用 .NET Process 显式以 UTF-8 解码 netsh 输出（避免中文乱码）。
# 本机 netsh 实际输出 UTF-8，而 Runspace 默认按系统代码页(GBK)解码导致乱码；
# 通过 StandardOutputEncoding=UTF8 直接拿到正确中文。返回 @{ Ok; Output }
$opScript = {
    param([string]$Name, [bool]$Enable)
    $admin = if ($Enable) { 'enable' } else { 'disable' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'netsh.exe'
    $psi.Arguments = "interface set interface `"$Name`" admin=$admin"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.CreateNoWindow = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        [PSCustomObject]@{ Ok = ($p.ExitCode -eq 0); Output = ($out + $err).Trim() }
    } catch {
        [PSCustomObject]@{ Ok = $false; Output = ("异常: " + $_.Exception.Message) }
    }
}

# 在新 Runspace 后台执行脚本，并把作业登记到 $script:bgJobs；由 UI 线程的轮询定时器回收结果并调用 $OnDone
# （不依赖 Register-ObjectEvent：其事件泵送在不同宿主下不可靠）
function Start-Background {
    param([scriptblock]$Script, [scriptblock]$OnDone, $ArgumentList = @())
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.AddScript($Script.ToString()) | Out-Null
    foreach ($a in $ArgumentList) { $ps.AddArgument($a) | Out-Null }
    $iasync = $ps.BeginInvoke()
    $job = [pscustomobject]@{ Ps = $ps; IAsync = $iasync; OnDone = $OnDone; Done = $false }
    $script:bgJobs += $job
}

function Write-Log {
    param([string]$msg)
    $line = "$(Get-Date -Format 'HH:mm:ss')  $msg"
    $box = $script:logBox
    if ($box -eq $null) { return }
    if ($box.InvokeRequired) {
        # 可能在后台线程调用（自动守护）；用无参 Action + 闭包，避免泛型委托在 PS 中崩溃
        $box.BeginInvoke([System.Action]{ $box.AppendText($line + [Environment]::NewLine) }) | Out-Null
    } else {
        $box.AppendText($line + [Environment]::NewLine)
    }
}

# 异常日志：写入 NetToggle_error.log（带时间戳+堆栈），并同步显示到界面日志框
function Write-ExceptionLog {
    param([string]$Source, [object]$ErrorObject)
    $ex    = if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) { $ErrorObject.Exception } else { $ErrorObject }
    $msg   = if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) { $ErrorObject.ToString() } else { "$ErrorObject" }
    $stack = if ($ex -and $ex.StackTrace) { $ex.StackTrace } else { '(无堆栈)' }
    $ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$ts][$Source]`n  $msg`n  $stack`n"
    try {
        $path = Join-Path $PSScriptRoot 'NetToggle_error.log'
        [System.Threading.Monitor]::Enter($script:errLock)
        try { [System.IO.File]::AppendAllText($path, $entry, [System.Text.Encoding]::UTF8) } `
        finally { [System.Threading.Monitor]::Exit($script:errLock) }
    } catch {}
    Write-Log "[异常][$Source] $msg"
}

# ---------- 4. 构建 UI ----------
$form = New-Object System.Windows.Forms.Form
$form.Icon = [System.Drawing.SystemIcons]::Application
$form.Text = 'NetToggle - 一键断网 / 联网'
$form.Size = New-Object System.Drawing.Size(560, 560)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(480, 500)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

# 状态条
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(16, 14)
$statusLabel.Size = New-Object System.Drawing.Size(360, 22)
$statusLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei', 11, [System.Drawing.FontStyle]::Bold)
$statusLabel.Text = '当前网络：检测中…'
$form.Controls.Add($statusLabel)

$dot = New-Object System.Windows.Forms.PictureBox
$dot.Location = New-Object System.Drawing.Point(390, 16)
$dot.Size = New-Object System.Drawing.Size(16, 16)
$dot.BackColor = [System.Drawing.Color]::Gray
$form.Controls.Add($dot)

# 适配器列表
$lbLabel = New-Object System.Windows.Forms.Label
$lbLabel.Location = New-Object System.Drawing.Point(16, 48)
$lbLabel.Size = New-Object System.Drawing.Size(200, 18)
$lbLabel.Text = '网络适配器（点选要操作的）'
$form.Controls.Add($lbLabel)

$listBox = New-Object System.Windows.Forms.ListBox
$listBox.Location = New-Object System.Drawing.Point(16, 70)
$listBox.Size = New-Object System.Drawing.Size(300, 150)
$listBox.DisplayMember = 'Label'
$listBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($listBox)

# 按钮
$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Location = New-Object System.Drawing.Point(330, 70)
$btnRefresh.Size = New-Object System.Drawing.Size(190, 34)
$btnRefresh.Text = '刷新列表'
$form.Controls.Add($btnRefresh)

$btnDisable = New-Object System.Windows.Forms.Button
$btnDisable.Location = New-Object System.Drawing.Point(330, 112)
$btnDisable.Size = New-Object System.Drawing.Size(190, 38)
$btnDisable.Text = '⛔ 一键断网'
$btnDisable.BackColor = [System.Drawing.Color]::FromArgb(255, 235, 235)
$form.Controls.Add($btnDisable)

$btnEnable = New-Object System.Windows.Forms.Button
$btnEnable.Location = New-Object System.Drawing.Point(330, 158)
$btnEnable.Size = New-Object System.Drawing.Size(190, 38)
$btnEnable.Text = '✅ 一键联网'
$btnEnable.BackColor = [System.Drawing.Color]::FromArgb(225, 245, 230)
$form.Controls.Add($btnEnable)

# 自动守护
$chkWatch = New-Object System.Windows.Forms.CheckBox
$chkWatch.Location = New-Object System.Drawing.Point(330, 206)
$chkWatch.Size = New-Object System.Drawing.Size(190, 22)
$chkWatch.Text = '自动守护（掉线自动重连）'
$form.Controls.Add($chkWatch)

$lblInterval = New-Object System.Windows.Forms.Label
$lblInterval.Location = New-Object System.Drawing.Point(330, 234)
$lblInterval.Size = New-Object System.Drawing.Size(120, 18)
$lblInterval.Text = '检测间隔(秒)：'
$form.Controls.Add($lblInterval)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Location = New-Object System.Drawing.Point(456, 232)
$numInterval.Size = New-Object System.Drawing.Size(64, 22)
$numInterval.Minimum = 2
$numInterval.Maximum = 60
$numInterval.Value = 2
$form.Controls.Add($numInterval)
$numInterval.Add_ValueChanged({ $script:guardInterval = [int]$numInterval.Value; if ($timer -ne $null) { $timer.Interval = [int]$numInterval.Value * 1000 } })

# ---------- 定时任务（断网/联网） ----------
$grpSched = New-Object System.Windows.Forms.GroupBox
$grpSched.Location = New-Object System.Drawing.Point(16, 230)
$grpSched.Size = New-Object System.Drawing.Size(300, 150)
$grpSched.Text = '定时任务（每天重复）'
$form.Controls.Add($grpSched)

$chkSchedOff = New-Object System.Windows.Forms.CheckBox
$chkSchedOff.Location = New-Object System.Drawing.Point(14, 26)
$chkSchedOff.Size = New-Object System.Drawing.Size(110, 22)
$chkSchedOff.Text = '定时断网'
$grpSched.Controls.Add($chkSchedOff)

$dtpOff = New-Object System.Windows.Forms.DateTimePicker
$dtpOff.Location = New-Object System.Drawing.Point(130, 24)
$dtpOff.Size = New-Object System.Drawing.Size(95, 22)
$dtpOff.Format = 'Time'
$dtpOff.ShowUpDown = $true
$dtpOff.Value = [datetime]::Today.AddHours(23)   # 默认 23:00 断网
$grpSched.Controls.Add($dtpOff)

$chkSchedOn = New-Object System.Windows.Forms.CheckBox
$chkSchedOn.Location = New-Object System.Drawing.Point(14, 58)
$chkSchedOn.Size = New-Object System.Drawing.Size(110, 22)
$chkSchedOn.Text = '定时联网'
$grpSched.Controls.Add($chkSchedOn)

$dtpOn = New-Object System.Windows.Forms.DateTimePicker
$dtpOn.Location = New-Object System.Drawing.Point(130, 56)
$dtpOn.Size = New-Object System.Drawing.Size(95, 22)
$dtpOn.Format = 'Time'
$dtpOn.ShowUpDown = $true
$dtpOn.Value = [datetime]::Today.AddHours(7)    # 默认 07:00 联网
$grpSched.Controls.Add($dtpOn)

$lblSchedNote = New-Object System.Windows.Forms.Label
$lblSchedNote.Location = New-Object System.Drawing.Point(14, 92)
$lblSchedNote.Size = New-Object System.Drawing.Size(272, 46)
$lblSchedNote.Text = '到点对“当前选中的网卡”自动执行；软件需保持运行（可最小化到托盘）。'
$lblSchedNote.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
$grpSched.Controls.Add($lblSchedNote)

# 日志
$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Location = New-Object System.Drawing.Point(16, 398)
$logLabel.Size = New-Object System.Drawing.Size(200, 18)
$logLabel.Text = '操作日志'
$form.Controls.Add($logLabel)

$script:logBox = New-Object System.Windows.Forms.TextBox
$script:logBox.Location = New-Object System.Drawing.Point(16, 420)
$script:logBox.Size = New-Object System.Drawing.Size(508, 100)
$script:logBox.Multiline = $true
$script:logBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:logBox.ReadOnly = $true
$script:logBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$form.Controls.Add($script:logBox)

# 托盘图标
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Application
$notify.Text = 'NetToggle'
$notify.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemShow = $menu.Items.Add('显示窗口')
$itemOff  = $menu.Items.Add('一键断网')
$itemOn   = $menu.Items.Add('一键联网')
$itemExit = $menu.Items.Add('退出')
$notify.ContextMenuStrip = $menu

# ---------- 5. 事件 ----------
function Refresh-List {
    # 记住当前选中的网卡，刷新后尽量恢复，避免联网/断网后选中项被重置导致状态显示错位
    $prevName = $null
    if ($listBox.SelectedItem) { $prevName = $listBox.SelectedItem.Name }
    $script:adapters = Get-AdapterList
    $listBox.Items.Clear()
    foreach ($a in $script:adapters) { $listBox.Items.Add($a) | Out-Null }
    $idx = 0
    if ($prevName) {
        for ($i = 0; $i -lt $listBox.Items.Count; $i++) {
            if ($listBox.Items[$i].Name -eq $prevName) { $idx = $i; break }
        }
    }
    if ($listBox.Items.Count -gt 0) { $listBox.SelectedIndex = $idx }
    Write-Log "已刷新，共 $($listBox.Items.Count) 个适配器"
    Update-StatusFromAdapter
}

function Selected-Adapter {
    if ($listBox.SelectedItem -eq $null) { Write-Log "请先选择适配器"; return $null }
    return $listBox.SelectedItem
}

# 依据“选中适配器的连接状态”显示主状态（权威，与列表一致），外网可达性仅作补充提示。
# 状态灯优先采用后台实时探测得到的网卡启用状态（$liveStates），而非列表快照，
# 这样网卡从禁用切换到连接后能被自动纠正为绿色，不会再永远停在红色“已断开”。
function Update-StatusFromAdapter {
    $a = $listBox.SelectedItem
    if ($a -eq $null) {
        $statusLabel.Text = '当前网络：未选择适配器'
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
        $dot.BackColor = [System.Drawing.Color]::Gray
        return
    }
    # 优先用实时探测得到的启用状态；没有实时值（如刚刷新、尚未探测）时回退到列表快照
    $netEnabled = $a.NetEnabled
    if ($script:liveStates.ContainsKey($a.Name)) { $netEnabled = $script:liveStates[$a.Name] }
    if ($netEnabled) {
        if ($script:lastOnline -eq $false) {
            $statusLabel.Text = '当前网络：已连接（无外网）'
            $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(200, 140, 0)
            $dot.BackColor = [System.Drawing.Color]::FromArgb(240, 180, 0)
        } else {
            $statusLabel.Text = '当前网络：● 已连接'
            $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(20, 120, 40)
            $dot.BackColor = [System.Drawing.Color]::FromArgb(40, 180, 70)
        }
    } else {
        $statusLabel.Text = '当前网络：○ 已断开'
        $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(190, 40, 40)
        $dot.BackColor = [System.Drawing.Color]::FromArgb(220, 60, 60)
    }
}

# 定时任务检查：由独立定时器（每 15 秒）调用。到达当天目标时间的那一分钟内，
# 对“当前选中的网卡”自动断/联网，同一天只触发一次，避免重复执行。
function Check-Schedule {
    $now = Get-Date
    $today = $now.Date
    if ($script:schedOffEnabled) {
        $target = $today.Add($dtpOff.Value.TimeOfDay)
        if ($now -ge $target -and $now -lt $target.AddMinutes(1)) {
            if ($null -eq $script:schedOffLast -or $script:schedOffLast -ne $today) {
                $script:schedOffLast = $today
                Write-Log "定时任务：到达断网时间 $($target.ToString('HH:mm'))，执行断网"
                Invoke-Toggle -Enable $false
            }
        }
    }
    if ($script:schedOnEnabled) {
        $target = $today.Add($dtpOn.Value.TimeOfDay)
        if ($now -ge $target -and $now -lt $target.AddMinutes(1)) {
            if ($null -eq $script:schedOnLast -or $script:schedOnLast -ne $today) {
                $script:schedOnLast = $today
                Write-Log "定时任务：到达联网时间 $($target.ToString('HH:mm'))，执行联网"
                Invoke-Toggle -Enable $true
            }
        }
    }
}

$btnRefresh.Add_Click({ Refresh-List })

$btnDisable.Add_Click({ Invoke-Toggle -Enable $false })
$btnEnable.Add_Click({ Invoke-Toggle -Enable $true })

$chkWatch.Add_CheckedChanged({
    $script:watchdogOn = $chkWatch.Checked
    if ($script:watchdogOn) { Write-Log "自动守护已开启（每 $($numInterval.Value) 秒检测）" } else { Write-Log "自动守护已关闭" }
})

$chkSchedOff.Add_CheckedChanged({
    $script:schedOffEnabled = $chkSchedOff.Checked
    if ($chkSchedOff.Checked) { Write-Log "已启用定时断网：$($dtpOff.Value.ToString('HH:mm'))" } else { Write-Log "已关闭定时断网" }
})
$chkSchedOn.Add_CheckedChanged({
    $script:schedOnEnabled = $chkSchedOn.Checked
    if ($chkSchedOn.Checked) { Write-Log "已启用定时联网：$($dtpOn.Value.ToString('HH:mm'))" } else { Write-Log "已关闭定时联网" }
})

$itemShow.Add_Click({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
$itemOff.Add_Click({ Invoke-Toggle -Enable $false })
$itemOn.Add_Click({ Invoke-Toggle -Enable $true })
$itemExit.Add_Click({ $form.Close() })

$form.Add_Resize({
    if ($form.WindowState -eq 'Minimized') { $form.Hide() }
})

$notify.Add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

# UI 定时器（WinForms Timer，Tick 在 UI 线程执行）：每 interval 秒发起一次后台探测
# 探测本身在独立 Runspace 后台执行，UI 线程仅负责发起，绝不阻塞
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [int]$numInterval.Value * 1000
$timer.Add_Tick({
    if ($script:probing) { return }
    $script:probing = $true
    # 把当前选中网卡名作为实参传入（按值传递，避免闭包捕获导致的取值错位）
    $sel = $listBox.SelectedItem
    $nm = if ($sel) { $sel.Name } else { '' }
    Start-Background -Script $probeScript -ArgumentList @($nm) -OnDone {
        param($r)
        $script:probing = $false
        $online = $false
        $netEnabled = $null
        if ($r -ne $null) {
            if ($null -ne $r.Online) { $online = [bool]$r.Online }
            if ($null -ne $r.NetEnabled) { $netEnabled = [bool]$r.NetEnabled }
        }
        $script:lastOnline = $online
        # 把实时网卡启用状态按“当前选中的网卡名”写入缓存，供状态灯优先采用
        if ($null -ne $netEnabled) {
            $cur = $listBox.SelectedItem
            if ($cur) { $script:liveStates[$cur.Name] = $netEnabled }
        }
        Update-StatusFromAdapter
        # 自动守护：仅当“网卡本身已启用、但探测不到外网”时才重连；
        # 用户主动断网（网卡已禁用）不触发，避免刚断又被自动连上。
        if ($script:watchdogOn) {
            $a = $listBox.SelectedItem
            if ($a -ne $null -and $a.NetEnabled -and -not $online) {
                Write-Log "自动守护：检测到离线，重连 [$($a.Name)]"
                Invoke-Toggle -Enable $true
            }
        }
    }
})

# 一键断网/联网：在独立 Runspace 后台执行 netsh，避免阻塞 UI 线程
# 重要：后台回调（OnDone）是在轮询定时器作用域经 & 调用的，取不到本函数的闭包局部变量
#（$a/$Enable 会变成 $null），因此把网卡名与“联网/断网”意图存入【脚本作用域】，
# 回调里只读取脚本作用域变量，避免“状态文字误判成已断网 / Remove 空键抛异常”。
$script:toggleName = $null
$script:toggleEnable = $false
function Invoke-Toggle {
    param([bool]$Enable)
    $a = Selected-Adapter
    if ($a -eq $null) { return }
    if ($script:busy) { Write-Log "上一次操作仍在进行，请稍候"; return }
    $script:busy = $true
    $script:toggleName = $a.Name
    $script:toggleEnable = $Enable
    $btnDisable.Enabled = $false
    $btnEnable.Enabled = $false
    $statusLabel.Text = if ($Enable) { '当前网络：正在联网…' } else { '当前网络：正在断网…' }
    Start-Background -Script $opScript -ArgumentList @($a.Name, $Enable) -OnDone {
        param($r)
        $script:busy = $false
        $btnDisable.Enabled = $true
        $btnEnable.Enabled = $true
        if ($r -and $r.Ok) {
            Write-Log "操作成功：$($script:toggleName) $(if ($script:toggleEnable) { '已联网' } else { '已断网' })"
        } else {
            $statusLabel.Text = '当前网络：操作失败，请查看日志'
            $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(190, 40, 40)
            if ($r -and $r.Output) { Write-Log "netsh 返回：$($r.Output)" }
        }
        # 清掉该网卡旧的实时状态，强制先用刚抓的新鲜快照；随后后台探测会逐步校正为真实状态
        if ($script:toggleName) { $script:liveStates.Remove($script:toggleName) }
        Refresh-List
    }
}

# 轮询后台作业：在 UI 线程检查独立 Runspace 是否完成，完成后调用 OnDone 更新控件
# 采用轮询而非 Register-ObjectEvent，避免依赖事件子系统泵送，最稳妥（OnDone 在 UI 线程执行，可直接访问控件）
$timerPoll = New-Object System.Windows.Forms.Timer
$timerPoll.Interval = 200
$timerPoll.Add_Tick({
    foreach ($job in $script:bgJobs) {
        if (-not $job.Done -and $job.IAsync.IsCompleted) {
            $job.Done = $true
            $res = $null
            try { $res = $job.Ps.EndInvoke($job.IAsync) } catch { $res = $null }
            # EndInvoke 返回的是 PSDataCollection[PSObject]（脚本输出流打包），并非 return 的标量；
            # 不解包会导致所有后台回调误判（如探测被当 $false、操作结果 $r.Ok 读不到）。解包为单一结果对象。
            # 用类型全名字符串比较，避免对开放泛型类型标记做 -is 触发的 ContainsGenericParameters 异常。
            if ($res -ne $null -and $res.GetType().FullName.StartsWith('System.Management.Automation.PSDataCollection')) {
                $res = if ($res.Count -gt 0) { $res[0] } else { $null }
            }
            try { $job.Ps.Dispose() } catch {}
            try { & $job.OnDone $res } catch { Write-ExceptionLog -Source '后台回调' -ErrorObject $_ }
        }
    }
    $script:bgJobs = @($script:bgJobs | Where-Object { -not $_.Done })
})
$timerPoll.Start()

# 定时任务定时器：每 15 秒检查一次是否到达设定的断/联网时间（轻量，不做网络探测）
$timerSched = New-Object System.Windows.Forms.Timer
$timerSched.Interval = 15000
$timerSched.Add_Tick({ Check-Schedule })
$timerSched.Start()

$form.Add_FormClosing({
    $script:closing = $true
    if ($timer -ne $null) { $timer.Stop() }
    if ($timerPoll -ne $null) { $timerPoll.Stop() }
    if ($timerSched -ne $null) { $timerSched.Stop() }
    $notify.Visible = $false
})

# ---------- 6. 启动 ----------
Refresh-List
$timer.Start()
Write-Log "NetToggle 已启动（管理员模式）"
[System.Windows.Forms.Application]::Run($form)

