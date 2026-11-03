#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
  Игровой профиль золотого образа клуба. Один раз на эталоне, пока Super Client
  пишет диск image. После save настройки получают все ПК с тем же образом.
  Шелл это не вызывает.

  Запуск (на эталоне, не на машине разработчика):
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\Qt\golden-image-gaming\golden-image-gaming.ps1 -Apply

  Без -Apply скрипт ничего не меняет. Лог: golden-image-gaming-last.log рядом со скриптом.
  Дальше перезагрузка (ПК всё ещё в Super Client), проверка, затем «Выключить и сохранить».

  Не делает: MMCSS / SystemResponsiveness / NetworkThrottlingIndex, отключение
  Windows Update, Защитника, звука, DHCP, DNS, RPC, файла подкачки, Secure Boot, TPM,
  смену оболочки, обновление драйвера NIC, PnPCapabilities=24 (гасит WoL).
#>
param(
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$script:Notes = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Errors = New-Object System.Collections.Generic.List[string]

function Add-Note([string]$Message) {
    $script:Notes.Add($Message)
    Write-Host "  + $Message"
}

function Add-Warn([string]$Message) {
    $script:Warnings.Add($Message)
    Write-Warning $Message
}

function Add-Err([string]$Message) {
    $script:Errors.Add($Message)
    Write-Host "  ! $Message" -ForegroundColor Red
}

function Section([string]$Title) {
    Write-Host ""
    Write-Host "=== $Title ==="
}

function Set-RegDword {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )
    & reg.exe add $Key /v $Name /t REG_DWORD /d $Value /f | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "reg add $Key $Name = $Value"
    }
}

function Set-ClubUserKeys([string]$Hive) {
    Set-RegDword "$Hive\Software\Microsoft\GameBar" 'AutoGameModeEnabled' 1
    Set-RegDword "$Hive\Software\Microsoft\GameBar" 'AllowAutoGameMode' 1
    Set-RegDword "$Hive\Software\Microsoft\GameBar" 'UseNexusForGameBarEnabled' 0
    Set-RegDword "$Hive\System\GameConfigStore" 'GameDVR_Enabled' 0
    Set-RegDword "$Hive\Software\Microsoft\Windows\CurrentVersion\GameDVR" 'AppCaptureEnabled' 0
    Set-RegDword "$Hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'TaskbarDa' 0
    Set-RegDword "$Hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'ShowCopilotButton' 0
    Set-RegDword "$Hive\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" 'VisualFXSetting' 2
    Set-RegDword "$Hive\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SystemPaneSuggestionsEnabled' 0
    Set-RegDword "$Hive\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SoftLandingEnabled' 0
    Set-RegDword "$Hive\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SilentInstalledAppsEnabled' 0
    Set-RegDword "$Hive\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SubscribedContent-338389Enabled' 0
    Set-RegDword "$Hive\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" 'SubscribedContent-310093Enabled' 0
    Set-RegDword "$Hive\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" 'GlobalUserDisabled' 1
    Set-RegDword "$Hive\Software\Microsoft\Windows\CurrentVersion\Search" 'BackgroundAppGlobalToggle' 0
}

function Invoke-WithHive {
    param(
        [Parameter(Mandatory = $true)][string]$DatPath,
        [Parameter(Mandatory = $true)][string]$HiveName,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    if (-not (Test-Path -LiteralPath $DatPath)) {
        return $false
    }
    & reg.exe load "HKU\$HiveName" $DatPath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Add-Warn "не загрузился куст $DatPath"
        return $false
    }
    try {
        & $Action "HKU\$HiveName"
        return $true
    } finally {
        [gc]::Collect()
        Start-Sleep -Milliseconds 300
        & reg.exe unload "HKU\$HiveName" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Add-Warn "не выгрузился HKU\$HiveName. Повторите прогон после перезагрузки, если Game Mode нужен в этом профиле."
        }
    }
}

if (-not $Apply) {
    Write-Host @"
Игровой профиль золотого образа. Без -Apply ничего не меняет.

Запускать на эталонном игровом ПК, когда Super Client уже пишет диск image
и гостя на месте нет. Не запускать на машине разработчика.

  powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Apply

После скрипта — перезагрузка, ПК всё ещё в Super Client. Проверить схему питания,
VBS, EEE и Wake on Magic Packet. Потом setup → «Выключить и сохранить».
MMCSS скрипт не трогает. Глава в доках: «Игровой профиль золотого образа».
"@
    exit 2
}

