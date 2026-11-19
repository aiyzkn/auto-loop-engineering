#requires -Version 7.0
# auto-loop の共通関数。指令リポジトリ（Markdown + git）を読み書きする
# 方針: 認証の入力待ちで止まらない / 何もしなかった理由もログに残す / 破壊的な git 操作をしない
Set-StrictMode -Version 3

$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:LogAgent = ''
try { [Console]::OutputEncoding = $script:Utf8NoBom } catch { }

function Get-LoopHome {
    if ($env:AUTO_LOOP_HOME) { return $env:AUTO_LOOP_HOME }
    return (Join-Path $HOME '.claude/auto-loop')
}

function Get-LoopConfig {
    $path = Join-Path (Get-LoopHome) 'config.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "設定がありません: $path （/auto-loop setup、または scripts/install.ps1 を実行する）"
    }
    $c = [IO.File]::ReadAllText($path, $script:Utf8NoBom) | ConvertFrom-Json
    # 同じ PC の別エージェント（Copilot など）は、環境変数で ID を差し替える
    if ($env:AUTO_LOOP_AGENT_ID) { $c.agentId = $env:AUTO_LOOP_AGENT_ID }
    if (-not $c.agentId) { throw "config.json に agentId がありません: $path" }
    $script:LogAgent = [string]$c.agentId
    if (-not $c.controlRepoPath) { throw "config.json に controlRepoPath がありません: $path" }
    if (-not (Test-Path -LiteralPath (Join-Path $c.controlRepoPath 'projects'))) {
        throw "指令リポジトリが見つかりません（projects/ が無い）: $($c.controlRepoPath)"
    }
    foreach ($d in @(@('controlRemote', 'origin'), @('leaseHours', 24), @('maxParallel', 3))) {
        if (-not ($c.PSObject.Properties.Name -contains $d[0])) { $c | Add-Member -NotePropertyName $d[0] -NotePropertyValue $d[1] }
    }
    if (-not ($c.PSObject.Properties.Name -contains 'repoPaths') -or $null -eq $c.repoPaths) {
        $c | Add-Member -NotePropertyName repoPaths -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    return $c
}

function Get-NowIso { return (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz') }

function Write-LoopLog {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Message)
    try {
        $dir = Join-Path (Get-LoopHome) 'logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        $agent = if ($script:LogAgent) { $script:LogAgent } else { '-' }
        $line = "{0} [{1}] [{2}] {3}`n" -f (Get-NowIso), $agent, $Source, ($Message -replace '\r?\n', ' / ')
        [IO.File]::AppendAllText((Join-Path $dir 'auto-loop.log'), $line, $script:Utf8NoBom)
    }
    catch { }
}

function Read-LoopText { param([string]$Path) return [IO.File]::ReadAllText($Path, $script:Utf8NoBom) }
function Write-LoopText { param([string]$Path, [string]$Text) [IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom) }

$script:FrontMatterRx = [regex]::new('\A(﻿?---\r?\n)(.*?)(\r?\n---[ \t]*(?:\r?\n|\z))', 'Singleline')

# フロントマターは「キー: 値」の 1 行だけを扱う（入れ子・複数行は使わない）
function Get-FrontMatter {
    param([string]$Text)
    $h = [ordered]@{}
    $m = $script:FrontMatterRx.Match($Text)
    if (-not $m.Success) { return $h }
    foreach ($line in ($m.Groups[2].Value -split '\r?\n')) {
        if ($line -match '^([A-Za-z_][\w-]*):[ \t]*(.*)$') { $h[$Matches[1]] = $Matches[2].Trim().Trim('"') }
    }
    return $h
}

function Set-FrontMatterValue {
    param([string]$Text, [Parameter(Mandatory)][string]$Key, [AllowEmptyString()][string]$Value = '')
    $m = $script:FrontMatterRx.Match($Text)
    if (-not $m.Success) { throw 'フロントマター（先頭の --- で囲んだ部分）がありません' }
    $body = $m.Groups[2].Value
    $nl = if ($m.Groups[1].Value.EndsWith("`r`n")) { "`r`n" } else { "`n" }
    $line = if ($Value -eq '') { "${Key}:" } else { "${Key}: $Value" }
    $rx = [regex]::new('(?m)^' + [regex]::Escape($Key) + ':.*?(?=\r?$)')
    if ($rx.IsMatch($body)) { $body = $rx.Replace($body, $line.Replace('$', '$$'), 1) }
    else { $body = $body + $nl + $line }
    $g = $m.Groups[2]
    return $Text.Substring(0, $g.Index) + $body + $Text.Substring($g.Index + $g.Length)
}

# 末尾の「## ログ」に 1 行足す（ログは追記だけ。ひな形ではログが最後の節）
function Add-TaskLogLine {
    param([string]$Text, [string]$Agent, [string]$Message)
    $nl = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $t = $Text.TrimEnd("`r", "`n")
    if ($t -notmatch '(?m)^## ログ') { $t = $t + $nl + $nl + '## ログ' + $nl }
    return $t + $nl + ('- {0} [{1}] {2}' -f (Get-NowIso), $Agent, ($Message -replace '\r?\n', ' / ')) + $nl
}

function Invoke-Git {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string[]]$GitArgs)
    $oldPrompt = $env:GIT_TERMINAL_PROMPT; $oldGcm = $env:GCM_INTERACTIVE
    # 認証の入力待ちで止めない（失敗として返す）
    $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'
    # pwsh 7.1 以前は、Stop のままだと標準エラーの 1 行目で例外になる（git は進み具合を標準エラーに出す）
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& git -C $Repo -c core.quotepath=false @GitArgs 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    }
    finally { $env:GIT_TERMINAL_PROMPT = $oldPrompt; $env:GCM_INTERACTIVE = $oldGcm }
    return [pscustomobject]@{ Code = $code; Out = $out; Text = ($out -join "`n") }
}

