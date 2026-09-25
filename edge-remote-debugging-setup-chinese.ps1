# ============================================================
#  Edge Remote Debugging Configuration Script
# ============================================================
#  支持两种模式：
#    配置模式：一键配置 Edge 远程调试。
#    回退模式：撤销配置时做的所有改动。
#  启动时自动检测当前状态，但不限制用户选择。
# ============================================================

#Requires -Version 5.1

param(
    [int]$Port = 0
)

# ============================================================
#  让控制台窗口保持置顶
# ============================================================
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinTopMost {
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);

    public static readonly IntPtr HWND_TOPMOST   = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

    public const uint SWP_NOMOVE     = 0x0002;
    public const uint SWP_NOSIZE     = 0x0001;
    public const uint SWP_SHOWWINDOW = 0x0040;

    public static void SetTopMost(IntPtr hWnd) {
        SetWindowPos(hWnd, HWND_TOPMOST, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    }
    public static void UnsetTopMost(IntPtr hWnd) {
        SetWindowPos(hWnd, HWND_NOTOPMOST, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    }
}
"@

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinConsole {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
"@

$consoleHwnd = [WinConsole]::GetConsoleWindow()
if ($consoleHwnd -ne [IntPtr]::Zero) {
    [WinTopMost]::SetTopMost($consoleHwnd)
}

# ========== 公共配置 ==========
$EdgeExe        = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
$SourceUserData = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
$TargetUserData = "$env:LOCALAPPDATA\Microsoft\Edge\My User Data"
$ShortcutName   = "Edge remote debugging"
$RegistryPath   = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
$DesktopPath    = [Environment]::GetFolderPath("Desktop")
$StartMenuPath  = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$DefaultPort    = 9222

# ============================================================
#  辅助函数
# ============================================================

# 用 JavaScriptSerializer 解析 JSON，容忍大小写不同的重复键
# （PowerShell 5.1 的 ConvertFrom-Json 遇到重复键会抛异常）
function ConvertFrom-JsonSafe {
    param([string]$JsonText)
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction SilentlyContinue
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    return $serializer.DeserializeObject($JsonText)
}

# 静默关闭可能占用数据目录的进程
# 重启 explorer.exe 时会提示用户
function Stop-ConflictingProcesses {
    $edgeProcs = Get-Process -Name "msedge" -ErrorAction SilentlyContinue
    if ($edgeProcs) { $edgeProcs | Stop-Process -Force -ErrorAction SilentlyContinue }

    $wv2Procs = Get-Process -Name "msedgewebview2" -ErrorAction SilentlyContinue
    if ($wv2Procs) { $wv2Procs | Stop-Process -Force -ErrorAction SilentlyContinue }

    $searchProcs = Get-Process -Name "SearchApp" -ErrorAction SilentlyContinue
    if ($searchProcs) { $searchProcs | Stop-Process -Force -ErrorAction SilentlyContinue }

    Write-Host "正在重启资源管理器以释放文件句柄（任务栏会闪一下）..." -ForegroundColor Yellow
    $explorerProcs = Get-Process -Name "explorer" -ErrorAction SilentlyContinue
    if ($explorerProcs) {
        $explorerProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    Start-Process "explorer.exe" -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2
}

# 从扩展目录解析 manifest.json，返回名称和版本
# 本地化名称解析策略：优先 zh_CN，其次 en，再遍历其余 _locales 子目录，哪个能取到 key 就用哪个。
function Get-ExtensionInfo {
    param(
        [string]$ExtensionDir
    )
    $info = [PSCustomObject]@{
        Name    = $null
        Version = "未知"
    }

    # 找 manifest.json
    $manifestPath = Get-ChildItem -Path $ExtensionDir -Filter "manifest.json" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $manifestPath) { return $info }

    try {
        $manifest = ConvertFrom-JsonSafe -JsonText (Get-Content $manifestPath.FullName -Raw -Encoding UTF8)

        if ($manifest["version"]) { $info.Version = $manifest["version"] }
        if ($manifest["name"]) {
            $name = $manifest["name"]

            # __MSG_xxx__ 本地化占位符
            if ($name -match "^__MSG_(.+)__$") {
                $msgKey = $Matches[1]
                $versionDir = $manifestPath.Directory.FullName
                $localesDir = Join-Path $versionDir "_locales"

                if (Test-Path $localesDir) {
                    $resolved = $null

                    # 1. 优先 zh_CN
                    $zhPath = Join-Path $localesDir "zh_CN\messages.json"
                    if (Test-Path $zhPath) {
                        try {
                            $messages = Get-Content $zhPath -Raw -Encoding UTF8 | ConvertFrom-Json
                            if ($messages.PSObject.Properties.Name -contains $msgKey) {
                                $resolved = $messages.$msgKey.message
                            }
                        } catch { }
                    }

                    # 2. 其次 en
                    if (-not $resolved) {
                        $enPath = Join-Path $localesDir "en\messages.json"
                        if (Test-Path $enPath) {
                            try {
                                $messages = Get-Content $enPath -Raw -Encoding UTF8 | ConvertFrom-Json
                                if ($messages.PSObject.Properties.Name -contains $msgKey) {
                                    $resolved = $messages.$msgKey.message
                                }
                            } catch { }
                        }
                    }

                    # 3. 再遍历其余 _locales 子目录
                    if (-not $resolved) {
                        $localeFolders = Get-ChildItem -Path $localesDir -Directory -ErrorAction SilentlyContinue
                        foreach ($folder in $localeFolders) {
                            if ($folder.Name -eq "zh_CN" -or $folder.Name -eq "en") { continue }
                            $messagesPath = Join-Path $folder.FullName "messages.json"
                            if (Test-Path $messagesPath) {
                                try {
                                    $messages = Get-Content $messagesPath -Raw -Encoding UTF8 | ConvertFrom-Json
                                    if ($messages.PSObject.Properties.Name -contains $msgKey) {
                                        $resolved = $messages.$msgKey.message
                                        break
                                    }
                                } catch { }
                            }
                        }
                    }

                    if ($resolved) { $name = $resolved }
                }
            }

            $info.Name = $name
        }
    } catch { }

    return $info
}

# 判断目录名是否是合法的扩展 ID（32 位 a-p 小写字母）
function Test-ExtensionId {
    param([string]$Id)
    return $Id -match "^[a-p]{32}$"
}

# ============================================================
#  第一步：先说明脚本功能和具体实现
# ============================================================
Clear-Host
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " Edge 远程调试 配置工具" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "注意：无论选择配置还是回退，脚本都会先关闭所有正在运行的 Edge 进程，并重启资源管理器（任务栏会闪一下）。" -ForegroundColor Yellow
Write-Host "请提前保存好浏览器里未提交的内容，比如正在填写的表单。" -ForegroundColor Yellow
Write-Host ""
Write-Host "这个脚本有两种操作，你稍后可以二选一：" -ForegroundColor White
Write-Host ""
Write-Host "  【配置】帮你做以下 5 件事：" -ForegroundColor White
Write-Host "    1. 关闭所有正在运行的 Edge 进程。" -ForegroundColor Gray
Write-Host "    2. 把你的浏览器数据目录 User Data 改名为 My User Data，改名不改变文件时间戳。" -ForegroundColor Gray
Write-Host "    3. 再把 My User Data 复制一份为 User Data，作为配置前的备份。" -ForegroundColor Gray
Write-Host "    4. 设置注册表，让 Edge 使用 My User Data，并创建桌面和开始菜单的快捷方式。" -ForegroundColor Gray
Write-Host "    5. 启动 Edge 并验证调试端口。" -ForegroundColor Gray
Write-Host ""
Write-Host "  【回退】撤销配置时做的所有改动：" -ForegroundColor White
Write-Host "    1. 关闭所有正在运行的 Edge 进程。" -ForegroundColor Gray
Write-Host "    2. 列出与配置时相比消失的扩展，仅告知，不恢复。" -ForegroundColor Gray
Write-Host "    3. 删除备份 User Data。" -ForegroundColor Gray
Write-Host "    4. 把 My User Data 改名回 User Data，保留这段时间的所有改动。" -ForegroundColor Gray
Write-Host "    5. 删除注册表 UserDataDir 和两个快捷方式。" -ForegroundColor Gray
Write-Host ""
Write-Host "----------------------------------------------" -ForegroundColor DarkGray
Write-Host "脚本的限制：" -ForegroundColor Yellow
Write-Host "本脚本无法恢复被 Edge 删除的扩展程序。扩展能否被浏览器识别，取决于 Edge 内部的注册记录（Secure Preferences），" -ForegroundColor Yellow
Write-Host "而不是磁盘上的扩展文件夹。脚本只做文件层面的操作，无法重建这些内部记录。" -ForegroundColor Yellow
Write-Host "回退时会列出消失的扩展，仅供你参考。如需恢复请从 Edge 商店重新安装，或手动加载解压缩的扩展。" -ForegroundColor Yellow
Write-Host "----------------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Write-Host "全程不会上传任何数据，所有操作都在本机完成。配置后 User Data 是备份，My User Data 才是 Edge 实际使用的目录。" -ForegroundColor DarkGray
Write-Host "----------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# ============================================================
#  状态检测（仅用于提示，不影响选项）
# ============================================================
function Get-EdgeConfigState {
    $state = [PSCustomObject]@{
        UserDataDirSet          = $false
        UserDataDirValue        = $null
        RemoteDebuggingDisabled = $false
        ShortcutExists          = $false
        TargetFolderExists      = $false
        BackupFolderExists      = $false
    }

    if (Test-Path $RegistryPath) {
        $ud = Get-ItemProperty -Path $RegistryPath -Name "UserDataDir" -ErrorAction SilentlyContinue
        if ($ud) {
            $state.UserDataDirSet = $true
            $state.UserDataDirValue = $ud.UserDataDir
        }
        $rd = Get-ItemProperty -Path $RegistryPath -Name "RemoteDebuggingAllowed" -ErrorAction SilentlyContinue
        if ($rd -and $rd.RemoteDebuggingAllowed -eq 0) {
            $state.RemoteDebuggingDisabled = $true
        }
    }

    if ((Test-Path (Join-Path $DesktopPath "$ShortcutName.lnk")) -or
        (Test-Path (Join-Path $StartMenuPath "$ShortcutName.lnk"))) {
        $state.ShortcutExists = $true
    }

    if (Test-Path $TargetUserData) {
        $state.TargetFolderExists = $true
    }

    if (Test-Path $SourceUserData) {
        $state.BackupFolderExists = $true
    }

    return $state
}

# 读取快捷方式里的端口
function Get-ShortcutPort {
    $lnk = Join-Path $DesktopPath "$ShortcutName.lnk"
    if (-not (Test-Path $lnk)) {
        $lnk = Join-Path $StartMenuPath "$ShortcutName.lnk"
    }
    if (-not (Test-Path $lnk)) { return $null }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnk)
    if ($shortcut.Arguments -match "--remote-debugging-port=(\d+)") {
        return [int]$Matches[1]
    }
    return $null
}

$currentState = Get-EdgeConfigState
$currentPort = Get-ShortcutPort

Write-Host "当前状态检测结果：" -ForegroundColor White
Write-Host ""
Write-Host "  注册表 UserDataDir 策略：" -NoNewline
if ($currentState.UserDataDirSet) {
    Write-Host "已设置" -ForegroundColor Yellow
    Write-Host "    → $($currentState.UserDataDirValue)" -ForegroundColor Gray
} else {
    Write-Host "未设置" -ForegroundColor Green
}
Write-Host "  RemoteDebuggingAllowed 策略：" -NoNewline
if ($currentState.RemoteDebuggingDisabled) {
    Write-Host "被禁用" -ForegroundColor Red
} else {
    Write-Host "正常（未禁用）" -ForegroundColor Green
}
Write-Host "  快捷方式：「$ShortcutName」" -NoNewline
if ($currentState.ShortcutExists) {
    Write-Host "已存在" -ForegroundColor Yellow
    if ($currentPort) {
        Write-Host "    → 当前端口：$currentPort" -ForegroundColor Gray
    }
} else {
    Write-Host "不存在" -ForegroundColor Green
}
Write-Host "  数据目录 My User Data：" -NoNewline
if ($currentState.TargetFolderExists) {
    Write-Host "存在" -ForegroundColor Yellow
} else {
    Write-Host "不存在" -ForegroundColor Green
}
Write-Host "  备份目录 User Data：" -NoNewline
if ($currentState.BackupFolderExists) {
    Write-Host "存在" -ForegroundColor Yellow
} else {
    Write-Host "不存在" -ForegroundColor Green
}

Write-Host ""
Write-Host "----------------------------------------------" -ForegroundColor DarkGray

if ($currentState.UserDataDirSet -and $currentState.ShortcutExists) {
    Write-Host "判断：看起来已处于「配置后」状态。如需恢复，请选择回退。如需重新配置，也可以直接选择配置。" -ForegroundColor Yellow
} elseif (-not $currentState.UserDataDirSet -and -not $currentState.ShortcutExists) {
    Write-Host "判断：看起来处于「未配置」的原始状态。如需开启远程调试，请选择配置。" -ForegroundColor Green
} else {
    Write-Host "判断：状态不完整，可能之前配置中断或手动修改过。你可以选择配置来补全，或选择回退来清理。" -ForegroundColor Magenta
}

Write-Host "----------------------------------------------" -ForegroundColor DarkGray
Write-Host ""

# ============================================================
#  第二步：让用户选择操作
# ============================================================
Write-Host "请选择要执行的操作：" -ForegroundColor White
Write-Host "  1. 配置（开启或重新配置远程调试）" -ForegroundColor White
Write-Host "  2. 回退（撤销配置，恢复原始状态）" -ForegroundColor White
Write-Host "  0. 退出" -ForegroundColor Gray
Write-Host ""
$choice = Read-Host "输入选项（0/1/2）"

if ($choice -eq "0") {
    Write-Host "已退出。" -ForegroundColor Gray
    exit
} elseif ($choice -eq "2") {
    $Rollback = $true
} elseif ($choice -eq "1") {
    $Rollback = $false
} else {
    Write-Host "无效输入，默认执行配置。" -ForegroundColor Yellow
    $Rollback = $false
}

# ============================================================
#  第三步：权限检测
# ============================================================
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
$isAdmin = $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Clear-Host
    Write-Host ""
    Write-Host "本脚本需要管理员权限才能修改系统注册表。" -ForegroundColor Yellow
    Write-Host "即将以管理员身份重新启动。" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "如果弹出窗口询问：" -NoNewline
    Write-Host "「你要允许来自未知发布者的此应用对你的设备进行更改吗？」" -ForegroundColor Cyan
    Write-Host "请点击「是」即可继续。" -ForegroundColor Cyan
    Write-Host ""
    Start-Sleep -Seconds 3
    $scriptPath = $MyInvocation.MyCommand.Path
    if ($Rollback) {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
            -Verb RunAs
    } elseif ($Port -gt 0) {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Port $Port" `
            -Verb RunAs
    } else {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
            -Verb RunAs
    }
    exit
}

