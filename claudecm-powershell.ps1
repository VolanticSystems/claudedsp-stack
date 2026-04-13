function claudecm {
    $cmDir = "$env:USERPROFILE\.claudecm"
    $sessionsFile = "$cmDir\sessions.txt"
    $machineNameFile = "$cmDir\machine-name.txt"
    $claudeExe = "$env:USERPROFILE\.local\bin\claude.exe"
    $cmvExe = "$env:APPDATA\npm\cmv.cmd"
    $env:CLAUDE_CODE_REMOTE_SEND_KEEPALIVES = "1"

    function Ensure-CleanupPeriodDays {
        $settingsPath = "$env:USERPROFILE\.claude\settings.json"
        if (-not (Test-Path $settingsPath)) { return }
        try {
            $raw = Get-Content $settingsPath -Raw
            $settings = $raw | ConvertFrom-Json
            $current = $settings.cleanupPeriodDays
            if (-not $current -or $current -lt 1000) {
                # Back up
                $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
                $backupDir = "$env:USERPROFILE\.claudecm\backup"
                if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
                Copy-Item $settingsPath "$backupDir\settings.json.$ts" -ErrorAction SilentlyContinue
                # Set to 100000 (preserves transcripts for ~274 years; NOT 0, which disables persistence)
                $settings | Add-Member -NotePropertyName 'cleanupPeriodDays' -NotePropertyValue 100000 -Force
                $settings | ConvertTo-Json -Depth 20 | Set-Content $settingsPath -Encoding UTF8
                Write-Host "  Protected session transcripts from Claude Code's 30-day auto-delete." -ForegroundColor Cyan
            }
        } catch {
            # Silent - never block ClaudeCM on settings issues
        }
    }
    Ensure-CleanupPeriodDays

    if (-not (Test-Path $cmDir)) { New-Item -ItemType Directory -Path $cmDir | Out-Null }
    if (-not (Test-Path $sessionsFile)) { New-Item -ItemType File -Path $sessionsFile | Out-Null }

    # Auto-backup sessions.txt on every launch (best-effort, silent).
    # Keeps a rolling history so a buggy or destructive operation can always be rolled back.
    # Retains the most recent 20 backups; older ones are pruned.
    try {
        $backupDir = "$cmDir\backup"
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        if ((Get-Item $sessionsFile -ErrorAction SilentlyContinue).Length -gt 0) {
            $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
            Copy-Item $sessionsFile "$backupDir\sessions.txt.$ts" -ErrorAction SilentlyContinue
            $oldBackups = @(Get-ChildItem "$backupDir\sessions.txt.*" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -Skip 20)
            foreach ($b in $oldBackups) { Remove-Item $b.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch {}

    # Machine name: prompt on first use
    if (-not (Test-Path $machineNameFile)) {
        Write-Host ""
        $mn = Read-Host "  Machine name for remote display (e.g. desktop, laptop)"
        if (-not $mn) { $mn = $env:COMPUTERNAME.ToLower() }
        $mn | Set-Content $machineNameFile
        Write-Host "  Saved: $mn"
    }
    $machineName = (Get-Content $machineNameFile -ErrorAction SilentlyContinue).Trim()
    if (-not $machineName) { $machineName = $env:COMPUTERNAME.ToLower() }

    function Get-SessionDisplayName($desc) {
        return "$machineName - $desc"
    }

    function Parse-SessionLine($line) {
        $parts = $line -split '\|', 4
        $tokens = ""; if ($parts.Count -ge 4) { $tokens = $parts[3] }
        return [PSCustomObject]@{ Guid=$parts[0]; Dir=$parts[1]; Desc=$parts[2]; Tokens=$tokens }
    }

    function Get-Sessions {
        $lines = Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' }
        $sessions = @()
        foreach ($line in $lines) {
            if ($line.Trim() -eq '[archived]') { break }
            $sessions += Parse-SessionLine $line
        }
        return $sessions
    }

    function Get-ArchivedSessions {
        $lines = Get-Content $sessionsFile | Where-Object { $_.Trim() -ne '' }
        $sessions = @()
        $inArchived = $false
        foreach ($line in $lines) {
            if ($line.Trim() -eq '[archived]') { $inArchived = $true; continue }
            if ($inArchived) { $sessions += Parse-SessionLine $line }
        }
        return $sessions
    }

    function Acquire-SessionsLock {
        # Returns a FileStream holding an exclusive lock on sessions.txt.lock.
        # Retries for up to 10 seconds. Returns $null on timeout.
        $lockPath = "$sessionsFile.lock"
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline) {
            try {
                $fs = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
                return $fs
            } catch {
                Start-Sleep -Milliseconds 200
            }
        }
        Write-Host "  [warning] Could not acquire sessions.txt lock after 10s; another ClaudeCM operation may be running. Proceeding without lock." -ForegroundColor Yellow
        return $null
    }

    function Release-SessionsLock($lock) {
        if ($lock) {
            try { $lock.Close(); $lock.Dispose() } catch {}
        }
    }

    function Write-SessionsAtomic($lines) {
        # Write to temp file, then atomic rename. Survives partial-write crashes.
        $tmp = "$sessionsFile.tmp"
        $lines | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $sessionsFile -Force
    }

    function Save-Sessions($sessions) {
        $lock = Acquire-SessionsLock
        try {
            $archived = Get-ArchivedSessions
            $lines = @($sessions | ForEach-Object { "$($_.Guid)|$($_.Dir)|$($_.Desc)|$($_.Tokens)" })
            if ($archived.Count -gt 0) {
                $lines += '[archived]'
                $lines += @($archived | ForEach-Object { "$($_.Guid)|$($_.Dir)|$($_.Desc)|$($_.Tokens)" })
            }
            Write-SessionsAtomic $lines
        } finally { Release-SessionsLock $lock }
    }

    function Save-ArchivedSessions($archivedSessions) {
        $lock = Acquire-SessionsLock
        try {
        $main = Get-Sessions
        $lines = @($main | ForEach-Object { "$($_.Guid)|$($_.Dir)|$($_.Desc)|$($_.Tokens)" })
        if ($archivedSessions.Count -gt 0) {
            $lines += '[archived]'
            $lines += @($archivedSessions | ForEach-Object { "$($_.Guid)|$($_.Dir)|$($_.Desc)|$($_.Tokens)" })
        }
        Write-SessionsAtomic $lines
        } finally { Release-SessionsLock $lock }
    }

    function Sync-SessionIndex($projectDir) {
        # Validates and repairs Claude Code's sessions-index.json for a project directory.
        # Removes entries for deleted JSONL files, adds entries for unindexed ones,
        # and creates the index from scratch if missing. Best-effort; never blocks on failure.
        try {
            $projKey = Get-ProjectKey $projectDir
            $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
            if (-not (Test-Path $projDirClaude)) { return }

            $uuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            $jsonlFiles = @(Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -match $uuidPattern })
            if ($jsonlFiles.Count -eq 0) { return }

            $indexPath = Join-Path $projDirClaude "sessions-index.json"
            $existingEntries = @()
            $originalPath = $projectDir

            if (Test-Path $indexPath) {
                try {
                    $indexData = Get-Content $indexPath -Raw | ConvertFrom-Json
                    $existingEntries = @($indexData.entries)
                    if ($indexData.originalPath) { $originalPath = $indexData.originalPath }
                } catch { $existingEntries = @() }
            }

            # Build lookup of GUIDs on disk
            $diskGuids = @{}
            foreach ($f in $jsonlFiles) { $diskGuids[$f.BaseName] = $f }

            # Keep only entries whose files still exist; update their mtime
            $validEntries = @()
            foreach ($entry in $existingEntries) {
                if ($diskGuids.ContainsKey($entry.sessionId)) {
                    $f = $diskGuids[$entry.sessionId]
                    $entry.fileMtime = [long]($f.LastWriteTimeUtc - [datetime]'1970-01-01').TotalMilliseconds
                    $entry.modified = $f.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                    $validEntries += $entry
                }
            }

            $indexedGuids = @{}
            foreach ($entry in $validEntries) { $indexedGuids[$entry.sessionId] = $true }

            # Add entries for unindexed files
            $sessions = Get-Sessions
            $newEntries = @()
            foreach ($guid in $diskGuids.Keys) {
                if (-not $indexedGuids.ContainsKey($guid)) {
                    $f = $diskGuids[$guid]
                    $mtime = [long]($f.LastWriteTimeUtc - [datetime]'1970-01-01').TotalMilliseconds
                    $created = $f.CreationTimeUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                    $modified = $f.LastWriteTimeUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                    $sessMatch = $sessions | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
                    $firstPrompt = ""; $projPath = $projectDir
                    if ($sessMatch) {
                        $firstPrompt = $sessMatch.Desc
                        $projPath = $sessMatch.Dir
                    }
                    $newEntries += @{
                        sessionId = $guid
                        fullPath = $f.FullName
                        fileMtime = $mtime
                        firstPrompt = $firstPrompt
                        messageCount = 0
                        created = $created
                        modified = $modified
                        gitBranch = ""
                        projectPath = $projPath
                        isSidechain = $false
                    }
                }
            }

            $allEntries = @($validEntries) + @($newEntries)
            $indexObj = @{ version = 1; entries = $allEntries; originalPath = $originalPath }
            $indexObj | ConvertTo-Json -Depth 10 | Set-Content $indexPath -Encoding UTF8
        } catch {
            # Best-effort: never block ClaudeCM operations on index sync failure
        }
    }

    function Get-ProjectKey($dir) {
        # Claude Code encoding: every non-alphanumeric char becomes a dash
        return ($dir -replace '[^a-zA-Z0-9]', '-')
    }

    function Format-Tokens($tokens) {
        if (-not $tokens -or $tokens -eq '') { return "--" }
        $t = [int]$tokens
        if ($t -ge 1000000) { return "{0:N1}M tok" -f ($t / 1000000) }
        if ($t -ge 1000) { return "{0:N0}K tok" -f ($t / 1000) }
        return "$t tok"
    }

    function Format-Size($bytes) {
        if ($bytes -ge 1MB) { return "{0:N1} MB" -f ($bytes / 1MB) }
        if ($bytes -ge 1KB) { return "{0:N0} KB" -f ($bytes / 1KB) }
        return "$bytes B"
    }

    function Format-DateShort($dt) {
        if ($dt.Year -lt (Get-Date).Year) { return $dt.ToString("MMM d, yyyy") }
        return $dt.ToString("MMM d")
    }

    function Get-SessionInfo($guid, $dir, $tokens) {
        $projKey = Get-ProjectKey $dir
        $projDir = "$env:USERPROFILE\.claude\projects\$projKey"
        $jsonl = "$projDir\$guid.jsonl"
        $tokStr = Format-Tokens $tokens

        if (Test-Path $jsonl) {
            $item = Get-Item $jsonl
            return [PSCustomObject]@{
                Size = Format-Size $item.Length
                Date = Format-DateShort $item.LastWriteTime
                Tokens = $tokStr
                Status = 'ok'
            }
        }

        # JSONL missing - try fallbacks for date
        $fallbackDate = $null
        $guidSubdir = "$projDir\$guid"
        $memoryDir = "$projDir\memory"
        if (Test-Path $guidSubdir) { $fallbackDate = (Get-Item $guidSubdir).LastWriteTime }
        elseif (Test-Path $memoryDir) { $fallbackDate = (Get-Item $memoryDir).LastWriteTime }
        else {
            $indexPath = "$projDir\sessions-index.json"
            if (Test-Path $indexPath) {
                try {
                    $idx = Get-Content $indexPath -Raw | ConvertFrom-Json
                    $entry = $idx.entries | Where-Object { $_.sessionId -eq $guid } | Select-Object -First 1
                    if ($entry -and $entry.created) { $fallbackDate = [DateTime]$entry.created }
                } catch {}
            }
        }

        $dateStr = "--"
        if ($fallbackDate) { $dateStr = (Format-DateShort $fallbackDate) + "*" }

        return [PSCustomObject]@{
            Size = "(missing)"
            Date = $dateStr
            Tokens = $tokStr
            Status = 'missing'
        }
    }

    function Build-RecoveryMetaPrompt($dir, $desc, $tokens, $lastDate) {
        $projKey = Get-ProjectKey $dir
        $projDir = "$env:USERPROFILE\.claude\projects\$projKey"
        $memoryDir = "$projDir\memory"
        $subagentsDir = "$projDir\$($script:lastGuid)\subagents"

        $memoryFiles = @()
        if (Test-Path $memoryDir) {
            $memoryFiles = Get-ChildItem "$memoryDir\*.md" -ErrorAction SilentlyContinue |
                ForEach-Object { "  * $($_.Name) ($([math]::Round($_.Length/1024)) KB, modified $($_.LastWriteTime.ToString('yyyy-MM-dd')))" }
        }
        $memoryList = if ($memoryFiles.Count -gt 0) { $memoryFiles -join "`n" } else { "  (none)" }

        $subagentCount = 0
        $subagentLatest = "unknown"
        if (Test-Path $subagentsDir) {
            $agents = @(Get-ChildItem "$subagentsDir\*.jsonl" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            $subagentCount = $agents.Count
            if ($agents.Count -gt 0) { $subagentLatest = $agents[0].LastWriteTime.ToString('yyyy-MM-dd') }
        }

        $tokStr = if ($tokens) { "$tokens tokens" } else { "unknown token count" }
        $dateStr = if ($lastDate) { $lastDate } else { "unknown" }

        return @"
Context: a Claude Code session was deleted. You need to produce orientation text for a future Claude Code session that will read this text as its first input. Produce the text. That text goes directly into the next session. It is NOT a summary, NOT a description, NOT a report about what you did. It is the directives themselves.

Read these artifacts:
* Memory files in ${memoryDir}
* Subagent transcripts in ${subagentsDir} (2-3 most recent; total on disk: $subagentCount, latest dated $subagentLatest)
* The project code at $dir

Session metadata (for reference when you write):
* Session name: $desc
* Project path: $dir
* Last activity: $dateStr
* Conversation size when lost: $tokStr

Now replace every <PLACEHOLDER> below and OUTPUT the completed template. Start your output with "This is a recovery session." and end with "ask before assuming." Output nothing else. No preamble, no confirmation, no summary of what you did.

This is a recovery session. The previous conversation transcript for "$desc" was deleted. The project lives at $dir. Memory, subagent state, and source code all survived.

Read these files in this order:

<NUMBERED LIST. Format: "1. <filename>: <one-line description of what this file contains, based on what you read in it>". Use actual file paths from the memory directory.>

Then skim these subagent transcripts for context on in-flight work:

<BULLETED LIST using "*" not "-". Format: "* <filename>: <what this subagent was doing>". Use 2-3 of the most recently modified subagent transcripts. If there are zero subagent transcripts, replace this whole list with the single line: "No surviving subagent transcripts.">

Open questions or in-flight work visible from the artifacts:

<BULLETED LIST using "*" not "-". One line per item. If nothing specific is identifiable, replace this whole list with: "None identified from the artifacts.">

Read these in order. Do not run builds, tests, or git commands yet. Do not modify any files. After reading, report back with: (1) your understanding of project state as of the last captured activity, (2) what appears to have been in progress, (3) what you recommend doing next. Do not invent details. If something is unclear, ask before assuming.
"@
    }

    function Resolve-ResumeOrRecover($guid, $dir, $desc, $tokens) {
        $projKey = Get-ProjectKey $dir
        $jsonl = "$env:USERPROFILE\.claude\projects\$projKey\$guid.jsonl"
        if (Test-Path $jsonl) {
            return [PSCustomObject]@{ Action='normal'; Guid=$guid }
        }

        Write-Host ""
        Write-Host "  The conversation transcript for '$desc' has been lost." -ForegroundColor Yellow
        Write-Host "  Probably due to Claude Code's 30-day auto-cleanup."
        Write-Host "  Memory files and subagent state are intact."
        Write-Host ""
        Write-Host "  You have three options:"
        Write-Host "    1. Start a fresh Claude session in that directory"
        Write-Host "    2. Create a recovery-prompt.md file in the project directory, that you can prompt Claude to read and execute, with optional edits."
        Write-Host "    3. Cancel"
        Write-Host ""
        $choice = Read-Host "  > "

        switch ($choice) {
            '1' { return [PSCustomObject]@{ Action='fresh'; Guid=$null } }
            '3' { return [PSCustomObject]@{ Action='cancel'; Guid=$null } }
            '2' {
                if (-not (Test-Path $dir)) {
                    Write-Host "  Project directory not found: $dir" -ForegroundColor Red
                    return [PSCustomObject]@{ Action='cancel'; Guid=$null }
                }
                # Rotate existing recovery-prompt.md files: current -> .old, .old -> .old2, etc.
                $primaryPath = Join-Path $dir "recovery-prompt.md"
                if (Test-Path $primaryPath) {
                    # Find highest .oldN suffix
                    $existing = Get-ChildItem $dir -Filter "recovery-prompt.md.old*" -ErrorAction SilentlyContinue
                    $maxN = 1
                    foreach ($f in $existing) {
                        if ($f.Name -match 'recovery-prompt\.md\.old(\d+)$') {
                            $n = [int]$Matches[1]
                            if ($n -ge $maxN) { $maxN = $n + 1 }
                        }
                    }
                    # Shift .old -> .old(N+1), .old(N) -> .old(N+1), etc.
                    $toRotate = @($existing) | Sort-Object {
                        if ($_.Name -match 'recovery-prompt\.md\.old(\d+)$') { [int]$Matches[1] } else { 1 }
                    } -Descending
                    foreach ($f in $toRotate) {
                        $n = 1
                        if ($f.Name -match 'recovery-prompt\.md\.old(\d+)$') { $n = [int]$Matches[1] }
                        $newName = "recovery-prompt.md.old$($n + 1)"
                        try { Rename-Item $f.FullName $newName -Force -ErrorAction Stop } catch {}
                    }
                    try { Rename-Item $primaryPath "recovery-prompt.md.old" -Force -ErrorAction Stop } catch {}
                }

                Write-Host ""
                Write-Host "  Generating recovery prompt (this may take a minute)..." -ForegroundColor Cyan
                $script:lastGuid = $guid
                $info = Get-SessionInfo $guid $dir $tokens
                $metaPrompt = Build-RecoveryMetaPrompt $dir $desc $tokens $info.Date

                $origLoc = Get-Location
                try {
                    Set-Location $dir
                    $tmpFile = [System.IO.Path]::GetTempFileName()
                    $metaPrompt | Out-File -FilePath $tmpFile -Encoding UTF8
                    $primerJson = Get-Content $tmpFile -Raw | & $claudeExe -p --output-format json --dangerously-skip-permissions 2>$null
                    Remove-Item $tmpFile -ErrorAction SilentlyContinue
                    $primerData = $primerJson | ConvertFrom-Json
                    $recoveryPrompt = $primerData.result
                    # Capture and clean up the throwaway JSONL the -p call created
                    $primerSessionId = $primerData.session_id
                    if ($primerSessionId) {
                        $primerProjKey = Get-ProjectKey (Get-Location).Path
                        $primerJsonl = "$env:USERPROFILE\.claude\projects\$primerProjKey\$primerSessionId.jsonl"
                        if (Test-Path $primerJsonl) { Remove-Item $primerJsonl -Force -ErrorAction SilentlyContinue }
                        $primerSubdir = "$env:USERPROFILE\.claude\projects\$primerProjKey\$primerSessionId"
                        if (Test-Path $primerSubdir) { Remove-Item $primerSubdir -Recurse -Force -ErrorAction SilentlyContinue }
                        Sync-SessionIndex (Get-Location).Path
                    }
                    if (-not $recoveryPrompt) {
                        Write-Host "  Recovery prompt generation failed." -ForegroundColor Red
                        return [PSCustomObject]@{ Action='cancel'; Guid=$null }
                    }
                    $recoveryPrompt | Out-File -FilePath $primaryPath -Encoding UTF8
                    Write-Host ""
                    Write-Host "  Recovery prompt saved to:" -ForegroundColor Green
                    Write-Host "    $primaryPath"
                    Write-Host ""
                    Write-Host "  Edit it if you want, or just tell Claude to use it as the first message of the conversation."
                    Write-Host "  Opening a fresh Claude session in that directory now..." -ForegroundColor Cyan
                    Write-Host ""
                    return [PSCustomObject]@{ Action='fresh'; Guid=$null }
                } catch {
                    Write-Host "  Recovery prompt generation error: $_" -ForegroundColor Red
                    return [PSCustomObject]@{ Action='cancel'; Guid=$null }
                } finally {
                    Set-Location $origLoc
                }
            }
            default { return [PSCustomObject]@{ Action='cancel'; Guid=$null } }
        }
    }

    function Show-List($sessions, [int]$highlight = 0) {
        Write-Host ""
        Write-Host "  === Saved Sessions ==="
        Write-Host ""
        $maxDesc = 0
        foreach ($s in $sessions) { if ($s.Desc.Length -gt $maxDesc) { $maxDesc = $s.Desc.Length } }
        $maxDesc = [Math]::Max($maxDesc, 10)
        $numWidth = "$($sessions.Count)".Length
        for ($i = 0; $i -lt $sessions.Count; $i++) {
            $info = Get-SessionInfo $sessions[$i].Guid $sessions[$i].Dir $sessions[$i].Tokens
            $num = "$($i+1).".PadRight($numWidth + 2)
            $desc = $sessions[$i].Desc.PadRight($maxDesc + 2)
            $sizeStr = $info.Size.PadLeft(9)
            $tokStr = $info.Tokens.PadLeft(10)
            $dateStr = $info.Date
            $pathStr = $sessions[$i].Dir
            $line = "  $num $desc $sizeStr  $tokStr   $dateStr`t$pathStr"
            if ($highlight -eq ($i + 1)) {
                Write-Host "  *** $num $desc $sizeStr  $tokStr   $dateStr`t$pathStr  [Selected] ***" -ForegroundColor Yellow
            } else {
                Write-Host $line
            }
        }
        Write-Host ""
        $archivedCount = @(Get-ArchivedSessions).Count
        Write-Host "  E. Edit this list"
        if ($archivedCount -gt 0) { Write-Host "  V. View archived ($archivedCount)" }
        Write-Host "  M. Machine name ($machineName)"
    }

    function Do-OrphanScan($scanDir, $registeredGuid) {
        $sessions = @(Get-Sessions) + @(Get-ArchivedSessions)
        $projKey = Get-ProjectKey $scanDir
        $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
        $allJsonl = @()
        if (Test-Path $projDirClaude) {
            $allJsonl = @(Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        }
        if ($allJsonl.Count -le 1) { return $null }
        # Check if any files are actually problematic (orphan or wrong directory)
        $hasProblems = $false
        foreach ($f in $allJsonl) {
            $guid = $f.BaseName
            $sessMatch = $sessions | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
            if (-not $sessMatch) { $hasProblems = $true; break }
            if ($sessMatch.Dir -ne $scanDir) { $hasProblems = $true; break }
        }
        if (-not $hasProblems) { return $null }
        $backupDir = "$env:USERPROFILE\documents\github\claude-conversation-backup"
        Write-Host ""
        Write-Host "  Multiple conversation files found ($($allJsonl.Count)):" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  #   Last Modified          Size     Session Name"
        Write-Host "  --- --------------------  --------  ---------------------------"
        for ($ci = 0; $ci -lt $allJsonl.Count; $ci++) {
            $f = $allJsonl[$ci]
            $guid = $f.BaseName
            $sizeBytes = $f.Length
            $sizeStr = ""
            if ($sizeBytes -ge 1MB) { $sizeStr = "{0:N1} MB" -f ($sizeBytes / 1MB) }
            elseif ($sizeBytes -ge 1KB) { $sizeStr = "{0:N0} KB" -f ($sizeBytes / 1KB) }
            else { $sizeStr = "$sizeBytes B" }
            $dateStr = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
            $sessMatch = $sessions | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
            $nameStr = "(orphan)"
            if ($sessMatch) {
                $nameStr = $sessMatch.Desc
                if ($sessMatch.Dir -ne $scanDir) { $nameStr += " (wrong directory)" }
            }
            $marker = ""
            if ($guid -eq $registeredGuid) { $marker = " *" }
            $sizeStr = $sizeStr.PadLeft(8)
            Write-Host ("  {0,-4} {1}  {2}  {3}{4}" -f "$($ci+1).", $dateStr, $sizeStr, $nameStr, $marker)
        }
        Write-Host ""
        Write-Host "  * = registered session for this directory"
        Write-Host ""
        Write-Host "  Actions: [number] to select, [q number] to quarantine to backup, [Enter] to continue with registered session"
        $orphanCmd = Read-Host "  >"
        if ($orphanCmd -match '^\d+$') {
            $idx = [int]$orphanCmd - 1
            if ($idx -ge 0 -and $idx -lt $allJsonl.Count) {
                return @{ Action='select'; Guid=$allJsonl[$idx].BaseName }
            } else { Write-Host "  Invalid number." }
        }
        elseif ($orphanCmd -match '^[qQ]\s*(\d+)$') {
            $idx = [int]$Matches[1] - 1
            if ($idx -ge 0 -and $idx -lt $allJsonl.Count) {
                $f = $allJsonl[$idx]
                $guid = $f.BaseName
                if ($guid -eq $registeredGuid) {
                    Write-Host "  Cannot quarantine the registered session." -ForegroundColor Red
                } else {
                    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
                    $destSubdir = Join-Path $backupDir (Split-Path $scanDir -Leaf)
                    if (-not (Test-Path $destSubdir)) { New-Item -ItemType Directory -Path $destSubdir -Force | Out-Null }
                    Move-Item $f.FullName (Join-Path $destSubdir $f.Name)
                    $guidDir = Join-Path $projDirClaude $guid
                    if (Test-Path $guidDir) { Move-Item $guidDir (Join-Path $destSubdir $guid) }
                    Sync-SessionIndex $scanDir
                    Write-Host "  Quarantined to backup: $(Split-Path $scanDir -Leaf)\$guid" -ForegroundColor Green
                }
            } else { Write-Host "  Invalid number." }
        }
        return $null
    }

    function Do-DeleteSession($guid, $dir) {
        # Destructive delete: removes JSONL, associated subdirectory, and sessions-index entry
        $projKey = Get-ProjectKey $dir
        $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
        $jsonlFile = Join-Path $projDirClaude "$guid.jsonl"
        $guidDir = Join-Path $projDirClaude $guid
        if (Test-Path $jsonlFile) { Remove-Item $jsonlFile -Force }
        if (Test-Path $guidDir) { Remove-Item $guidDir -Recurse -Force }
        Sync-SessionIndex $dir
    }

    function Do-ViewArchived {
        while ($true) {
            $archived = Get-ArchivedSessions
            if ($archived.Count -eq 0) {
                Write-Host ""
                Write-Host "  No archived sessions."
                return
            }
            Write-Host ""
            Write-Host "  === Archived Sessions ==="
            Write-Host ""
            for ($i = 0; $i -lt $archived.Count; $i++) {
                $info = Get-SessionInfo $archived[$i].Guid $archived[$i].Dir $archived[$i].Tokens
                Write-Host "  $($i+1). $($archived[$i].Desc)  [$($archived[$i].Dir)]  $($info.Size)"
            }
            Write-Host ""
            Write-Host "  U# = Unarchive   D# = Delete permanently   Q = Back"
            Write-Host ""
            $cmd = Read-Host "  >"
            if (-not $cmd -or $cmd -eq 'q' -or $cmd -eq 'Q') { return }
            if ($cmd -match '^[uU](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $archived.Count) {
                    $entry = $archived[$idx]
                    $archived = @($archived | Where-Object { $_ -ne $entry })
                    Save-ArchivedSessions $archived
                    $sessions = Get-Sessions
                    $sessions = @($entry) + @($sessions)
                    Save-Sessions $sessions
                    Write-Host "  Unarchived: $($entry.Desc)" -ForegroundColor Green
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[dD](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $archived.Count) {
                    Write-Host "  This permanently deletes the conversation file and all associated data." -ForegroundColor Red
                    Write-Host "  This cannot be undone." -ForegroundColor Red
                    $confirm = Read-Host "  Type 'delete' to confirm"
                    if ($confirm -match '^delete$') {
                        $entry = $archived[$idx]
                        Do-DeleteSession $entry.Guid $entry.Dir
                        $archived = @($archived | Where-Object { $_ -ne $entry })
                        Save-ArchivedSessions $archived
                        Write-Host "  Deleted: $($entry.Desc)" -ForegroundColor Green
                    } else { Write-Host "  Cancelled." }
                } else { Write-Host "  Invalid number." }
            }
            else { Write-Host "  Unknown command." }
        }
    }

    function Do-EditList {
        while ($true) {
            $sessions = Get-Sessions
            Write-Host ""
            Write-Host "  === Edit Sessions ==="
            Write-Host ""
            for ($i = 0; $i -lt $sessions.Count; $i++) {
                Write-Host "  $($i+1). $($sessions[$i].Desc)  [$($sessions[$i].Dir)]"
            }
            Write-Host ""
            Write-Host "  R# = Rename   P# = Path   A# = Archive   D# = Delete   M#,# = Move   Q = Done"
            Write-Host ""
            $cmd = Read-Host "  >"
            if (-not $cmd -or $cmd -eq 'q' -or $cmd -eq 'Q') { return }
            if ($cmd -match '^[rR](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $sessions.Count) {
                    $newName = Read-Host "  New name for '$($sessions[$idx].Desc)'"
                    if ($newName) {
                        $sessions[$idx].Desc = $newName
                        Save-Sessions $sessions
                    }
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[pP](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $sessions.Count) {
                    Write-Host "  Current: $($sessions[$idx].Dir)"
                    $newPath = Read-Host "  New path (Enter to keep)"
                    if ($newPath) {
                        if (-not (Test-Path $newPath)) {
                            Write-Host "  Path does not exist: $newPath"
                            continue
                        }
                        $guid = $sessions[$idx].Guid
                        $oldPath = $sessions[$idx].Dir
                        $oldKey = Get-ProjectKey $oldPath
                        $newKey = Get-ProjectKey $newPath
                        $claudeProj = "$env:USERPROFILE\.claude\projects"
                        $oldFile = "$claudeProj\$oldKey\$guid.jsonl"
                        $newDir = "$claudeProj\$newKey"
                        $newFile = "$newDir\$guid.jsonl"
                        if (Test-Path $oldFile) {
                            if (-not (Test-Path $newDir)) { New-Item -ItemType Directory -Path $newDir -Force | Out-Null }
                            Copy-Item $oldFile $newFile
                            Write-Host "  Session file copied to new project directory."
                        } else {
                            Write-Host "  Warning: Session file not found at old path. Resume may not work."
                        }
                        $sessions[$idx].Dir = $newPath
                        Save-Sessions $sessions
                        Sync-SessionIndex $newPath
                        Sync-SessionIndex $oldPath
                    }
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[aA](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $sessions.Count) {
                    $entry = $sessions[$idx]
                    $sessions = @($sessions | Where-Object { $_ -ne $entry })
                    Save-Sessions $sessions
                    $archived = Get-ArchivedSessions
                    $archived = @($archived) + @($entry)
                    Save-ArchivedSessions $archived
                    Write-Host "  Archived: $($entry.Desc)" -ForegroundColor Green
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[dD](\d+)$') {
                $idx = [int]$Matches[1] - 1
                if ($idx -ge 0 -and $idx -lt $sessions.Count) {
                    Write-Host "  This permanently deletes the conversation file and all associated data." -ForegroundColor Red
                    Write-Host "  This cannot be undone." -ForegroundColor Red
                    $confirm = Read-Host "  Type 'delete' to confirm"
                    if ($confirm -match '^delete$') {
                        $entry = $sessions[$idx]
                        Do-DeleteSession $entry.Guid $entry.Dir
                        $sessions = @($sessions | Where-Object { $_ -ne $entry })
                        Save-Sessions $sessions
                        Write-Host "  Deleted: $($entry.Desc)" -ForegroundColor Green
                    } else { Write-Host "  Cancelled." }
                } else { Write-Host "  Invalid number." }
            }
            elseif ($cmd -match '^[mM](\d+),(\d+)$') {
                $from = [int]$Matches[1] - 1
                $to = [int]$Matches[2] - 1
                if ($from -ge 0 -and $from -lt $sessions.Count -and $to -ge 0 -and $to -lt $sessions.Count) {
                    $item = $sessions[$from]
                    $list = [System.Collections.ArrayList]@($sessions)
                    $list.RemoveAt($from)
                    $list.Insert($to, $item)
                    $sessions = @($list)
                    Save-Sessions $sessions
                } else { Write-Host "  Invalid numbers." }
            }
            else { Write-Host "  Unknown command." }
        }
    }

    function Do-Trim($currentGuid) {
        if (-not (Test-Path $cmvExe)) {
            Write-Host "  cmv not found. Skipping trim."
            return
        }
        # Pre-trim: clean up stale .cmv-trim-tmp files (older than 5 minutes) in the current
        # project's dir. These are leftovers from prior failed CMV trims.
        $sessions = Get-Sessions
        $entry = $sessions | Where-Object { $_.Guid -eq $currentGuid } | Select-Object -First 1
        if ($entry) {
            $projKey = Get-ProjectKey $entry.Dir
            $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
            if (Test-Path $projDirClaude) {
                $cutoff = (Get-Date).AddMinutes(-5)
                Get-ChildItem "$projDirClaude\*.cmv-trim-tmp" -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoff } |
                    ForEach-Object {
                        Write-Host "  Cleaned stale CMV temp file: $($_.Name)" -ForegroundColor DarkGray
                        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    }
            }
        }
        Write-Host "  Trimming session..."
        $trimStartedAt = Get-Date
        $trimOutput = & $cmvExe trim -s $currentGuid --skip-launch 2>&1 | Out-String
        $guidMatch = [regex]::Match($trimOutput, 'Session ID:\s*([0-9a-f-]+)')
        if (-not $guidMatch.Success) {
            Write-Host "  Trim failed or no new session ID found."
            $trimOutput.Split("`n") | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
            return
        }
        $newGuid = $guidMatch.Groups[1].Value
        # Update GUID in sessions.txt
        $sessions = Get-Sessions
        foreach ($s in $sessions) {
            if ($s.Guid -eq $currentGuid) { $s.Guid = $newGuid }
        }
        Save-Sessions $sessions
        # Verify trimmed JSONL landed in the expected project dir.
        # Previously we silently copied the file across project directories if it
        # showed up elsewhere. That hid CMV bugs and caused cross-project contamination.
        # Now we fail loud and let the user investigate.
        $sessions = Get-Sessions
        $entry = $sessions | Where-Object { $_.Guid -eq $newGuid } | Select-Object -First 1
        if ($entry) {
            $projKey = Get-ProjectKey $entry.Dir
            $expectedDir = "$env:USERPROFILE\.claude\projects\$projKey"
            $expectedFile = Join-Path $expectedDir "$newGuid.jsonl"
            if (-not (Test-Path $expectedFile)) {
                $actual = Get-ChildItem "$env:USERPROFILE\.claude\projects\*\$newGuid.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($actual) {
                    Write-Host ""
                    Write-Host "  CMV WROTE THE TRIMMED SESSION TO THE WRONG PROJECT" -ForegroundColor Red
                    Write-Host "  Expected: $expectedFile" -ForegroundColor Red
                    Write-Host "  Actual:   $($actual.FullName)" -ForegroundColor Red
                    Write-Host "  Investigate before resuming. ClaudeCM will NOT silently copy the file."
                } else {
                    Write-Host ""
                    Write-Host "  Trim claimed to create $newGuid but the file is not on disk." -ForegroundColor Red
                }
            }
        }
        $trimOutput.Split("`n") | Where-Object { $_ -notmatch 'Session ID:' -and $_.Trim() } | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
        # Post-trim: clean up any .cmv-trim-tmp files modified during this run that
        # CMV failed to clean up itself.
        if ($entry) {
            $projDirClaude = "$env:USERPROFILE\.claude\projects\$(Get-ProjectKey $entry.Dir)"
            if (Test-Path $projDirClaude) {
                Get-ChildItem "$projDirClaude\*.cmv-trim-tmp" -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -ge $trimStartedAt } |
                    ForEach-Object {
                        Write-Host "  CMV left a temp file behind: $($_.Name); removing." -ForegroundColor DarkGray
                        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    }
            }
        }
        Write-Host ""
        Write-Host "  Session trimmed. New ID: $newGuid"
        $script:trimNewGuid = $newGuid
    }

    function Do-Refresh($currentGuid) {
        $sessions = Get-Sessions
        $curSession = $sessions | Where-Object { $_.Guid -eq $currentGuid } | Select-Object -First 1
        $curDesc = "Unnamed"; if ($curSession) { $curDesc = $curSession.Desc }
        $curDir = (Get-Location).Path; if ($curSession) { $curDir = $curSession.Dir }
        Write-Host ""
        $newName = Read-Host "  Name for new session (Enter for '$curDesc')"
        if (-not $newName) { $newName = $curDesc }
        # --- Skeleton extraction ---
        $projKey = Get-ProjectKey $curDir
        $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
        $oldJsonl = Join-Path $projDirClaude "$currentGuid.jsonl"
        # Per-operation scoped temp dir to avoid concurrent-refresh collisions
        $refreshTempRoot = Join-Path $cmDir "refresh-temp"
        if (-not (Test-Path $refreshTempRoot)) { New-Item -ItemType Directory -Path $refreshTempRoot -Force | Out-Null }
        # Best-effort cleanup of any per-op subdirs older than 24 hours
        $cleanCutoff = (Get-Date).AddHours(-24)
        Get-ChildItem $refreshTempRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cleanCutoff } |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        $refreshOpId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$currentGuid"
        $refreshTempDir = Join-Path $refreshTempRoot $refreshOpId
        New-Item -ItemType Directory -Path $refreshTempDir -Force | Out-Null
        $skeletonContent = ""
        $transcriptPath = ""
        # Locate extract-skeleton.mjs: prefer alongside this script, then $env:CLAUDECM_HOME, then user-installed locations
        $extractScript = $null
        $candidates = @()
        if ($PSCommandPath) { $candidates += Join-Path (Split-Path $PSCommandPath -Parent) "extract-skeleton.mjs" }
        if ($env:CLAUDECM_HOME) { $candidates += Join-Path $env:CLAUDECM_HOME "extract-skeleton.mjs" }
        $candidates += @(
            "$env:USERPROFILE\.claudecm\extract-skeleton.mjs",
            "$env:USERPROFILE\.local\share\claudecm\extract-skeleton.mjs"
        )
        foreach ($c in $candidates) {
            if ($c -and (Test-Path $c)) { $extractScript = $c; break }
        }
        if ((Test-Path $oldJsonl) -and $extractScript -and (Test-Path $extractScript)) {
            Write-Host ""
            Write-Host "  Extracting session skeleton..."
            $nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
            if ($nodeExe) {
                & $nodeExe $extractScript $oldJsonl $curDesc $refreshTempDir 2>&1 | Out-Null
                $skelFile = Join-Path $refreshTempDir "$currentGuid-skeleton.md"
                $txFile = Join-Path $refreshTempDir "$currentGuid-transcript.md"
                if (Test-Path $skelFile) {
                    $skeletonContent = Get-Content $skelFile -Raw
                    Write-Host "  Skeleton extracted." -ForegroundColor Green
                }
                if (Test-Path $txFile) {
                    $transcriptPath = $txFile
                    $txSize = "{0:N0} KB" -f ((Get-Item $txFile).Length / 1KB)
                    Write-Host "  Filtered transcript: $txSize" -ForegroundColor Green
                }
            } else {
                Write-Host "  Node.js not found, skipping skeleton extraction." -ForegroundColor Yellow
            }
        } else {
            if (-not (Test-Path $oldJsonl)) {
                Write-Host "  Old session JSONL not found, skipping skeleton extraction." -ForegroundColor Yellow
            }
            if (-not (Test-Path $extractScript)) {
                Write-Host "  extract-skeleton.mjs not found, skipping skeleton extraction." -ForegroundColor Yellow
            }
        }
        # --- Build recovery prompt ---
        $refreshPrompt = @"
Read your memories. This is a fresh session replacing a long previous conversation
on this project. Everything you need to know is in:

1) Your memory files (MEMORY.md and all linked files)
2) Any documentation in the project directory
3) The codebase itself (git log for history)
4) project_current_state.md in your memory if it exists
"@
        if ($skeletonContent -or $transcriptPath) {
            $refreshPrompt += "`n5) The structured extraction below, produced by mechanical analysis of the`n   conversation log"
            if ($transcriptPath) {
                $refreshPrompt += "`n6) A filtered transcript of the previous session (conversation text and tool call`n   summaries, no tool output) at:`n   $transcriptPath`n   Read this file and identify any key decisions, user corrections, or reasoning`n   that the skeleton below does not capture."
            }
        }
        $refreshPrompt += @"