# git の失敗の文面から、直し方を 1 行で返す（分からなければ空）
function Get-GitFailureHint {
    param([string]$Repo, [string]$Remote, [string]$Text)
    if ($Text -notmatch 'Cannot prompt because user interactivity has been disabled|terminal prompts disabled|could not read Username') { return '' }
    $url = (Invoke-Git $Repo @('remote', 'get-url', $Remote)).Text.Trim()
    $origin = if ($url -match '^(https?://[^/]+)') { $Matches[1] } else { 'https://<ホスト>' }
    # Git Credential Manager に同じホストのアカウントが複数あると、選ぶ画面を出そうとして止まる
    return "資格情報の入力が要る状態（同じホストのアカウントが複数保存されている、または未保存）。この clone で使うアカウントを固定する: git -C `"$Repo`" config credential.$origin.username <アカウント>（未保存なら、一度対話で git fetch してログインする）"
}

function Get-ControlRemote {
    param($Config)
    $r = Invoke-Git $Config.controlRepoPath @('remote')
    if ($r.Out -contains $Config.controlRemote) { return [string]$Config.controlRemote }
    return ''   # リモート無し（1 台だけで試すとき）
}

function Get-ControlBranch {
    param($Config)
    return (Invoke-Git $Config.controlRepoPath @('rev-parse', '--abbrev-ref', 'HEAD')).Text.Trim()
}

function Test-RemoteBranch {
    param($Config, [string]$Remote, [string]$Branch)
    $r = Invoke-Git $Config.controlRepoPath @('ls-remote', '--heads', $Remote, $Branch)
    return [pscustomobject]@{ Ok = ($r.Code -eq 0); Exists = [bool]$r.Text.Trim(); Detail = $r.Text }
}

# 取り込みだけ（未コミットの変更は autostash で保つ）
function Update-ControlRepo {
    param($Config)
    $repo = $Config.controlRepoPath
    $remote = Get-ControlRemote $Config
    if (-not $remote) { return [pscustomobject]@{ Ok = $true; Reason = 'local-only'; Detail = '' } }
    $branch = Get-ControlBranch $Config
    $rb = Test-RemoteBranch $Config $remote $branch
    if (-not $rb.Ok) { return [pscustomobject]@{ Ok = $false; Reason = 'remote'; Detail = $rb.Detail } }
    if (-not $rb.Exists) { return [pscustomobject]@{ Ok = $true; Reason = 'remote-empty'; Detail = '' } }
    $r = Invoke-Git $repo @('pull', '--rebase', '--autostash', $remote, $branch)
    if ($r.Code -ne 0) {
        $conflict = $r.Text -match 'CONFLICT|could not apply'
        Invoke-Git $repo @('rebase', '--abort') | Out-Null
        return [pscustomobject]@{ Ok = $false; Reason = $(if ($conflict) { 'conflict' } else { 'pull' }); Detail = $r.Text }
    }
    return [pscustomobject]@{ Ok = $true; Reason = 'updated'; Detail = '' }
}

# コミット（変更があれば）→ 取り込み → 送信。競合したら rebase を取り消して報告する（強制はしない）
function Sync-ControlRepo {
    param($Config, [Parameter(Mandatory)][string]$Message)
    $repo = $Config.controlRepoPath
    $committed = $false
    if ((Invoke-Git $repo @('status', '--porcelain')).Text.Trim()) {
        Invoke-Git $repo @('add', '-A') | Out-Null
        $r = Invoke-Git $repo @('commit', '-m', $Message)
        if ($r.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Reason = 'commit'; Detail = $r.Text; Committed = $false; Pushed = $false } }
        $committed = $true
    }
    $remote = Get-ControlRemote $Config
    if (-not $remote) { return [pscustomobject]@{ Ok = $true; Reason = 'local-only'; Detail = ''; Committed = $committed; Pushed = $false } }
    $branch = Get-ControlBranch $Config
    $last = ''
    for ($i = 1; $i -le 3; $i++) {
        $rb = Test-RemoteBranch $Config $remote $branch
        if (-not $rb.Ok) { return [pscustomobject]@{ Ok = $false; Reason = 'remote'; Detail = $rb.Detail; Committed = $committed; Pushed = $false } }
        if ($rb.Exists) {
            $r = Invoke-Git $repo @('pull', '--rebase', $remote, $branch)
            if ($r.Code -ne 0) {
                $conflict = $r.Text -match 'CONFLICT|could not apply'
                Invoke-Git $repo @('rebase', '--abort') | Out-Null
                return [pscustomobject]@{ Ok = $false; Reason = $(if ($conflict) { 'conflict' } else { 'pull' }); Detail = $r.Text; Committed = $committed; Pushed = $false }
            }
            $ahead = (Invoke-Git $repo @('rev-list', '--count', "$remote/$branch..HEAD")).Text.Trim()
            if ($ahead -eq '0') { return [pscustomobject]@{ Ok = $true; Reason = 'up-to-date'; Detail = ''; Committed = $committed; Pushed = $false } }
        }
        $r = Invoke-Git $repo @('push', $remote, "HEAD:$branch")
        if ($r.Code -eq 0) { return [pscustomobject]@{ Ok = $true; Reason = 'pushed'; Detail = ''; Committed = $committed; Pushed = $true } }
        $last = $r.Text
    }
    return [pscustomobject]@{ Ok = $false; Reason = 'push'; Detail = $last; Committed = $committed; Pushed = $false }
}

function Find-TaskFile {
    param($Config, [Parameter(Mandatory)][string]$Task, [string]$Project = '')
    $root = Join-Path $Config.controlRepoPath 'projects'
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { -not $Project -or $_.Name -eq $Project })
    $hits = @()
    foreach ($d in $dirs) {
        foreach ($sub in @('tasks', 'archive')) {
            $p = Join-Path $d.FullName "$sub/$Task.md"
            if (Test-Path -LiteralPath $p) { $hits += (Get-Item -LiteralPath $p) }
        }
    }
    if ($hits.Count -eq 0) { throw "タスクが見つかりません: $Task" }
    if ($hits.Count -gt 1) { throw "同じ ID のタスクが複数あります（-Project を指定する）: $(($hits | ForEach-Object FullName) -join ', ')" }
    return $hits[0]
}

function Get-RelPath {
    param([string]$Root, [string]$Path)
    return [IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function Get-LoopTasks {
    param($Config, [string]$Project = '', [switch]$IncludeArchive)
    $root = Join-Path $Config.controlRepoPath 'projects'
    $list = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { -not $Project -or $_.Name -eq $Project })) {
        $subs = @('tasks'); if ($IncludeArchive) { $subs += 'archive' }
        foreach ($sub in $subs) {
            $dir = Join-Path $d.FullName $sub
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File | Where-Object { $_.Name -notmatch '^(_|README)' })) {
                $fm = Get-FrontMatter (Read-LoopText $f.FullName)
                $get = { param($k) if ($fm.Contains($k)) { [string]$fm[$k] } else { '' } }
                $list += [pscustomobject]@{
                    project   = $d.Name
                    id        = $f.BaseName
                    status    = $(if ($sub -eq 'archive' -and -not (& $get 'status')) { 'done' } elseif (& $get 'status') { & $get 'status' } else { '?' })
                    stage     = & $get 'stage'
                    priority  = & $get 'priority'
                    created   = & $get 'created'
                    assignee  = & $get 'assignee'
                    claimedBy = & $get 'claimed_by'
                    heartbeat = & $get 'heartbeat_at'
                    updated   = & $get 'updated'
                    title     = & $get 'title'
                    archived  = ($sub -eq 'archive')
                    path      = $f.FullName
                }
            }
        }
    }
    return $list
}

function Get-AgeHours {
    param([string]$Iso)
    if (-not $Iso) { return $null }
    try { return [math]::Round(([datetimeoffset]::Now - [datetimeoffset]::Parse($Iso)).TotalHours, 1) } catch { return $null }
}

# project.md の「## リポジトリ」の表を読む（列の順: キー | ホスト | リポジトリ | アカウント | 本流リモート | 基準ブランチ）
function Get-ProjectRepos {
    param([Parameter(Mandatory)][string]$ProjectFile)
    $rows = @(); $in = $false; $seenTable = $false
    foreach ($line in (Read-LoopText $ProjectFile) -split '\r?\n') {
        if ($line -match '^##\s+リポジトリ') { $in = $true; continue }
        if (-not $in) { continue }
        if ($line -match '^##\s') { break }
        if ($line -notmatch '^\s*\|') { if ($seenTable) { break } else { continue } }
        $seenTable = $true
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim().Trim('`') })
        if ($cells.Count -lt 3) { continue }
        if ($cells[0] -match '^:?-{2,}' -or $cells[0] -in @('キー', 'key') -or -not $cells[0] -or $cells[0].StartsWith('<')) { continue }
        $cell = { param($i, $default) if ($cells.Count -gt $i -and $cells[$i] -and $cells[$i] -ne '-') { $cells[$i] } else { $default } }
        $rows += [pscustomobject]@{
            key     = $cells[0]
            host    = & $cell 1 ''
            repo    = & $cell 2 ''
            account = & $cell 3 ''
            remote  = & $cell 4 'origin'
            base    = & $cell 5 'main'
        }
    }
    return $rows
}