$logPath = Join-Path $PSScriptRoot 'golden-image-gaming-last.log'
try {
    Start-Transcript -Path $logPath -Force | Out-Null
} catch {
    Add-Warn "транскрипт не открылся: $($_.Exception.Message)"
}

Write-Host "Игровой профиль. Лог: $logPath"
Write-Host "Эталон должен быть в Super Client (диск image). Иначе правки умрут с writeback."

# --- Платформа: предупредить, не чинить Secure Boot / TPM ---
Section 'Secure Boot и TPM (только проверка)'
try {
    $secureBoot = Confirm-SecureBootUEFI
    if ($secureBoot -eq $true) {
        Add-Note 'Secure Boot включён'
    } else {
        Add-Warn 'Secure Boot выключен. FACEIT AC требует TPM 2.0 и Secure Boot в UEFI. Скрипт их не включает.'
    }
} catch {
    Add-Warn 'Secure Boot не прочитан. FACEIT AC требует Secure Boot в UEFI каждой платы.'
}
try {
    $tpm = Get-Tpm
    if ($tpm.TpmPresent -and $tpm.TpmReady) {
        Add-Note 'TPM готов'
    } else {
        Add-Warn 'TPM не готов. FACEIT AC на клиентах не поднимется, пока TPM 2.0 не включён в UEFI.'
    }
} catch {
    Add-Warn "Get-Tpm: $($_.Exception.Message)"
}

# --- Схема питания ---
Section 'Схема питания'
$ultimateTemplate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$highPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$subProcessor = '54533251-82be-4824-96c1-47b60b740d00'
$minState = '893dee8e-2bef-41e0-89c6-b55d0929964c'
$maxState = 'bc5038f7-23e0-4960-96da-33abaf5935ec'
$subUsb = '2a737441-1930-4402-8d77-b2bebba308a3'
$usbSuspend = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$subPci = '501a4d13-42af-4429-9fd1-a8218c268e20'
$aspm = 'ee12f906-d277-404b-b6da-e5fa1a576df5'

$schemeGuid = $null
$list = @(& powercfg.exe /l)
foreach ($line in $list) {
    if ($line -match '([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})\s+\((.+)\)') {
        $guid = $Matches[1]
        $name = $Matches[2].Trim()
        if ($name -match 'Ultimate Performance|Максимальная производительность') {
            $schemeGuid = $guid
            break
        }
        if ($guid -eq $ultimateTemplate) {
            $schemeGuid = $guid
        }
    }
}
if (-not $schemeGuid) {
    $dup = & powercfg.exe -duplicatescheme $ultimateTemplate 2>&1 | Out-String
    if ($dup -match '([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})') {
        $schemeGuid = $Matches[1]
        Add-Note "создана схема максимальной производительности $schemeGuid"
    }
}
if (-not $schemeGuid) {
    $schemeGuid = $highPerformance
    Add-Warn 'шаблон максимальной производительности недоступен, берётся высокая производительность'
}

function Set-PlanValue([string]$SettingSub, [string]$Setting, [int]$Value) {
    & powercfg.exe /setacvalueindex $schemeGuid $SettingSub $Setting $Value | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "setac $Setting" }
    & powercfg.exe /setdcvalueindex $schemeGuid $SettingSub $Setting $Value | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "setdc $Setting" }
}

try {
    Set-PlanValue $subProcessor $minState 100
    Set-PlanValue $subProcessor $maxState 100
    Set-PlanValue $subUsb $usbSuspend 0
    Set-PlanValue $subPci $aspm 0
    & powercfg.exe /setactive $schemeGuid | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'setactive' }
    Add-Note "активная схема $schemeGuid (мин. процессора 100%, сон USB выкл, ASPM выкл)"
} catch {
    Add-Err "схема питания: $($_.Exception.Message)"
}

try {
    & powercfg.exe -h off | Out-Null
    Add-Note 'гибернация выключена (вместе с быстрым запуском)'
} catch {
    Add-Err "powercfg -h off: $($_.Exception.Message)"
}
try {
    Set-RegDword 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
    Add-Note 'HiberbootEnabled=0'
} catch {
    Add-Err "быстрый запуск: $($_.Exception.Message)"
}

# --- VBS / HVCI. Secure Boot и TPM не трогаем. ---
Section 'VBS и целостность памяти'
try {
    Set-RegDword 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
    Set-RegDword 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
    Set-RegDword 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard' 'Enabled' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'HVCIMATRequired' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'LsaCfgFlags' 0
    Add-Note 'DeviceGuard / HVCI / Credential Guard выключены политикой'
} catch {
    Add-Err "реестр VBS: $($_.Exception.Message)"
}

