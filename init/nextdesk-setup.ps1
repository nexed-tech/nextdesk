<#
.SYNOPSIS
    NextDesk - pre-registers Nextcloud apps as Edge web apps (PWA-style windows)
    via the WebAppInstallForceList enterprise policy.

.DESCRIPTION
    Writes HKLM\SOFTWARE\Policies\Microsoft\Edge\WebAppInstallForceList with one
    entry per Nextcloud app. Each entry uses a custom name and a custom icon loaded
    from the nextdesk GitHub repo. Edge installs the apps on its next policy refresh
    and creates the desktop + Start menu shortcuts itself.

    Existing non-NextDesk entries in the policy are preserved.

.EXAMPLE
    # One-liner (prompts for the Nextcloud URL):
    irm https://raw.githubusercontent.com/nexed-tech/nextdesk/main/init/nextdesk-setup.ps1 | iex

.EXAMPLE
    # One-liner with parameters:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/nexed-tech/nextdesk/main/init/nextdesk-setup.ps1))) -NextcloudUrl https://cloud.example.com

.EXAMPLE
    # Remove all NextDesk apps again:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/nexed-tech/nextdesk/main/init/nextdesk-setup.ps1))) -Uninstall
#>
param(
    # Base URL of the Nextcloud server, e.g. https://cloud.example.com
    [string]$NextcloudUrl = $env:NEXTDESK_URL,

    # Which apps to register. Also available: Deck, Forms, News.
    [string[]]$Apps = @('Calendar', 'Contacts', 'Mail', 'Notes', 'Office', 'Photos', 'Talk', 'Tasks'),

    # Prefix for the app names, e.g. "Nextcloud " -> "Nextcloud Calendar". Empty = just "Calendar".
    [string]$NamePrefix = '',

    # Don't create desktop shortcuts (Start menu entries are always created by Edge).
    [switch]$NoDesktopShortcut,

    # Don't open Edge at the end to trigger the install.
    [switch]$NoLaunch,

    # Remove all NextDesk entries from the policy (Edge then uninstalls the apps).
    [switch]$Uninstall
)