# 起動時・スリープ解除時の自動起動（kick.ps1）の設定。config.json の kick に無い項目は既定で補う
function Get-KickConfig {
    param($Config)
    $k = [ordered]@{
        enabled              = $false   # install.ps1 -EnableKick で true
        minIntervalHours     = 4        # 前に起こしてから、次に起こすまでの最短の時間
        idle                 = $true    # 通常のタスクが無いとき、手が空いたときの作業のために起こすか
        idleMinIntervalHours = 24       # 手が空いたときの作業のために起こす間隔
        busyMinutes          = 15       # 作業中のセッション（入力待ちでないもの）の記録がこの分の内に書かれていれば、起こさない（0 なら見ない）
        idleCloseMinutes     = 60       # 起こしたセッションの記録がこの分のあいだ書かれなければ、終わらせる（0 なら終わらせない）
        permissionMode       = 'auto'   # 起こすセッションの権限モード
        remoteControl        = $true    # --remote-control つきで起こす
        prompt               = ''       # 最初に送る指示。空なら既定（/auto-loop next）
    }
    if ($Config.PSObject.Properties.Name -contains 'kick' -and $Config.kick) {
        foreach ($p in $Config.kick.PSObject.Properties) { if ($k.Contains($p.Name) -and $null -ne $p.Value) { $k[$p.Name] = $p.Value } }
    }
    return [pscustomobject]$k
}