& bcdedit.exe /set hypervisorlaunchtype off | Out-Null
if ($LASTEXITCODE -eq 0) {
    Add-Note 'hypervisorlaunchtype=off'
} else {
    Add-Err 'bcdedit hypervisorlaunchtype off не выполнился'
}
& bcdedit.exe /set vsmlaunchtype off | Out-Null
if ($LASTEXITCODE -eq 0) {
    Add-Note 'vsmlaunchtype=off'
} else {
    Add-Warn 'bcdedit vsmlaunchtype off не поддерживается этой сборкой. HVCI всё равно закрыт политикой.'
}

foreach ($featureName in @(
        'Microsoft-Hyper-V-All',
        'Microsoft-Hyper-V',
        'HypervisorPlatform',
        'VirtualMachinePlatform',
        'Microsoft-Windows-Subsystem-Linux'
    )) {
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
        if ($feature.State -eq 'Enabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName $featureName -NoRestart -ErrorAction Stop | Out-Null
            Add-Note "компонент $featureName выключен"
        }
    } catch {
        # Компонента нет в этом издании.
    }
}

# --- Игровой режим, HAGS, без записи Xbox ---
Section 'Игровой режим и HAGS'
try {
    Set-RegDword 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    Add-Note 'HAGS включён (HwSchMode=2), Game DVR запрещён политикой'
} catch {
    Add-Err "HAGS / Game DVR: $($_.Exception.Message)"
}

try {
    Set-ClubUserKeys 'HKCU'
    Add-Note 'текущий профиль: игровой режим вкл, запись Game Bar выкл'
} catch {
    Add-Err "HKCU игровой режим: $($_.Exception.Message)"
}

Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | ForEach-Object {
    $sid = $_.PSChildName
    if ($sid -match '^S-1-5-21-' -and $sid -notmatch '_Classes$') {
        try {
            Set-ClubUserKeys "HKU\$sid"
        } catch {
            Add-Warn "профиль $sid : $($_.Exception.Message)"
        }
    }
}

$loadedSids = @{}
Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | ForEach-Object {
    $loadedSids[$_.PSChildName] = $true
}
try {
    $profiles = Get-CimInstance Win32_UserProfile | Where-Object {
        -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath (Join-Path $_.LocalPath 'NTUSER.DAT'))
    }
    foreach ($profile in $profiles) {
        if ($loadedSids.ContainsKey([string]$profile.SID)) {
            continue
        }
        $loaded = Invoke-WithHive -DatPath (Join-Path $profile.LocalPath 'NTUSER.DAT') -HiveName 'ReactorGolden' -Action {
            param($hive)
            Set-ClubUserKeys $hive
        }
        if ($loaded) {
            Add-Note "профиль $($profile.LocalPath): игровой режим"
        }
    }
    $defaultLoaded = Invoke-WithHive -DatPath (Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT') -HiveName 'ReactorDefault' -Action {
        param($hive)
        Set-ClubUserKeys $hive
    }
    if ($defaultLoaded) {
        Add-Note 'профиль Default: игровой режим для новых учёток'
    }
} catch {
    Add-Warn "профили пользователей: $($_.Exception.Message)"
}

# --- Службы фона. Update, Defender, звук, сеть, Gaming Services остаются. ---
Section 'Службы'
foreach ($serviceName in @('WSearch', 'SysMain', 'DiagTrack', 'dmwappushservice', 'DoSvc')) {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Add-Note "служба $serviceName отсутствует, пропуск"
        continue
    }
    try {
        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        }
        Set-Service -Name $serviceName -StartupType Disabled
        Add-Note "служба $serviceName отключена"
    } catch {
        Add-Err "служба ${serviceName}: $($_.Exception.Message)"
    }
}
try {
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 100
    Add-Note 'Delivery Optimization: режим bypass, без раздачи по LAN'
} catch {
    Add-Err "политика Delivery Optimization: $($_.Exception.Message)"
}

foreach ($taskPath in @(
        '\Microsoft\Windows\Application Experience\',
        '\Microsoft\Windows\Customer Experience Improvement Program\'
    )) {
    $taskNames = @('Microsoft Compatibility Appraiser', 'Consolidator', 'UsbCeip')
    foreach ($taskName in $taskNames) {
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
        if (-not $task) { continue }
        try {
            Disable-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop | Out-Null
            Add-Note "задача $taskPath$taskName отключена"
        } catch {
            Add-Warn "задача $taskName : $($_.Exception.Message)"
        }
    }
}