# ============================================================
#  模式一：回退
# ============================================================
if ($Rollback) {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host " Edge 远程调试 回退" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "回退将执行以下操作（顺序固定）：" -ForegroundColor White
    Write-Host ""
    Write-Host "  1. 关闭所有正在运行的 Edge 进程" -ForegroundColor White
    Write-Host "  2. 列出与配置时相比消失的扩展（仅告知）" -ForegroundColor White
    Write-Host "  3. 删除备份 User Data" -ForegroundColor White
    Write-Host "  4. 把 My User Data 改名回 User Data" -ForegroundColor White
    Write-Host "  5. 删除注册表 UserDataDir 和两个快捷方式" -ForegroundColor White
    Write-Host ""
    Write-Host "My User Data 里的最新数据会完整保留。" -ForegroundColor Green
    Write-Host ""
    Write-Host "注意：本脚本无法恢复被 Edge 删除的扩展程序。如需恢复，请从 Edge 商店重新安装，或手动加载解压缩的扩展。" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "按回车键开始回退"

    Write-Host "正在关闭所有 Edge 及相关进程..." -ForegroundColor Yellow
    Stop-ConflictingProcesses
    Write-Host "已关闭。" -ForegroundColor Green

    $missingExts = @()
    if ((Test-Path $SourceUserData) -and (Test-Path $TargetUserData)) {
        $backupExtDir = Join-Path $SourceUserData "Default\Extensions"
        $currentExtDir = Join-Path $TargetUserData "Default\Extensions"

        if ((Test-Path $backupExtDir) -and (Test-Path $currentExtDir)) {
            $backupExts = Get-ChildItem -Path $backupExtDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-ExtensionId $_.Name }
            $currentExts = Get-ChildItem -Path $currentExtDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-ExtensionId $_.Name } |
                Select-Object -ExpandProperty Name

            foreach ($ext in $backupExts) {
                if ($ext.Name -notin $currentExts) {
                    $info = Get-ExtensionInfo -ExtensionDir $ext.FullName
                    $missingExts += [PSCustomObject]@{
                        Id      = $ext.Name
                        Name    = if ($info.Name) { $info.Name } else { $ext.Name }
                        Version = $info.Version
                    }
                }
            }

            if ($missingExts.Count -gt 0) {
                Write-Host ""
                Write-Host "与配置时相比，以下扩展已不在当前数据中：" -ForegroundColor Yellow
                Write-Host ""
                foreach ($ext in $missingExts) {
                    Write-Host "  - $($ext.Name)  版本 $($ext.Version)  (ID: $($ext.Id))" -ForegroundColor Gray
                }
                Write-Host ""
                Write-Host "这些扩展可能是 Edge 升级时被删除的，也可能是你手动卸载的。本脚本无法区分，也无法自动恢复。" -ForegroundColor Gray
                Write-Host "如需恢复，请从 Edge 商店重新安装，或手动加载解压缩的扩展。" -ForegroundColor Gray
            } else {
                Write-Host "扩展对比：与配置时相比，没有扩展消失。" -ForegroundColor Green
            }
        } else {
            Write-Host "扩展目录不完整，跳过扩展对比。" -ForegroundColor Yellow
        }
    } else {
        Write-Host "备份或当前数据目录不存在，跳过扩展对比。" -ForegroundColor Yellow
    }

    if (Test-Path $SourceUserData) {
        try {
            Remove-Item -Path $SourceUserData -Recurse -Force -ErrorAction Stop
            Write-Host "已删除备份 User Data。" -ForegroundColor Green
        } catch {
            Write-Host "删除备份 User Data 失败：$($_.Exception.Message)" -ForegroundColor Red
            Write-Host "请手动关闭所有 Edge 后重试。" -ForegroundColor Yellow
            Read-Host "按回车键退出"
            exit 1
        }
    } else {
        Write-Host "备份 User Data 不存在，跳过。" -ForegroundColor Yellow
    }

    if (Test-Path $TargetUserData) {
        try {
            Rename-Item -Path $TargetUserData -NewName "User Data" -ErrorAction Stop
            Write-Host "已将 My User Data 改名回 User Data。" -ForegroundColor Green
        } catch {
            Write-Host "改名失败：$($_.Exception.Message)" -ForegroundColor Red
            Write-Host "可能仍有进程占用该目录，请手动关闭后重试。本次未对 My User Data 做任何改动，数据完好。" -ForegroundColor Yellow
            Read-Host "按回车键退出"
            exit 1
        }
    } else {
        Write-Host "My User Data 不存在，跳过改名。" -ForegroundColor Yellow
    }

    if (Test-Path $RegistryPath) {
        $val = Get-ItemProperty -Path $RegistryPath -Name "UserDataDir" -ErrorAction SilentlyContinue
        if ($val) {
            Remove-ItemProperty -Path $RegistryPath -Name "UserDataDir" -Force
            Write-Host "已删除注册表 UserDataDir。" -ForegroundColor Green
        } else {
            Write-Host "注册表 UserDataDir 不存在，跳过。" -ForegroundColor Yellow
        }
    } else {
        Write-Host "注册表策略路径不存在，跳过。" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "提示：如果之前你手动设置过 RemoteDebuggingAllowed 策略，回退不会自动恢复它。请在注册表中手动检查并重新设置。" -ForegroundColor Yellow

    $shortcutPaths = @(
        (Join-Path $DesktopPath "$ShortcutName.lnk"),
        (Join-Path $StartMenuPath "$ShortcutName.lnk")
    )
    foreach ($lnk in $shortcutPaths) {
        if (Test-Path $lnk) {
            Remove-Item -Path $lnk -Force
            Write-Host "已删除快捷方式：$lnk" -ForegroundColor Green
        } else {
            Write-Host "快捷方式不存在，跳过：$lnk" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "=== 回退完成 ===" -ForegroundColor Cyan
    Write-Host "Edge 将恢复使用默认 User Data 目录。" -ForegroundColor Green
    if ($missingExts.Count -gt 0) {
        Write-Host ""
        Write-Host "提醒：以下扩展已不在当前数据中，脚本无法恢复：" -ForegroundColor Yellow
        foreach ($ext in $missingExts) {
            Write-Host "  - $($ext.Name)  版本 $($ext.Version)" -ForegroundColor Gray
        }
        Write-Host "如需恢复，请从 Edge 商店重新安装，或手动加载解压缩的扩展。" -ForegroundColor Yellow
    }
    Write-Host ""
    Read-Host "按回车键退出"
    exit
}

# ============================================================
#  模式二：配置
# ============================================================
Clear-Host
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " Edge 远程调试 一键配置" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

$existingPort = Get-ShortcutPort
Write-Host "请设置远程调试端口。" -ForegroundColor White
if ($existingPort) {
    Write-Host "当前已配置端口：$existingPort" -ForegroundColor Cyan
    Write-Host "直接回车保持原端口；也可输入新端口（1024-65535）。" -ForegroundColor Gray
} else {
    Write-Host "直接回车使用默认端口 $DefaultPort；也可输入自定义端口（1024-65535）。" -ForegroundColor Gray
}
$userInput = Read-Host "端口"
if ([string]::IsNullOrWhiteSpace($userInput)) {
    if ($existingPort) {
        $Port = $existingPort
        Write-Host "保持原端口：$Port" -ForegroundColor Green
    } else {
        $Port = $DefaultPort
        Write-Host "使用默认端口：$Port" -ForegroundColor Green
    }
} else {
    $parsed = 0
    if ([int]::TryParse($userInput, [ref]$parsed) -and $parsed -ge 1024 -and $parsed -le 65535) {
        $Port = $parsed
        Write-Host "使用自定义端口：$Port" -ForegroundColor Green
    } else {
        if ($existingPort) {
            $Port = $existingPort
            Write-Host "输入无效，保持原端口：$Port" -ForegroundColor Yellow
        } else {
            $Port = $DefaultPort
            Write-Host "输入无效，回退到默认端口：$Port" -ForegroundColor Yellow
        }
    }
}
Write-Host ""
Read-Host "按回车键开始配置"

Write-Host "正在关闭所有 Edge 及相关进程..." -ForegroundColor Yellow
Stop-ConflictingProcesses
Write-Host "已关闭。" -ForegroundColor Green

if (Test-Path $TargetUserData) {
    Write-Host "检测到 My User Data 已存在，跳过改名和备份。（如需重新生成备份，请先回退再配置。）" -ForegroundColor Yellow
} else {
    if (-not (Test-Path $SourceUserData)) {
        Write-Host "错误：找不到默认 User Data 目录：$SourceUserData" -ForegroundColor Red
        Read-Host "按回车键退出"
        exit 1
    }

    try {
        Rename-Item -Path $SourceUserData -NewName "My User Data" -ErrorAction Stop
        Write-Host "已将 User Data 改名为 My User Data（时间戳保留）。" -ForegroundColor Green
    } catch {
        Write-Host "改名失败：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "请确认所有 Edge、资源管理器窗口已关闭后重试。数据完好，未做任何改动。" -ForegroundColor Yellow
        Read-Host "按回车键退出"
        exit 1
    }

    Write-Host "正在复制 My User Data 为 User Data（备份，可能需要几分钟）..." -ForegroundColor Yellow
    try {
        Copy-Item -Path $TargetUserData -Destination $SourceUserData -Recurse -Force -ErrorAction Stop
        Write-Host "备份完成：User Data 是配置前的数据快照。" -ForegroundColor Green
    } catch {
        Write-Host "复制备份失败：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "正在回滚改名操作..." -ForegroundColor Yellow
        try {
            Rename-Item -Path $TargetUserData -NewName "User Data" -ErrorAction Stop
            Write-Host "已回滚，User Data 恢复原状。" -ForegroundColor Green
        } catch {
            Write-Host "回滚失败，请手动把 My User Data 改名回 User Data。" -ForegroundColor Red
        }
        Read-Host "按回车键退出"
        exit 1
    }
}

if (-not (Test-Path $RegistryPath)) {
    New-Item -Path $RegistryPath -Force | Out-Null
}
Set-ItemProperty -Path $RegistryPath -Name "UserDataDir" -Value $TargetUserData -Type String
Write-Host "注册表已设置：UserDataDir = $TargetUserData" -ForegroundColor Green

$remoteDebugValue = Get-ItemProperty -Path $RegistryPath -Name "RemoteDebuggingAllowed" -ErrorAction SilentlyContinue
if ($remoteDebugValue -and $remoteDebugValue.RemoteDebuggingAllowed -eq 0) {
    Write-Host "检测到 RemoteDebuggingAllowed 被禁用，正在恢复..." -ForegroundColor Yellow
    Remove-ItemProperty -Path $RegistryPath -Name "RemoteDebuggingAllowed" -Force
}

$shell = New-Object -ComObject WScript.Shell
$shortcutTargets = @(
    (Join-Path $DesktopPath "$ShortcutName.lnk"),
    (Join-Path $StartMenuPath "$ShortcutName.lnk")
)
foreach ($lnkPath in $shortcutTargets) {
    $shortcut = $shell.CreateShortcut($lnkPath)
    $shortcut.TargetPath = $EdgeExe
    $shortcut.Arguments = "--remote-debugging-port=$Port"
    $shortcut.Description = "Edge Remote Debugging on port $Port"
    $shortcut.Save()
    Write-Host "已创建快捷方式：$lnkPath" -ForegroundColor Green
}

Write-Host "`n正在检查防火墙规则..." -ForegroundColor Yellow
$fwRules = Get-NetFirewallRule -Enabled True -Direction Inbound -ErrorAction SilentlyContinue |
    Where-Object {
        ($_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq $Port
    }
if ($fwRules) {
    Write-Host ""
    Write-Host "注意：检测到防火墙中有针对端口 $Port 的入站规则。远程调试端口默认只监听本机（127.0.0.1），" -ForegroundColor Red
    Write-Host "如果这条规则允许外部网络访问，会带来安全风险。" -ForegroundColor Yellow
} else {
    Write-Host "未发现针对端口 $Port 的外部放行规则，安全。" -ForegroundColor Green
}

Write-Host "`n正在启动 Edge 进行验证..." -ForegroundColor Yellow
Start-Process -FilePath $EdgeExe -ArgumentList "--remote-debugging-port=$Port"
Start-Sleep -Seconds 5
try {
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 5
    Write-Host "`n远程调试已成功开启！" -ForegroundColor Green
    Write-Host "浏览器版本：$($response.Browser)" -ForegroundColor Cyan
    Write-Host "Agent 连接地址：$($response.webSocketDebuggerUrl)" -ForegroundColor Cyan
} catch {
    Write-Host "`n验证失败，端口 $Port 无响应。" -ForegroundColor Red
    Write-Host "请手动打开 edge://version/ 检查「配置文件路径」是否指向：$TargetUserData" -ForegroundColor Yellow
}

Write-Host "`n=== 日常使用说明 ===" -ForegroundColor Cyan
Write-Host "1. 以后请通过桌面或开始菜单的「$ShortcutName」启动 Edge。"
Write-Host "2. Agent 连接地址：ws://127.0.0.1:$Port/devtools/browser/<uuid>"
Write-Host "3. 启动前建议完全退出 Edge（包括托盘），否则参数会被转发给已有实例而失效。"
Write-Host "4. 如需回退，重新运行本脚本并选择回退即可。"
Write-Host "5. 回退时会列出与配置时相比消失的扩展（仅告知，无法恢复）。" -ForegroundColor Gray
Write-Host ""
Read-Host "按回车键退出"