# Claude Code のセッションの記録（~/.claude/projects/<プロジェクト>/<ID>.jsonl）の末尾 MaxBytes バイトを行に分けて返す。
# 末尾に巨大な行があっても速いよう、バイト単位で読む（auto-resume-global の Read-SessionTail と同じ考え方）。途中から読んだときは最初の行を捨てる
function Read-SessionTailLines {
    param([string]$Path, [long]$MaxBytes = 4MB)
    $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $start = [math]::Max([long]0, $fs.Length - $MaxBytes)
        [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
        $buf = [byte[]]::new([int]($fs.Length - $start))
        $n = 0
        while ($n -lt $buf.Length) { $k = $fs.Read($buf, $n, $buf.Length - $n); if ($k -le 0) { break }; $n += $k }
    }
    finally { $fs.Dispose() }
    [string[]]$lines = [Text.Encoding]::UTF8.GetString($buf, 0, $n).Split([char]"`n")
    if ($start -gt 0 -and $lines.Length -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
    return , $lines
}

# セッションが「手を動かしているか」を、最後の会話の記録から判定する（kick.ps1 の 1 台 1 セッションの数え方。依頼 20261119-autoresume-fix-idle-dashboard）。
#   empty         会話の記録が無い（起動したが何も指示されていない）
#   limit         最後が利用上限の記録（解除待ち。kick.ps1 は復帰タスクで別に見る）
#   waiting-input 最後が assistant の応答で、ツールの呼び出しが無い（利用者の入力待ち）
#   working       最後が user の入力・ツールの結果、またはツールを呼び出し中で、BusyMinutes 分の内に記録（サブエージェントの記録を含む）が書かれた
#   stale         working の形だが、BusyMinutes 分より長く書かれていない（権限の確認待ち・異常終了など。長いツールの実行もここに入りうる）
# 利用者の入力ではない user の記録（サブエージェントの通知・isMeta など）と、サブエージェント側の記録（isSidechain）は飛ばす。
# 記録の形は Claude Code の内部形式（2026-11 時点）。版が変わったら実物に合わせて直す
function Get-SessionActivity {
    param([string]$Path, [double]$BusyMinutes = 15)
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return [pscustomobject]@{ State = 'empty'; LastWrite = $null; Path = $Path } }
    $lastWrite = $item.LastWriteTime
    $sub = Join-Path $item.DirectoryName ([IO.Path]::GetFileNameWithoutExtension($item.Name))
    if (Test-Path -LiteralPath $sub) {
        $s = Get-ChildItem -LiteralPath $sub -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($s -and $s.LastWriteTime -gt $lastWrite) { $lastWrite = $s.LastWriteTime }
    }
    $state = 'empty'
    $lines = Read-SessionTailLines $Path
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $l = $lines[$i].TrimEnd("`r")
        if (-not $l.StartsWith('{')) { continue }
        try { $r = $l | ConvertFrom-Json } catch { continue }
        if ($r.type -notin @('user', 'assistant')) { continue }
        if ($r.PSObject.Properties['isSidechain'] -and $r.isSidechain) { continue }
        if ($r.type -eq 'user') {
            if ($r.PSObject.Properties['isMeta'] -and $r.isMeta) { continue }
            if ($r.PSObject.Properties['origin'] -and $r.origin -and $r.origin.PSObject.Properties['kind'] -and $r.origin.kind -ne 'human') { continue }
            $c = if ($r.message) { $r.message.content } else { $null }
            if ($c -is [string] -and $c -match '^\s*<(task-notification|system-reminder)>') { continue }
            $state = 'working'; break
        }
        # assistant
        if (($r.PSObject.Properties['apiError'] -and $r.apiError -in @('usage_limit_reached', 'model_requires_usage_credits')) -or
            ($r.PSObject.Properties['error'] -and $r.error -eq 'rate_limit')) { $state = 'limit'; break }
        $content = @(if ($r.message -and $r.message.PSObject.Properties['content']) { $r.message.content })
        $tool = @($content | Where-Object { $_ -and $_.PSObject.Properties['type'] -and $_.type -eq 'tool_use' })
        $state = if ($tool.Count -gt 0) { 'working' } else { 'waiting-input' }
        break
    }
    if ($state -eq 'working' -and ((Get-Date) - $lastWrite).TotalMinutes -gt $BusyMinutes) { $state = 'stale' }
    return [pscustomobject]@{ State = $state; LastWrite = $lastWrite; Path = $Path }
}