# --- Компоненты, которые клубу не нужны ---
Section 'Компоненты Windows'
foreach ($featureName in @(
        'Printing-XPSServices-Features',
        'WorkFolders-Client',
        'SMB1Protocol-Client',
        'SMB1Protocol-Server',
        'SMB1Protocol',
        'Printing-Foundation-InternetPrinting-Client'
    )) {
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
        if ($feature.State -eq 'Enabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName $featureName -NoRestart -ErrorAction Stop | Out-Null
            Add-Note "компонент $featureName выключен"
        }
    } catch {
        # Нет в этом издании.
    }
}
try {
    $fax = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object {
            $_.Name -like 'Print.Fax.Scan*' -and $_.State -eq 'Installed'
        })
    foreach ($cap in $fax) {
        Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
        Add-Note "возможность $($cap.Name) снята"
    }
} catch {
    Add-Warn "факс: $($_.Exception.Message)"
}
try {
    $recall = @(Get-WindowsCapability -Online -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like '*Recall*' -and $_.State -eq 'Installed'
        })
    foreach ($cap in $recall) {
        Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction SilentlyContinue | Out-Null
        Add-Note "возможность $($cap.Name) снята"
    }
} catch {
    Add-Warn "Recall: $($_.Exception.Message)"
}

# --- Политики фона и пакеты. Store и Gaming Services не снимаем. ---
Section 'Фон, Copilot, Recall, пакеты'
try {
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
    Set-RegDword 'HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
    Add-Note 'политики: потребительские приложения, виджеты, Copilot, Recall, автозапуск Edge, OneDrive'
} catch {
    Add-Err "политики фона: $($_.Exception.Message)"
}

$removePackages = @(
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.People',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.YourPhone',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MixedReality.Portal',
    'Microsoft.GamingApp',
    'Microsoft.Xbox.TCUI',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.Windows.Copilot',
    'Microsoft.Copilot',
    'Microsoft.Windows.Ai.Copilot.Provider',
    'MicrosoftWindows.Client.WebExperience',
    'Microsoft.OutlookForWindows',
    'MicrosoftTeams',
    'MSTeams',
    'Clipchamp.Clipchamp',
    'Microsoft.Todos',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.549981C3F5F10',
    'Microsoft.WindowsMaps',
    'Microsoft.SkypeApp'
)
foreach ($packageName in $removePackages) {
    try {
        $installed = @(Get-AppxPackage -AllUsers -Name $packageName -ErrorAction SilentlyContinue)
        foreach ($package in $installed) {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
            Add-Note "снят пакет $($package.PackageFullName)"
        }
    } catch {
        Add-Warn "пакет ${packageName}: $($_.Exception.Message)"
    }
    try {
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object {
                $_.DisplayName -eq $packageName
            })
        foreach ($package in $provisioned) {
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
            Add-Note "снят провижининг $($package.DisplayName)"
        }
    } catch {
        Add-Warn "провижининг ${packageName}: $($_.Exception.Message)"
    }
}

foreach ($oneDrive in @(
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe",
        "$env:SystemRoot\System32\OneDriveSetup.exe"
    )) {
    if (-not (Test-Path -LiteralPath $oneDrive)) { continue }
    try {
        Start-Process -FilePath $oneDrive -ArgumentList '/uninstall' -Wait -WindowStyle Hidden
        Add-Note 'OneDrive: uninstall'
    } catch {
        Add-Warn "OneDrive: $($_.Exception.Message)"
    }
    break
}

# --- Защитник: исключения каталогов, сам Defender остаётся ---
Section 'Исключения Защитника'
$exclusionPaths = @(
    'D:\Steam',
    'D:\Games',
    'D:\Epic Games',
    'D:\Riot Games',
    'D:\Battle.net',
    'D:\Program Files\Epic Games',
    'D:\Program Files\Electronic Arts',
    'C:\Program Files (x86)\Steam',
    'C:\Program Files\Epic Games',
    'C:\Program Files (x86)\Battle.net',
    'C:\Riot Games',
    'C:\Program Files\Electronic Arts'
)
if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
    Add-Warn 'Add-MpPreference нет. Исключения Защитника не записаны.'
} else {
    try {
        $existing = @((Get-MpPreference).ExclusionPath)
        foreach ($folder in $exclusionPaths) {
            if ($existing -contains $folder) {
                continue
            }
            Add-MpPreference -ExclusionPath $folder
            Add-Note "исключение Защитника: $folder"
        }
    } catch {
        Add-Err "исключения Защитника: $($_.Exception.Message)"
    }
}