function Install-NextDesk {
    param($NextcloudUrl, $Apps, $NamePrefix, $NoDesktopShortcut, $NoLaunch, $Uninstall)

    $ErrorActionPreference = 'Stop'

    $RepoRaw   = 'https://raw.githubusercontent.com/nexed-tech/nextdesk/main'
    $ScriptUrl = "$RepoRaw/init/nextdesk-setup.ps1"
    $IconBase  = "$RepoRaw/assets/icons"
    $PolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $PolicyVal = 'WebAppInstallForceList'

    # App name -> path on the Nextcloud server + icon file in assets/icons
    $Catalog = [ordered]@{
        Calendar = @{ Path = '/apps/calendar/'; Icon = 'nextcloud-calendar.png' }
        Contacts = @{ Path = '/apps/contacts/'; Icon = 'nextcloud-contacts.png' }
        Mail     = @{ Path = '/apps/mail/';     Icon = 'nextcloud-mail.png' }
        Notes    = @{ Path = '/apps/notes/';    Icon = 'nextcloud-notes.png' }
        Office   = @{ Path = '/apps/files/';    Icon = 'nextcloud-office.png' }  # Nextcloud Office opens documents from Files
        Photos   = @{ Path = '/apps/photos/';   Icon = 'nextcloud-photos.png' }
        Talk     = @{ Path = '/apps/spreed/';   Icon = 'nextcloud-talk.png' }
        Tasks    = @{ Path = '/apps/tasks/';    Icon = 'nextcloud-tasks.png' }
        Deck     = @{ Path = '/apps/deck/';     Icon = 'nextcloud-deck.png' }
        Forms    = @{ Path = '/apps/forms/';    Icon = 'nextcloud-forms.png' }
        News     = @{ Path = '/apps/news/';     Icon = 'nextcloud-news.png' }
    }

    # --- Elevation -----------------------------------------------------------
    # HKLM policies need admin. Relaunch elevated with the same arguments.
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        if (-not $Uninstall -and -not $NextcloudUrl) {
            $NextcloudUrl = Read-Host 'Nextcloud URL (e.g. https://cloud.example.com)'
        }
        Write-Host 'Administrator rights are required - relaunching elevated...' -ForegroundColor Yellow
        $argList = @()
        if ($NextcloudUrl)      { $argList += "-NextcloudUrl '$($NextcloudUrl -replace "'", "''")'" }
        if ($Apps)              { $argList += "-Apps $(($Apps | ForEach-Object { "'$_'" }) -join ',')" }
        if ($NamePrefix)        { $argList += "-NamePrefix '$($NamePrefix -replace "'", "''")'" }
        if ($NoDesktopShortcut) { $argList += '-NoDesktopShortcut' }
        if ($NoLaunch)          { $argList += '-NoLaunch' }
        if ($Uninstall)         { $argList += '-Uninstall' }
        $source = if ($PSCommandPath) { "Get-Content -Raw '$PSCommandPath'" } else { "irm '$ScriptUrl'" }
        $command = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; " +
                   "& ([scriptblock]::Create(($source))) $($argList -join ' ')"
        Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', $command)
        return
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

    # --- Read existing policy, keep entries that aren't ours ----------------------
    # NextDesk entries are recognised by their custom_icon URL pointing at this repo,
    # so uninstall works without knowing the Nextcloud URL.
    $existing = @()
    $raw = (Get-ItemProperty -Path $PolicyKey -Name $PolicyVal -ErrorAction SilentlyContinue).$PolicyVal
    if ($raw) {
        try {
            foreach ($e in (ConvertFrom-Json $raw)) { $existing += $e }
        } catch {
            throw "Existing $PolicyVal policy is not valid JSON - fix or remove it first:`n$raw"
        }
    }
    $isOurs = { param($e) $e.custom_icon -and "$($e.custom_icon.url)".StartsWith($IconBase) }
    $kept   = @($existing | Where-Object { -not (& $isOurs $_) })

    if ($Uninstall) {
        $removed = $existing.Count - $kept.Count
        if ($kept.Count -gt 0) {
            Set-ItemProperty -Path $PolicyKey -Name $PolicyVal -Value (ConvertTo-Json -InputObject $kept -Depth 5 -Compress)
        } elseif ($raw) {
            Remove-ItemProperty -Path $PolicyKey -Name $PolicyVal
        }
        Write-Host "Removed $removed NextDesk app(s) from the Edge policy." -ForegroundColor Green
        Write-Host 'Edge will uninstall them (and their shortcuts) on its next policy refresh or restart.'
        return
    }

    # --- Build NextDesk entries ---------------------------------------------------
    if (-not $NextcloudUrl) { $NextcloudUrl = Read-Host 'Nextcloud URL (e.g. https://cloud.example.com)' }
    $NextcloudUrl = $NextcloudUrl.Trim().TrimEnd('/')
    if ($NextcloudUrl -notmatch '^https?://') { $NextcloudUrl = "https://$NextcloudUrl" }

    $unknown = @($Apps | Where-Object { -not $Catalog.Contains($_) })
    if ($unknown) { throw "Unknown app(s): $($unknown -join ', '). Valid: $($Catalog.Keys -join ', ')" }

    $tmp = Join-Path $env:TEMP "nextdesk-$([guid]::NewGuid().ToString('N')).png"
    $entries = @()
    try {
        foreach ($name in $Apps) {
            $app     = $Catalog[$name]
            $iconUrl = "$IconBase/$($app.Icon)"
            # Edge requires the SHA-256 of the icon; compute it from the actual file.
            Invoke-WebRequest -Uri $iconUrl -OutFile $tmp -UseBasicParsing
            $hash = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLower()

            # install_as_shortcut: Nextcloud serves the same manifest scope for every
            # app, so installing them as "real" PWAs would collapse them into one.
            # A shortcut app still opens in its own window with our name + icon.
            $entries += [ordered]@{
                url                      = "$NextcloudUrl$($app.Path)"
                default_launch_container = 'window'
                install_as_shortcut      = $true
                create_desktop_shortcut  = -not $NoDesktopShortcut
                custom_name              = "$NamePrefix$name"
                custom_icon              = [ordered]@{ url = $iconUrl; hash = $hash }
            }
            Write-Host ("  + {0,-10} {1}" -f $name, "$NextcloudUrl$($app.Path)")
        }
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }

    # --- Write policy ---------------------------------------------------------------
    $all = @($kept) + @($entries)
    if (-not (Test-Path $PolicyKey)) { New-Item -Path $PolicyKey -Force | Out-Null }
    Set-ItemProperty -Path $PolicyKey -Name $PolicyVal -Type String -Value (ConvertTo-Json -InputObject $all -Depth 5 -Compress)

    Write-Host ''
    Write-Host "Registered $($entries.Count) NextDesk app(s) in $PolicyKey\$PolicyVal" -ForegroundColor Green
    if ($kept.Count) { Write-Host "Kept $($kept.Count) existing non-NextDesk entr$(if ($kept.Count -eq 1) {'y'} else {'ies'})." }
    Write-Host 'Edge installs the apps and creates desktop + Start menu shortcuts on its next policy refresh.'
    Write-Host 'Check progress at edge://policy and edge://apps.'

    # --- Kick Edge ------------------------------------------------------------------
    # Launch via explorer.exe so Edge runs de-elevated as the logged-in user, opening
    # Nextcloud so the user can sign in (the apps share Edge's session cookie).
    if (-not $NoLaunch) {
        Start-Process explorer.exe -ArgumentList "microsoft-edge:$NextcloudUrl/"
    }
}

Install-NextDesk -NextcloudUrl $NextcloudUrl -Apps $Apps -NamePrefix $NamePrefix `
    -NoDesktopShortcut $NoDesktopShortcut -NoLaunch $NoLaunch -Uninstall $Uninstall