# この PC で「手を動かしている」セッションを数える。BusyMinutes 分の内に書かれた記録（本体かサブエージェント）だけを読む。
# 戻り値の Working が 1 件以上なら、ほかのセッションが動いている。Idle は数えなかったもの（入力待ちなど）の内訳
function Get-BusySessions {
    param([string]$ProjectsDir, [double]$BusyMinutes = 15, [string[]]$ExcludeSessionIds = @())
    $working = @(); $idle = @()
    if (-not (Test-Path -LiteralPath $ProjectsDir)) { return [pscustomobject]@{ Working = $working; Idle = $idle } }
    $cutoff = (Get-Date).AddMinutes(-$BusyMinutes)
    $seen = @{}
    foreach ($d in @(Get-ChildItem -LiteralPath $ProjectsDir -Directory -ErrorAction SilentlyContinue)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $cutoff })) {
            # サブエージェントの記録（<ID>/subagents/....jsonl）なら、本体の <ID>.jsonl を見る
            $main = $f.FullName
            $rel = $f.FullName.Substring($d.FullName.Length).TrimStart('\', '/')
            $first = ($rel -split '[\\/]')[0]
            if ($rel -ne $f.Name) { $main = Join-Path $d.FullName "$first.jsonl" }
            $sid = [IO.Path]::GetFileNameWithoutExtension($main)
            if ($seen.ContainsKey($main) -or $sid -in $ExcludeSessionIds) { continue }
            $seen[$main] = $true
            $a = Get-SessionActivity -Path $main -BusyMinutes $BusyMinutes
            $row = [pscustomobject]@{ SessionId = $sid; Project = $d.Name; State = $a.State; LastWrite = $a.LastWrite }
            if ($a.State -eq 'working') { $working += $row } else { $idle += $row }
        }
    }
    return [pscustomobject]@{ Working = $working; Idle = $idle }
}