# --- NIC. Адаптер не перезапускаем: по нему висит iSCSI образа. ---
Section 'Сетевые адаптеры'
$disableKeywords = @(
    '*EEE', 'EEE', 'AdvancedEEE', 'EEELinkAdvertisement', 'EeePhyEnable',
    'GreenEthernet', 'EnableGreenEthernet',
    'GigaLite', 'PowerSavingMode', 'AutoDisableGigabit',
    '*SelectiveSuspend', 'SelectiveSuspend',
    '*UltraLowPowerMode', 'ULPMode', 'UltraLowPowerMode', '*UlpMode', 'UlpMode',
    'SystemIdlePowerSaver', '*SystemIdlePowerSaver', '*NicAutoPowerSaver',
    'ReduceSpeedOnPowerDown', '*DeviceSleepOnDisconnect',
    'EnableDynamicPowerGating', '*EnableDynamicPowerGating',
    '*WakeOnPattern', 'WakeOnPattern'
)
$enableKeywords = @(
    '*WakeOnMagicPacket', 'WakeOnMagicPacket', 'S5WakeOnLan',
    'WakeOnMagicPacketFromS5', '*ModernStandbyWoLMagicPacket',
    'EnablePME', 'WakeFromS5', 'ShutdownWakeOnLan'
)
$disableDisplay = @(
    '*Energy Efficient*', '*Efficient Ethernet*', '*Advanced EEE*',
    '*Green Ethernet*', '*Gigabit Lite*', '*Power Saving Mode*',
    '*Ultra Low Power*', '*System Idle Power Saver*', '*Auto Disable Gigabit*',
    '*Selective Suspend*',
    '*Энергосберегающий Ethernet*', '*Зелен*Ethernet*', '*Гигабит Lite*',
    '*Режим энергосбережения*', '*Сверхнизк*', '*Автоотключение*'
)
$enableDisplay = @(
    '*Magic Packet*', '*MagicPacket*', '*магическ*', '*Магическ*',
    '*Shutdown Wake*', '*Wake-On-Lan при выключ*'
)

function Test-AnyLike([string]$Text, [string[]]$Patterns) {
    foreach ($pattern in $Patterns) {
        if ($Text -like $pattern) { return $true }
    }
    return $false
}

$adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
        ($_.NdisPhysicalMedium -eq '802.3' -or $_.MediaType -eq '802.3') -and
        $_.InterfaceDescription -notmatch 'VPN|Hyper-V|Virtual|Bluetooth|TAP|Tunnel|WAN Miniport|Loopback'
    })
if ($adapters.Count -eq 0) {
    Add-Err 'физический Ethernet не найден. EEE не настроен.'
}