IMPORTANT:
- The files listed below reflect the state at the end of the previous session.
  Re-read any file before modifying it, as it may have changed since then.
- The errors listed may or may not still be relevant. Verify before acting on them.
- Do not start any development until the user tells you to.
- Tell the user what you understand about the current state of the project,
  what works, what is pending, and what your behavioral rules are.
"@
        if ($skeletonContent) {
            $refreshPrompt += "`n`n--- ADD YOUR NOTES HERE (context, decisions, corrections, anything the skeleton missed) ---`n`n`n`n--- SKELETON START (review and edit as needed) ---`n`n$skeletonContent`n`n--- SKELETON END ---"
        }
        $promptFile = Join-Path $cmDir "refresh-prompt.tmp"
        $refreshPrompt | Set-Content $promptFile -Encoding UTF8
        $editPrompt = Read-Host "  Edit the compaction prompt and skeleton? (Save and close when done) [y/N]"
        if ($editPrompt -eq 'y') {
            $proc = Start-Process notepad $promptFile -PassThru
            $proc.WaitForExit()
        }
        $promptText = Get-Content $promptFile -Raw
        Remove-Item $promptFile -ErrorAction SilentlyContinue
        # Run Claude headless from the session directory
        $refreshOrigDir = Get-Location
        Set-Location $curDir
        Write-Host ""
        Write-Host "  Creating fresh session, please wait..."
        & $claudeExe --dangerously-skip-permissions -p $promptText 2>&1 | Out-Null
        Write-Host "  Done."
        Set-Location $refreshOrigDir
        # Capture new session GUID (must be different from the one we refreshed)
        $projKey = Get-ProjectKey $curDir
        $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
        $freshGuid = $null
        $newest = Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -ne $currentGuid } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) { $freshGuid = $newest.BaseName }
        if (-not $freshGuid) {
            Write-Host "  Warning: Refresh did not create a new session. The old session is unchanged." -ForegroundColor Yellow
            return
        }
        # Rewrite sessions: new at top, old "(old)" at bottom
        $sessions = Get-Sessions
        $oldEntry = $null
        $others = @()
        foreach ($s in $sessions) {
            if ($s.Guid -eq $currentGuid) {
                if ($s.Desc -match '\(old(?:\s+(\d+))?\)$') {
                    $num = if ($Matches[1]) { [int]$Matches[1] + 1 } else { 2 }
                    $oldDesc = $s.Desc -replace '\(old(?:\s+\d+)?\)$', "(old $num)"
                } else {
                    $oldDesc = "$($s.Desc) (old)"
                }
                $oldEntry = [PSCustomObject]@{ Guid=$s.Guid; Dir=$s.Dir; Desc=$oldDesc; Tokens=$s.Tokens }
            } else {
                $others += $s
            }
        }
        # Get token count for fresh session
        $freshTokens = ''
        if (Test-Path $cmvExe) {
            $benchOut = & $cmvExe benchmark -s $freshGuid --json 2>&1 | Out-String
            $tokMatch = [regex]::Match($benchOut, '"preTrimTokens"\s*:\s*(\d+)')
            if ($tokMatch.Success) { $freshTokens = $tokMatch.Groups[1].Value }
        }
        $freshEntry = [PSCustomObject]@{ Guid=$freshGuid; Dir=$curDir; Desc=$newName; Tokens=$freshTokens }
        $newSessions = @($freshEntry) + @($others)
        if ($oldEntry) { $newSessions += $oldEntry }
        Save-Sessions $newSessions
        Write-Host ""
        Write-Host "  Fresh session created: $newName"
        Write-Host "  Old session moved to bottom of list."
        # Clean up this operation's temp dir (best-effort)
        if (Test-Path $refreshTempDir) {
            Remove-Item $refreshTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    function Do-PostExit($knownGuid) {
        # Resolve session GUID first (must be unambiguous before we run cmv operations
        # that previously used --latest, which is unsafe with concurrent sessions).
        Write-Host ""
        Write-Host "  Session ended."
        Write-Host ""
        if ($knownGuid) {
            $guid = $knownGuid
        } else {
            # Scope the search to the current project's directory only.
            # NEVER scan all projects: cross-project "latest" is the bug that caused
            # session contamination in April 2026.
            $projKey = Get-ProjectKey (Get-Location).Path
            $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
            if (-not (Test-Path $projDirClaude)) { return }
            $newest = Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notlike 'agent-*' } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $newest) { return }
            $guid = $newest.BaseName
        }
        # Auto-snapshot with CMV (now that we have a guid, use -s instead of --latest)
        if (Test-Path $cmvExe) {
            $snapLabel = "auto-exit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            $job = Start-Job -ScriptBlock {
                param($exe, $label, $sid)
                & $exe snapshot $label -s $sid 2>&1
            } -ArgumentList $cmvExe, $snapLabel, $guid
            $spin = @('-', '\', '|', '/')
            $i = 0
            while ($job.State -eq 'Running') {
                Write-Host "`r  $($spin[$i % 4]) Saving snapshot..." -NoNewline
                Start-Sleep -Milliseconds 100
                $i++
            }
            Write-Host "`r  Done.                        "
            Remove-Job $job -Force
        }
        $sessions = Get-Sessions
        $existing = $sessions | Where-Object { $_.Guid -eq $guid }
        if ($existing) {
            # Update token count via cmv benchmark (use -s, never --latest)
            if (Test-Path $cmvExe) {
                $benchOut = & $cmvExe benchmark -s $guid --json 2>&1 | Out-String
                $tokMatch = [regex]::Match($benchOut, '"preTrimTokens"\s*:\s*(\d+)')
                if ($tokMatch.Success) { $existing.Tokens = $tokMatch.Groups[1].Value }
            }
            $sessions = @($existing) + @($sessions | Where-Object { $_.Guid -ne $guid })
            Save-Sessions $sessions
        } else {
            Write-Host ""
            $folderName = (Split-Path (Get-Location).Path -Leaf) -replace '-', ' '
            $folderName = (Get-Culture).TextInfo.ToTitleCase($folderName)
            $desc = Read-Host "  Describe this session (Enter for '$folderName', 'skip' to skip)"
            if ($desc -eq 'skip') { return }
            if (-not $desc) { $desc = $folderName }
            $newEntry = [PSCustomObject]@{ Guid=$guid; Dir=(Get-Location).Path; Desc=$desc; Tokens='' }
            $sessions = @($newEntry) + @($sessions)
            Save-Sessions $sessions
        }
        # Sync session index for Claude's /resume picker
        $sessions = Get-Sessions
        $curSession = $sessions | Where-Object { $_.Guid -eq $guid } | Select-Object -First 1
        if ($curSession) { Sync-SessionIndex $curSession.Dir }

        # Show session size and anti-bloat options
        $sizeDisplay = ""
        if ($curSession) {
            $info = Get-SessionInfo $curSession.Guid $curSession.Dir $curSession.Tokens
            $sizeDisplay = "$($info.Size) ($($info.Tokens))"
        }
        if ($sizeDisplay) {
            Write-Host ""
            Write-Host "  Current session: $sizeDisplay"
        }
        Write-Host ""
        $doTrim = Read-Host "  Trim this session? [y/N]"
        if ($doTrim -eq 'y') {
            Do-Trim $guid
            if ($script:trimNewGuid) { $guid = $script:trimNewGuid }
        }
        # Anti-bloat: refresh (deeper clean)
        Write-Host ""
        $doRefresh = Read-Host "  Create a new compacted session, built from a structured rebuild of this one? [y/N]"
        if ($doRefresh -eq 'y') {
            Do-Refresh $guid
        }
    }

    function Do-Resume($pick, $sessions) {
        if ($pick -lt 1 -or $pick -gt $sessions.Count) {
            Write-Host "  Invalid selection."
            return
        }
        $sel = $sessions[$pick - 1]
        if (-not (Test-Path $sel.Dir)) {
            Write-Host "  Error: Project directory not found: $($sel.Dir)"
            return
        }
        $origDir = Get-Location
        Set-Location $sel.Dir
        $scanResult = Do-OrphanScan $sel.Dir $sel.Guid
        if ($scanResult -and $scanResult.Action -eq 'select') {
            $displayName = Get-SessionDisplayName $sel.Desc
            & $claudeExe --dangerously-skip-permissions --resume $scanResult.Guid -n $displayName
            if ($LASTEXITCODE -eq 0) {
                Do-PostExit $scanResult.Guid
            }
            Set-Location $origDir
            return
        }
        $recover = Resolve-ResumeOrRecover $sel.Guid $sel.Dir $sel.Desc $sel.Tokens
        if ($recover.Action -eq 'cancel') { Set-Location $origDir; return }
        $displayName = Get-SessionDisplayName $sel.Desc
        if ($recover.Action -eq 'fresh') {
            # Do NOT delete the old entry before launch. Discover the new GUID after
            # a successful launch by finding the newest JSONL in this project's dir.
            $projKey = Get-ProjectKey $sel.Dir
            $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
            $beforeNewest = $null
            if (Test-Path $projDirClaude) {
                $beforeNewest = (Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1)
            }
            & $claudeExe --dangerously-skip-permissions -n $displayName
            if ($LASTEXITCODE -eq 0) {
                $newJsonl = Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($newJsonl -and (-not $beforeNewest -or $newJsonl.BaseName -ne $beforeNewest.BaseName)) {
                    # Swap GUID in place, preserve desc and dir, reset tokens.
                    $sessions = Get-Sessions
                    foreach ($s in $sessions) {
                        if ($s.Guid -eq $sel.Guid) { $s.Guid = $newJsonl.BaseName; $s.Tokens = '' }
                    }
                    Save-Sessions $sessions
                    Do-PostExit $newJsonl.BaseName
                }
            }
            Set-Location $origDir
            return
        }
        if ($recover.Action -eq 'primed') {
            & $claudeExe --dangerously-skip-permissions --resume $recover.Guid -n $displayName
            if ($LASTEXITCODE -eq 0) {
                Do-PostExit $recover.Guid
            }
            Set-Location $origDir
            return
        }
        & $claudeExe --dangerously-skip-permissions --resume $sel.Guid -n $displayName
        if ($LASTEXITCODE -eq 0) {
            Do-PostExit $sel.Guid
        } else {
            # Distinguish "JSONL is actually missing" from "Claude refused to resume but the file is there"
            $projKey = Get-ProjectKey $sel.Dir
            $jsonlPath = "$env:USERPROFILE\.claude\projects\$projKey\$($sel.Guid).jsonl"
            if (Test-Path $jsonlPath) {
                Write-Host ""
                Write-Host "  Claude refused to resume this session (file is on disk but Claude won't load it)." -ForegroundColor Yellow
                Write-Host "  Common causes: interrupted tool call, stale deferred-tool marker."
                Write-Host "  The session entry has NOT been deleted. You can try again later or investigate the JSONL."
            } else {
                Write-Host ""
                $delEntry = Read-Host "  Session JSONL is missing. Delete this entry? [Y/n]"
                if ($delEntry -ne 'n') {
                    $sessions = Get-Sessions
                    $sessions = @($sessions | Where-Object { $_.Guid -ne $sel.Guid })
                    Save-Sessions $sessions
                    Write-Host "  Entry removed."
                }
            }
        }
        Set-Location $origDir
    }

    # --- Main ---
    $firstArg = $args[0]

    # List mode
    if ($firstArg -eq 'l' -or $firstArg -eq 'L' -or $firstArg -eq '-l' -or $firstArg -eq '-L') {
        while ($true) {
            $sessions = Get-Sessions
            if ($sessions.Count -eq 0) {
                Write-Host ""
                Write-Host "  No saved sessions."
                Write-Host ""
                return
            }
            Show-List $sessions
            Write-Host ""
            $pick = Read-Host "  Pick a session (Enter to quit)"
            if (-not $pick) { return }
            if ($pick -eq 'e' -or $pick -eq 'E') {
                Do-EditList
                continue
            }
            if ($pick -eq 'v' -or $pick -eq 'V') {
                Do-ViewArchived
                continue
            }
            if ($pick -eq 'm' -or $pick -eq 'M') {
                Write-Host ""
                Write-Host "  Current machine name: $machineName"
                $newMn = Read-Host "  New name (Enter to keep)"
                if ($newMn) {
                    $newMn | Set-Content $machineNameFile
                    $machineName = $newMn
                    Write-Host "  Machine name set to: $machineName" -ForegroundColor Green
                }
                continue
            }
            if ($pick -match '^\d+$') {
                Do-Resume ([int]$pick) $sessions
                return
            }
            # Non-numeric, non-E: treat as new project title
            $safeDirName = $pick.ToLower() -replace '\s+', '-' -replace '[^a-z0-9_-]', ''
            $newProjDir = Join-Path (Get-Location).Path $safeDirName
            $counter = 1
            while (Test-Path $newProjDir) {
                $newProjDir = Join-Path (Get-Location).Path "$safeDirName($counter)"
                $counter++
            }
            New-Item -ItemType Directory -Path $newProjDir -Force | Out-Null
            Write-Host ""
            Write-Host "  Starting new session: $pick"
            Write-Host "  Project dir: $newProjDir"
            $origDir = Get-Location
            Set-Location $newProjDir
            $displayName = Get-SessionDisplayName $pick
            & $claudeExe --dangerously-skip-permissions -n $displayName
            $projKey = Get-ProjectKey (Get-Location).Path
            $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
            $newest = Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($newest) {
                $sessions = Get-Sessions
                $newEntry = [PSCustomObject]@{ Guid=$newest.BaseName; Dir=$newProjDir; Desc=$pick; Tokens='' }
                $sessions = @($newEntry) + @($sessions)
                Save-Sessions $sessions
            }
            Set-Location $origDir
            return
        }
        return
    }

    # Direct resume by number
    if ($firstArg -match '^\d+$') {
        $sessions = Get-Sessions
        if ($sessions.Count -eq 0) {
            Write-Host "  No saved sessions."
            return
        }
        Show-List $sessions ([int]$firstArg)
        Do-Resume ([int]$firstArg) $sessions
        return
    }

    # Normal mode
    $projDir = $null
    $passArgs = @()
    $i = 0
    while ($i -lt $args.Count) {
        if ($args[$i] -eq '--proj' -and ($i + 1) -lt $args.Count) {
            $projDir = $args[$i + 1]
            $i += 2
        } else {
            $passArgs += $args[$i]
            $i++
        }
    }

    $origDir = Get-Location
    if ($projDir) {
        if (-not (Test-Path $projDir)) {
            Write-Host "Error: Directory not found: $projDir"
            return
        }
        Set-Location $projDir
    }

    # Check if current directory matches an existing session
    $curDir = (Get-Location).Path
    $sessions = Get-Sessions
    $match = $sessions | Where-Object { $_.Dir -eq $curDir } | Select-Object -First 1
    $preNamed = $null
    if ($passArgs.Count -eq 0) {
        if ($match) {
            $scanResult = Do-OrphanScan $curDir $match.Guid
            if ($scanResult -and $scanResult.Action -eq 'select') {
                if (-not (Test-Path $match.Dir)) {
                    Write-Host "  Error: Project directory not found: $($match.Dir)"
                    return
                }
                Set-Location $match.Dir
                $displayName = Get-SessionDisplayName $match.Desc
                & $claudeExe --dangerously-skip-permissions --resume $scanResult.Guid -n $displayName
                if ($LASTEXITCODE -eq 0) {
                    Do-PostExit $scanResult.Guid
                }
                if ($projDir) { Set-Location $origDir }
                return
            }

            Write-Host ""
            Write-Host "  Session found: $($match.Desc)"
            $rename = Read-Host "  Rename? (Enter to keep)"
            if ($rename) {
                $match.Desc = $rename
                Save-Sessions $sessions
            }
            $useExisting = Read-Host "  Resume this session? [Y/n]"
            if ($useExisting -ne 'n') {
                if (-not (Test-Path $match.Dir)) {
                    Write-Host "  Error: Project directory not found: $($match.Dir)"
                    return
                }
                Set-Location $match.Dir
                $recover = Resolve-ResumeOrRecover $match.Guid $match.Dir $match.Desc $match.Tokens
                if ($recover.Action -eq 'cancel') { if ($projDir) { Set-Location $origDir }; return }
                $displayName = Get-SessionDisplayName $match.Desc
                if ($recover.Action -eq 'fresh') {
                    # Do NOT delete the old entry before launch. Detect new GUID via project-scoped newest JSONL.
                    $projKey = Get-ProjectKey $match.Dir
                    $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
                    $beforeNewest = $null
                    if (Test-Path $projDirClaude) {
                        $beforeNewest = (Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTime -Descending | Select-Object -First 1)
                    }
                    & $claudeExe --dangerously-skip-permissions -n $displayName
                    if ($LASTEXITCODE -eq 0) {
                        $newJsonl = Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTime -Descending | Select-Object -First 1
                        if ($newJsonl -and (-not $beforeNewest -or $newJsonl.BaseName -ne $beforeNewest.BaseName)) {
                            $sessions = Get-Sessions
                            foreach ($s in $sessions) {
                                if ($s.Guid -eq $match.Guid) { $s.Guid = $newJsonl.BaseName; $s.Tokens = '' }
                            }
                            Save-Sessions $sessions
                            Do-PostExit $newJsonl.BaseName
                        }
                    }
                    if ($projDir) { Set-Location $origDir }
                    return
                }
                if ($recover.Action -eq 'primed') {
                    & $claudeExe --dangerously-skip-permissions --resume $recover.Guid -n $displayName
                    if ($LASTEXITCODE -eq 0) {
                        Do-PostExit $recover.Guid
                    }
                    if ($projDir) { Set-Location $origDir }
                    return
                }
                & $claudeExe --dangerously-skip-permissions --resume $match.Guid -n $displayName
                if ($LASTEXITCODE -eq 0) {
                    Do-PostExit $match.Guid
                } else {
                    $projKey = Get-ProjectKey $match.Dir
                    $jsonlPath = "$env:USERPROFILE\.claude\projects\$projKey\$($match.Guid).jsonl"
                    if (Test-Path $jsonlPath) {
                        Write-Host ""
                        Write-Host "  Claude refused to resume this session (file is on disk but Claude won't load it)." -ForegroundColor Yellow
                        Write-Host "  Common causes: interrupted tool call, stale deferred-tool marker."
                        Write-Host "  The session entry has NOT been deleted."
                    } else {
                        Write-Host ""
                        $delEntry = Read-Host "  Session JSONL is missing. Delete this entry? [Y/n]"
                        if ($delEntry -ne 'n') {
                            $sessions = @($sessions | Where-Object { $_.Guid -ne $match.Guid })
                            Save-Sessions $sessions
                            Write-Host "  Entry removed."
                        }
                    }
                }
                if ($projDir) { Set-Location $origDir }
                return
            }
        } else {
            Write-Host ""
            Write-Host "  No session entry found for this directory."
            $folderDefault = (Split-Path (Get-Location).Path -Leaf) -replace '-', ' '
            $folderDefault = (Get-Culture).TextInfo.ToTitleCase($folderDefault)
            $preNamed = Read-Host "  Create a name for this session (Enter for '$folderDefault', 'skip' to skip)"
            if ($preNamed -eq 'skip') { $preNamed = $null }
            elseif (-not $preNamed) { $preNamed = $folderDefault }
        }
    }

    $launchDesc = if ($preNamed) { $preNamed } elseif ($match) { $match.Desc } else { (Split-Path (Get-Location).Path -Leaf) }
    $displayName = Get-SessionDisplayName $launchDesc
    if ($passArgs.Count -gt 0) {
        & $claudeExe --dangerously-skip-permissions -n $displayName @passArgs
    } else {
        & $claudeExe --dangerously-skip-permissions -n $displayName
    }

    if ($LASTEXITCODE -ne 0) {
        if ($projDir) { Set-Location $origDir }
        return
    }

    if ($preNamed) {
        # Session was pre-named before launch; register it then run post-exit
        $projKey = Get-ProjectKey (Get-Location).Path
        $projDirClaude = "$env:USERPROFILE\.claude\projects\$projKey"
        $newest = Get-ChildItem "$projDirClaude\*.jsonl" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) {
            $newGuid = $newest.BaseName
            $sessions = Get-Sessions
            $newEntry = [PSCustomObject]@{ Guid=$newGuid; Dir=$curDir; Desc=$preNamed; Tokens='' }
            $sessions = @($newEntry) + @($sessions)
            Save-Sessions $sessions
            Do-PostExit $newGuid
        } else {
            Do-PostExit
        }
    } else {
        Do-PostExit
    }

    if ($projDir) { Set-Location $origDir }
}

function lst { Get-ChildItem | Sort-Object LastWriteTime -Descending }

function grep {
    param(
        [Parameter(Position=0, Mandatory)][string]$Pattern,
        [Parameter(Position=1)][string]$Path,
        [Alias('r')][switch]$Recurse,
        [Alias('i')][switch]$CaseInsensitive
    )
    $slsArgs = @{ Pattern = $Pattern }
    if (-not $CaseInsensitive) { $slsArgs['CaseSensitive'] = $true }
    if ($Path) {
        Get-ChildItem -Path $Path -Recurse:$Recurse -File | Select-String @slsArgs
    } elseif ($Recurse) {
        Get-ChildItem -Recurse -File | Select-String @slsArgs
    } else {
        $input | Select-String @slsArgs
    }
}