# 優先度の順（小さいほど先）。urgent は利用者が指定したときだけ使う。書いていない・知らない値は normal と同じ
function Get-PriorityRank {
    param([string]$Priority)
    switch ($Priority) { 'urgent' { return 0 } 'high' { return 1 } 'low' { return 3 } default { return 2 } }
}

# assignee が自分に合うか（any・自分の ID・自分の道具の名前）
function Test-LoopAssignee {
    param([string]$Me, [string]$Assignee)
    if (-not $Assignee -or $Assignee -eq 'any') { return $true }
    return ($Me -eq $Assignee) -or (($Me -split '-') -contains $Assignee)
}

# 受付（inbox.md）の未整理の件: 「## 」見出し 1 つが 1 件。書く場所は問わない（冒頭の案内の下でも、末尾の目印の下でもよい）。
# 数えないもの: コードの囲み（```）の中（書き方の例）、「## 手が空いた時に実行するタスク」の節（次の「## 」まで）。
# Urgent は、そのうち「優先: 緊急」と書かれた件数
function Get-InboxSummary {
    param($Config)
    $count = 0; $urgent = 0
    $file = Join-Path $Config.controlRepoPath 'inbox.md'
    if (Test-Path -LiteralPath $file) {
        $fence = $false; $inItem = $false
        foreach ($l in (Read-LoopText $file) -split '\r?\n') {
            if ($l -match '^\s*```') { $fence = -not $fence; continue }
            if ($fence) { continue }
            if ($l -match '^##\s+\S') {
                $inItem = -not ($l -match '^##\s+手が空いた時に実行するタスク')
                if ($inItem) { $count++ }
                continue
            }
            if ($inItem -and $l -match '^優先[:：]\s*(緊急|urgent)') { $urgent++ }
        }
    }
    return [pscustomobject]@{ Count = $count; Urgent = $urgent }
}