foreach ($adapter in $adapters) {
    Write-Host "  адаптер $($adapter.Name): $($adapter.InterfaceDescription)"
    try {
        $properties = @(Get-NetAdapterAdvancedProperty -Name $adapter.Name -AllProperties -ErrorAction Stop)
    } catch {
        Add-Err "$($adapter.Name): свойства не прочитаны ($($_.Exception.Message))"
        continue
    }
    foreach ($property in $properties) {
        $keyword = [string]$property.RegistryKeyword
        $display = [string]$property.DisplayName
        $isPattern = ($keyword -in @('*WakeOnPattern', 'WakeOnPattern')) -or ($display -like '*Pattern*') -or ($display -like '*шаблон*')
        $isMagicWake = (-not $isPattern) -and (($enableKeywords -contains $keyword) -or (Test-AnyLike $display $enableDisplay))
        $turnOff = $isPattern -or ($disableKeywords -contains $keyword) -or (Test-AnyLike $display $disableDisplay)
        $desired = $null
        if ($isMagicWake) {
            $desired = '1'
        } elseif ($turnOff) {
            $desired = '0'
        }
        if ($null -eq $desired) { continue }
        if ([string]$property.RegistryValue -eq $desired) { continue }
        try {
            Set-NetAdapterAdvancedProperty -Name $adapter.Name -RegistryKeyword $keyword -RegistryValue $desired -NoRestart -ErrorAction Stop
            Add-Note "$($adapter.Name): $display ($keyword) = $desired"
        } catch {
            Add-Warn "$($adapter.Name): $keyword не принял $desired ($($_.Exception.Message))"
        }
    }

    $wmiMatched = $false
    try {
        $deviceId = [string]$adapter.PnPDeviceID
        $powerEnable = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue)
        foreach ($entry in $powerEnable) {
            if ($entry.InstanceName -and $deviceId -and $entry.InstanceName.Contains($deviceId)) {
                $wmiMatched = $true
                if ($entry.Enable) {
                    $entry.Enable = $false
                    Set-CimInstance -InputObject $entry -ErrorAction Stop
                    Add-Note "$($adapter.Name): снято «разрешить отключение устройства для экономии энергии»"
                } else {
                    Add-Note "$($adapter.Name): отключение устройства для экономии энергии уже снято"
                }
            }
        }
        $powerWake = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceWakeEnable -ErrorAction SilentlyContinue)
        foreach ($entry in $powerWake) {
            if ($entry.InstanceName -and $deviceId -and $entry.InstanceName.Contains($deviceId)) {
                if (-not $entry.Enable) {
                    $entry.Enable = $true
                    Set-CimInstance -InputObject $entry -ErrorAction Stop
                    Add-Note "$($adapter.Name): «разрешить устройству будить компьютер» включено"
                } else {
                    Add-Note "$($adapter.Name): пробуждение устройства уже разрешено"
                }
            }
        }
    } catch {
        Add-Warn "$($adapter.Name): WMI питания ($($_.Exception.Message))"
        $wmiMatched = $false
    }

    if (-not $wmiMatched) {
        # 8 = снять только «отключение устройства». 24 не ставить: вместе с ним гаснет пробуждение.
        $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
        $written = $false
        Get-ChildItem $classRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $netId = (Get-ItemProperty -Path $_.PSPath -Name NetCfgInstanceId -ErrorAction SilentlyContinue).NetCfgInstanceId
            $sameGuid = $netId -and $adapter.InterfaceGuid -and ($netId.Trim('{}') -eq $adapter.InterfaceGuid.ToString().Trim('{}'))
            if ($sameGuid) {
                New-ItemProperty -Path $_.PSPath -Name 'PnPCapabilities' -PropertyType DWord -Value 8 -Force | Out-Null
                $written = $true
            }
        }
        if ($written) {
            Add-Warn "$($adapter.Name): WMI не нашёл устройство, записан PnPCapabilities=8. До save сверьте галки питания NIC. Значение 24 не используется."
        } else {
            Add-Warn "$($adapter.Name): галка «отключение устройства» не записана. Снимите её вручную, пробуждение оставьте."
        }
    }

    $wakeNames = @(& powercfg.exe /devicequery wake_programmable 2>$null)
    foreach ($wakeName in $wakeNames) {
        $trim = ([string]$wakeName).Trim()
        if (-not $trim) { continue }
        if ($trim -eq $adapter.InterfaceDescription -or $trim -eq $adapter.Name) {
            & powercfg.exe /deviceenablewake $trim | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Add-Note "$($adapter.Name): powercfg wake оставлен включённым ($trim)"
            } else {
                Add-Warn "$($adapter.Name): powercfg /deviceenablewake не принял «$trim»"
            }
        }
    }
}

Section 'Дальше'
Write-Host @"

Перезагрузите эталон. Super Client не выключайте до проверки.

Перед «Выключить и сохранить»:
  powercfg /getactivescheme
  msinfo32 → безопасность на основе виртуализации не запущена; Secure Boot и TPM на месте
  Диспетчер устройств → NIC → Дополнительно: EEE и Green Ethernet выключены,
    Wake on Magic Packet включён
  Управление электропитанием: «отключение устройства» снято,
    «разрешить будить компьютер» включено
  WoL с дашборда поднимает это место после shutdown

MMCSS, SystemResponsiveness и NetworkThrottlingIndex не менялись.
Файл подкачки, Центр обновления, Защитник, звук, DHCP и оболочка шела не менялись.
"@

if ($script:Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Предупреждения: $($script:Warnings.Count)"
}
if ($script:Errors.Count -gt 0) {
    Write-Host ""
    Write-Host "Ошибки: $($script:Errors.Count)" -ForegroundColor Red
    $script:Errors | ForEach-Object { Write-Host "  $_" }
}

try { Stop-Transcript | Out-Null } catch { }

if ($script:Errors.Count -gt 0) { exit 1 }
exit 0