# 「間隔:」の書き方を日数にする（毎回 = 0、省略・読めないときは 7）
function ConvertTo-IntervalDays {
    param([string]$Text)
    $t = ($Text -replace '\s', '')
    if (-not $t) { return 7 }
    if ($t -match '毎回') { return 0 }
    if ($t -match '毎日') { return 1 }
    if ($t -match '毎週') { return 7 }
    if ($t -match '毎月') { return 30 }
    if ($t -match '^(\d+)日') { return [int]$Matches[1] }
    if ($t -match '日(\d+)回') { return 1 }
    if ($t -match '週(\d+)回') { return [math]::Max(1, [int][math]::Floor(7 / [math]::Max(1, [int]$Matches[1]))) }
    if ($t -match '月(\d+)回') { return [math]::Max(1, [int][math]::Floor(30 / [math]::Max(1, [int]$Matches[1]))) }
    return 7
}

# inbox.md の「## 手が空いた時に実行するタスク」の定義（### <案件>: <件名>）を読む。
# コードの囲み（```）の中と、見出しが「（停止）」で始まるものは読まない。due = 間隔の内に実施していない
function Get-IdleDefinitions {
    param($Config)
    $defs = @()
    $file = Join-Path $Config.controlRepoPath 'inbox.md'
    if (-not (Test-Path -LiteralPath $file)) { return $defs }
    $in = $false; $fence = $false; $cur = $null
    foreach ($l in (Read-LoopText $file) -split '\r?\n') {
        if ($l -match '^\s*```') { $fence = -not $fence; continue }
        if ($fence) { continue }
        if ($l -match '^##\s+手が空いた時に実行するタスク') { $in = $true; continue }
        if (-not $in) { continue }
        if ($l -match '^##\s' -or $l -match '<!--\s*ここから下に追記') { break }
        if ($l -match '^###\s+(.+?)\s*$') {
            if ($cur) { $defs += $cur }
            $cur = $null
            $head = $Matches[1]
            if ($head -match '^[（(]停止[）)]') { continue }
            $project = ''; $title = $head
            if ($head -match '^([^:：]+)[:：]\s*(.+)$') { $project = $Matches[1].Trim(); $title = $Matches[2].Trim() }
            $cur = [pscustomobject]@{ project = $project; title = $title; stage = 'propose'; interval = ''; intervalDays = 7; last = ''; due = $true }
            continue
        }
        if (-not $cur) { continue }
        if ($l -match '^段階[:：]\s*(.*)$') { $cur.stage = $(if ($Matches[1] -match '実装|implement') { 'implement' } else { 'propose' }) }
        elseif ($l -match '^間隔[:：]\s*(.*)$') { $cur.interval = $Matches[1].Trim(); $cur.intervalDays = ConvertTo-IntervalDays $Matches[1] }
        elseif ($l -match '^最終実施[:：]\s*(.*)$') { $cur.last = $Matches[1].Trim() }
    }
    if ($cur) { $defs += $cur }
    foreach ($d in $defs) {
        if ($d.last -match '(\d{4})-(\d{2})-(\d{2})') {
            try {
                $date = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
                $d.due = (((Get-Date).Date - $date).TotalDays -ge $d.intervalDays)
            }
            catch { $d.due = $true }
        }
    }
    return $defs
}

Export-ModuleMember -Function *
