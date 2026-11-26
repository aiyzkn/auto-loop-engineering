#requires -Version 7.0
<#
.SYNOPSIS
  auto-loop のスクリプトの通し試験。一時フォルダに「リモート（bare）+ エージェント 2 つ分の clone」を作って確かめる。
.DESCRIPTION
  ネットワーク・GitHub・利用者の ~/.claude には触れない（AUTO_LOOP_HOME を一時フォルダに向ける）。
  確かめること: 起票 → 一覧 → 担当の主張 → 二重の主張の拒否 → push の競り負け → 印 → 引き継ぎ → 主張の喪失の検出 → 解放と保管 → 同期の競合 → 着手前の確認
              → 優先度（緊急）と一覧の順 → 自動起動の判断（kick.ps1 -DryRun。セッションは起こさない）→ 手が空いた時のタスクの定義 → 再開の指示の案内 → 配布先とのずれ（比べ方）
  自動起動・自動再開の場所は、環境変数（AUTO_LOOP_AUTO_RESUME_HOME・AUTO_LOOP_CLAUDE_PROJECTS）で一時フォルダに向ける。タスクスケジューラには触れない
.EXAMPLE
  pwsh -NoProfile -File tests/smoke.ps1
  pwsh -NoProfile -File tests/smoke.ps1 -Keep    # 一時フォルダを残す
  pwsh -NoProfile -File tests/smoke.ps1 -SkillsRepo <yzkn/skills の clone>   # 配布先とのずれも見る（手元に取得済みの upstream/main と。取得はしない）
#>
param(
    [switch]$Keep,
    [string]$SkillsRepo = '',            # 配布先 yzkn/skills の clone（空なら AUTO_LOOP_SKILLS_REPO。どちらも無ければ実物との比較は飛ばす）
    [string]$SkillsRef = 'upstream/main', # 配布先の比べる版（手元に取得済みのもの）
    [string]$KitRef = 'HEAD'              # キット（正本）の比べる版
)
$ErrorActionPreference = 'Stop'
$scripts = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/auto-loop/scripts'
$root = Join-Path ([IO.Path]::GetTempPath()) ('auto-loop-smoke-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $root | Out-Null
$script:fail = 0; $script:pass = 0

function Check([string]$Name, [bool]$Cond, [string]$Detail = '') {
    if ($Cond) { $script:pass++; Write-Output "  ok   $Name" }
    else { $script:fail++; Write-Output "  FAIL $Name $(if ($Detail) { "`n       $($Detail -replace "`n", "`n       ")" })" }
}
function Run([string]$Agent, [string]$Script, [string[]]$ScriptArgs = @()) {
    $env:AUTO_LOOP_HOME = Join-Path $root "home-$Agent"
    $env:AUTO_LOOP_AGENT_ID = $null
    $ErrorActionPreference = 'Continue'
    $out = @(& pwsh -NoProfile -File (Join-Path $scripts $Script) @ScriptArgs 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}
function Gx([string]$Dir, [string[]]$GitArgs) {
    $ErrorActionPreference = 'Continue'
    $out = @(& git -C $Dir @GitArgs 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}
$utf8 = [Text.UTF8Encoding]::new($false)
try { [Console]::OutputEncoding = $utf8 } catch { }

# キット（正本）と配布先（yzkn/skills）の対応。値は git の blob・ツリーの値で比べる（改行の展開に左右されない）
$distMap = @(
    [pscustomobject]@{ Name = 'auto-loop'; Kit = 'skills/auto-loop'; Dist = 'packages/claude-skill-auto-loop/skills/auto-loop' }
    [pscustomobject]@{ Name = 'auto-resume-global/SKILL.md'; Kit = 'skills/auto-resume-global/SKILL.md'; Dist = 'packages/claude-skill-auto-resume-global/skills/auto-resume-global/SKILL.md' }
    [pscustomobject]@{ Name = 'auto-resume-global/scripts'; Kit = 'skills/auto-resume-global/scripts'; Dist = 'packages/claude-skill-auto-resume-global/skills/auto-resume-global/scripts' }
    [pscustomobject]@{ Name = 'auto-resume-global/README.md'; Kit = 'skills/auto-resume-global/README.md'; Dist = 'packages/claude-skill-auto-resume-global/README.md' }
    [pscustomobject]@{ Name = 'auto-resume-global/MANUAL.md'; Kit = 'skills/auto-resume-global/MANUAL.md'; Dist = 'packages/claude-skill-auto-resume-global/MANUAL.md' }
)
function Compare-Distribution([string]$KitDir, [string]$KitRef, [string]$DistDir, [string]$DistRef) {
    $val = { param($Dir, $Spec) $r = Gx $Dir @('rev-parse', '--verify', '-q', $Spec); if ($r.Code -eq 0) { $r.Text.Trim() } else { '(無い)' } }
    foreach ($m in $distMap) {
        $k = & $val $KitDir "${KitRef}:$($m.Kit)"; $d = & $val $DistDir "${DistRef}:$($m.Dist)"
        [pscustomobject]@{ Name = $m.Name; Same = ($k -eq $d -and $k -ne '(無い)'); KitValue = $k; DistValue = $d }
    }
    # 配布先のスキルのフォルダに、キットに無いものが足されていないか（README・MANUAL はパッケージの直下へ、DISTRIBUTION.md は配らない）
    $names = { param($Dir, $Spec) $r = Gx $Dir @('ls-tree', '--name-only', $Spec); if ($r.Code -eq 0) { (@($r.Text -split "`n" | ForEach-Object { Split-Path -Leaf $_.Trim() } | Where-Object { $_ }) | Sort-Object) -join ',' } else { '(無い)' } }
    $kn = (@((& $names $KitDir "${KitRef}:skills/auto-resume-global") -split ',' | Where-Object { $_ -notin @('README.md', 'MANUAL.md', 'DISTRIBUTION.md') })) -join ','
    $dn = & $names $DistDir "${DistRef}:packages/claude-skill-auto-resume-global/skills/auto-resume-global"
    [pscustomobject]@{ Name = 'auto-resume-global の中身（名前）'; Same = ($kn -eq $dn); KitValue = $kn; DistValue = $dn }
}

try {
    $a = Join-Path $root 'ctl-a'; $b = Join-Path $root 'ctl-b'; $bare = Join-Path $root 'ctl.git'

    Write-Output '1. 指令リポジトリの作成と導入'
    $env:AUTO_LOOP_HOME = Join-Path $root 'home-a'
    $r = (Run 'a' 'new-control-repo.ps1' @('-Path', $a)).Text
    Check 'ひな形から作れる' ((Test-Path (Join-Path $a 'AGENTS.md')) -and (Test-Path (Join-Path $a '.gitattributes'))) $r
    & git init -q --bare -b main $bare
    Gx $a @('remote', 'add', 'origin', $bare) | Out-Null
    Check '最初の push' ((Gx $a @('push', '-q', 'origin', 'main')).Code -eq 0)
    Gx $root @('clone', '-q', $bare, $b) | Out-Null
    foreach ($x in @(@('a', $a), @('b', $b))) {
        $i = Run $x[0] 'install.ps1' @('-NoCopy', '-AgentId', "pc-$($x[0])-claude", '-ControlRepoPath', $x[1])
        Check "導入 $($x[0])" ($i.Code -eq 0 -and (Test-Path (Join-Path $root "home-$($x[0])/config.json"))) $i.Text
    }
    $i2 = Run 'a' 'install.ps1' @('-NoCopy')
    $cfgA = Get-Content (Join-Path $root 'home-a/config.json') -Raw | ConvertFrom-Json
    Check '導入の 2 回目は設定を保つ' ($cfgA.agentId -eq 'pc-a-claude' -and $cfgA.controlRepoPath) $i2.Text

    Write-Output '2. 案件と起票'
    New-Item -ItemType Directory -Force (Join-Path $a 'projects/demo') | Out-Null
    $target = Join-Path $root 'target'; $targetBare = Join-Path $root 'target.git'
    $proj = [IO.File]::ReadAllText((Join-Path $a 'templates/project.md'), $utf8)
    $proj = $proj + "`n## リポジトリ`n`n| キー | ホスト | リポジトリ | アカウント | 本流リモート | 基準ブランチ | 備考 |`n|---|---|---|---|---|---|---|`n| ``main`` | - | ``target`` | - | ``origin`` | ``main`` | 試験用 |`n"
    $proj = $proj -replace '(?s)## リポジトリ.*?(?=## 進め方)', ''
    [IO.File]::WriteAllText((Join-Path $a 'projects/demo/project.md'), $proj, $utf8)
    $n = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '試験: 競合の確認', '-Slug', 'race', '-Stage', 'implement', '-Request', '原文 $1 そのまま')
    $id = (($n.Text -split "`n")[0] -replace '^OK ', '').Trim()
    $taskRel = "projects/demo/tasks/$id.md"
    Check '起票できる' ($n.Code -eq 0 -and (Test-Path (Join-Path $a $taskRel))) $n.Text
    $taskText = [IO.File]::ReadAllText((Join-Path $a $taskRel), $utf8)
    Check 'ひな形の置き換えが残っていない・原文がそのまま' ($taskText -notmatch '\{\{' -and $taskText.Contains('原文 $1 そのまま') -and -not $taskText.Contains("`r"))
    $n2 = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '2 件目', '-Slug', 'race')
    Check '同じ名前は -2 になる' ($n2.Text -match "OK $id-2")
    $n3 = Run 'a' 'new-task.ps1' @('-Project', 'nope', '-Title', 'x')
    Check '無い案件は起票しない' ($n3.Code -eq 1)
    $s = Run 'a' 'sync.ps1' @('-Message', 'intake: demo に 2 件')
    Check '同期（push）' ($s.Code -eq 0 -and $s.Text -match 'pushed') $s.Text
    $st = Run 'b' 'status.ps1' @('-Json')
    $j = $st.Text | ConvertFrom-Json
    Check 'b から 2 件見える' (@($j.tasks).Count -eq 2 -and $j.agentId -eq 'pc-b-claude') $st.Text

    Write-Output '3. 担当の主張'
    $c1 = Run 'a' 'claim.ps1' @('claim', $id)
    Check 'a が担当できる' ($c1.Code -eq 0 -and (Test-Path (Join-Path $root "home-a/state/active/demo--$id.json"))) $c1.Text
    $c2 = Run 'b' 'claim.ps1' @('claim', $id)
    Check 'b は担当できない（終了コード 2）' ($c2.Code -eq 2 -and $c2.Text -match 'pc-a-claude が担当中') $c2.Text
    Check 'b の作業コピーは汚れていない' (-not (Gx $b @('status', '--porcelain')).Text.Trim())
    $c3 = Run 'a' 'claim.ps1' @('claim', $id)
    Check 'a の再主張は継続になる' ($c3.Code -eq 0) $c3.Text

    Write-Output '3b. 同じ PC・同じエージェントの 2 つのセッション（20261120-no-parallel-sessions）'
    $oldSid = $env:CLAUDE_CODE_SESSION_ID; $oldPid = $env:CLAUDE_PID; $oldProj = $env:AUTO_LOOP_CLAUDE_PROJECTS
    $sessProj = Join-Path $root 'sess-projects'; New-Item -ItemType Directory -Force (Join-Path $sessProj 'p') | Out-Null
    $env:AUTO_LOOP_CLAUDE_PROJECTS = $sessProj
    $holder = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 600') -PassThru -WindowStyle Hidden
    try {
        $sidX = 'sess-x-' + [Guid]::NewGuid().ToString('N').Substring(0, 8); $sidY = 'sess-y-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $logX = Join-Path $sessProj "p/$sidX.jsonl"; $logY = Join-Path $sessProj "p/$sidY.jsonl"
        $recWork = '{"type":"user","message":{"role":"user","content":"作業して"}}'
        $recTool = '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}'
        $recDone = '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"終わりました"}]}}'
        $recLimit = '{"type":"assistant","error":"rate_limit","apiError":"usage_limit_reached","message":{"role":"assistant","content":[{"type":"text","text":"limit"}]}}'
        $as = { param($Sid, $ProcId) $env:CLAUDE_CODE_SESSION_ID = $Sid; $env:CLAUDE_PID = "$ProcId" }
        $markOf = { param($T) Get-Content (Join-Path $root "home-a/state/active/demo--$T.json") -Raw | ConvertFrom-Json }
        # X は手を動かしている（最後が利用者の入力）
        [IO.File]::WriteAllText($logX, "$recWork`n", $utf8)
        $n3 = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '試験: セッション', '-Slug', 'sess', '-Stage', 'implement')
        $id3 = (($n3.Text -split "`n")[0] -replace '^OK ', '').Trim()
        Run 'a' 'sync.ps1' @('-Message', 'intake sess') | Out-Null
        & $as $sidX $holder.Id
        $s1 = Run 'a' 'claim.ps1' @('claim', $id3)
        $mark = & $markOf $id3
        Check 'X が担当し、印にセッションが残る' ($s1.Code -eq 0 -and $mark.sessionId -eq $sidX -and $mark.pid -eq $holder.Id -and $mark.processStart) $s1.Text
        & $as $sidY $PID
        $s2 = Run 'a' 'claim.ps1' @('claim', $id3)
        Check 'Y は claim できない（X が作業中。終了コード 2）' ($s2.Code -eq 2 -and $s2.Text -match '別のセッション') $s2.Text
        $s3 = Run 'a' 'claim.ps1' @('heartbeat', $id3, '-Note', 'Y から')
        Check 'Y は heartbeat もできない' ($s3.Code -eq 2) $s3.Text
        $s4 = Run 'a' 'claim.ps1' @('release', $id3, '-Status', 'ready')
        Check 'Y は release もできない（印は残る）' ($s4.Code -eq 2 -and (Test-Path (Join-Path $root "home-a/state/active/demo--$id3.json"))) $s4.Text
        Check 'Y の失敗で作業コピーは汚れない' (-not (Gx $a @('status', '--porcelain')).Text.Trim())
        $st6 = Run 'a' 'status.ps1' @('-Json', '-NoPull')
        $act = @(($st6.Text | ConvertFrom-Json).active | Where-Object { $_.task -eq $id3 })
        Check '一覧（Y から）: 別のセッションが作業中と出る' ($act.Count -eq 1 -and $act[0].otherSessionLive -and $act[0].sessionState -eq 'working') $st6.Text
        Check '一覧（-Json）: thisSession は真偽で出る' ($act.Count -eq 1 -and $act[0].thisSession -is [bool] -and -not $act[0].thisSession) $st6.Text
        # X が上限で止まった → Y（フォークの再開など）が続けられる
        [IO.File]::AppendAllText($logX, "$recLimit`n", $utf8)
        $s5 = Run 'a' 'claim.ps1' @('heartbeat', $id3, '-Note', 'Y が続ける')
        $mark = & $markOf $id3
        Check 'X が上限で止まれば、Y が続けられ、印が Y になる' ($s5.Code -eq 0 -and $mark.sessionId -eq $sidY -and $mark.pid -eq $PID) $s5.Text
        # Y が作業中なら、X が戻ってきても止まる
        [IO.File]::WriteAllText($logY, "$recTool`n", $utf8)
        & $as $sidX $holder.Id
        $s6 = Run 'a' 'claim.ps1' @('heartbeat', $id3, '-Note', 'X から')
        Check 'Y の作業中に X が戻っても止まる' ($s6.Code -eq 2) $s6.Text
        # Y が入力待ちになれば、X が続けられる
        [IO.File]::WriteAllText($logY, "$recDone`n", $utf8)
        $s7 = Run 'a' 'claim.ps1' @('claim', $id3)
        Check 'Y が入力待ちなら X が続けられる' ($s7.Code -eq 0 -and (& $markOf $id3).sessionId -eq $sidX) $s7.Text
        # X のプロセスが終われば、Y が続けられる（記録が作業中の形のままでも）
        [IO.File]::WriteAllText($logX, "$recWork`n", $utf8)
        Stop-Process -Id $holder.Id -Force; $holder.WaitForExit()
        & $as $sidY $PID
        $s8 = Run 'a' 'claim.ps1' @('release', $id3, '-Status', 'done', '-Note', '試験の後始末')
        Check 'X のプロセスが終われば、Y が解放できる' ($s8.Code -eq 0) $s8.Text
        # セッションの情報が無い道具（環境変数が無い）は、エージェント ID 単位のまま
        & $as $null $null; $env:CLAUDE_PID = $null
        $n4 = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '試験: セッション無し', '-Slug', 'nosess', '-Stage', 'implement')
        $id4 = (($n4.Text -split "`n")[0] -replace '^OK ', '').Trim()
        Run 'a' 'sync.ps1' @('-Message', 'intake nosess') | Out-Null
        $s9 = Run 'a' 'claim.ps1' @('claim', $id4); $s10 = Run 'a' 'claim.ps1' @('claim', $id4)
        $mark4 = & $markOf $id4
        Check 'セッションの情報が無ければ、いまの動きのまま（継続できる・印に sessionId が無い）' ($s9.Code -eq 0 -and $s10.Code -eq 0 -and -not $mark4.PSObject.Properties['sessionId']) "$($s9.Text)`n$($s10.Text)"
        Run 'a' 'claim.ps1' @('release', $id4, '-Status', 'done') | Out-Null
        # 指令リポジトリの排他: 別のプロセスが持っている間は取れず、放せば取れる
        Import-Module (Join-Path $scripts 'lib/AutoLoop.psm1') -Force
        $ready = Join-Path $root 'lock-held'
        $q = { param($S) $S.Replace("'", "''") }
        $holdCmd = "Import-Module '$(& $q (Join-Path $scripts 'lib/AutoLoop.psm1'))'; `$l = Enter-ControlLock ([pscustomobject]@{ controlRepoPath = '$(& $q $a)' }); New-Item -ItemType File '$(& $q $ready)' | Out-Null; Start-Sleep -Seconds 4; Exit-ControlLock `$l"
        $lk = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-Command', $holdCmd)
        for ($w = 0; $w -lt 150 -and -not (Test-Path $ready); $w++) { Start-Sleep -Milliseconds 100 }
        $blocked = $false
        try { $l2 = Enter-ControlLock ([pscustomobject]@{ controlRepoPath = $a }) -TimeoutSeconds 1; Exit-ControlLock $l2 } catch { $blocked = $true }
        $lk.WaitForExit()
        $l3 = $null; try { $l3 = Enter-ControlLock ([pscustomobject]@{ controlRepoPath = $a }) -TimeoutSeconds 5 } catch { }
        Check '指令リポジトリの排他（持たれている間は待ち、放されれば取れる）' ((Test-Path $ready) -and $blocked -and $null -ne $l3)
        Exit-ControlLock $l3
    }
    finally {
        if (-not $holder.HasExited) { Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue }
        $env:CLAUDE_CODE_SESSION_ID = $oldSid; $env:CLAUDE_PID = $oldPid; $env:AUTO_LOOP_CLAUDE_PROJECTS = $oldProj
    }

    Write-Output '3c. 別の案件の同じ ID と、古い名前の印（20261121-task-id-collision）'
    New-Item -ItemType Directory -Force (Join-Path $a 'projects/demo2') | Out-Null
    Copy-Item (Join-Path $a 'projects/demo/project.md') (Join-Path $a 'projects/demo2/project.md')
    $nx = Run 'a' 'new-task.ps1' @('-Project', 'demo2', '-Title', '別の案件', '-Slug', 'race')
    Check '別の案件でも、全案件で重ならない ID になる' ($nx.Code -eq 0 -and $nx.Text -match "OK $id-3") $nx.Text
    Remove-Item -Recurse -Force (Join-Path $a 'projects/demo2')   # 送らない（後の試験の件数を変えない）
    $actDir = Join-Path $root 'home-a/state/active'
    $newMark = Join-Path $actDir "demo--$id.json"; $legacy = Join-Path $actDir "$id.json"
    # 古い名前の印が別の案件のもの → 読まない・消さない
    [IO.File]::WriteAllText($legacy, (@{ task = $id; project = 'demo2'; agentId = 'pc-a-claude'; cwd = $root } | ConvertTo-Json), $utf8)
    $hx = Run 'a' 'claim.ps1' @('heartbeat', $id, '-Project', 'demo', '-Note', '別の案件の古い印')
    $stx = @((Run 'a' 'status.ps1' @('-Json', '-NoPull')).Text | ConvertFrom-Json | ForEach-Object { $_.active } | Where-Object { $_.task -eq $id })
    Check '別の案件の古い名前の印は残し、自分の印は新しい名前' ($hx.Code -eq 0 -and (Test-Path $legacy) -and (Test-Path $newMark) -and ((Get-Content $legacy -Raw | ConvertFrom-Json).project -eq 'demo2')) $hx.Text
    Check '一覧には案件ごとに 1 つずつ出る' ($stx.Count -eq 2 -and (@($stx.project) -contains 'demo') -and (@($stx.project) -contains 'demo2')) ($stx | ConvertTo-Json)
    Remove-Item $legacy -Force
    # 古い名前の印が同じ案件のもの → 新しい名前に移す
    Move-Item $newMark $legacy
    $stl = @((Run 'a' 'status.ps1' @('-Json', '-NoPull')).Text | ConvertFrom-Json | ForEach-Object { $_.active } | Where-Object { $_.task -eq $id })
    Check '一覧は古い名前の印も読む' ($stl.Count -eq 1 -and $stl[0].project -eq 'demo')
    $hm = Run 'a' 'claim.ps1' @('heartbeat', $id, '-Note', '古い印の移し替え')
    Check '同じ案件の古い名前の印は、新しい名前に移る' ($hm.Code -eq 0 -and (Test-Path $newMark) -and -not (Test-Path $legacy)) $hm.Text

    Write-Output '4. push の競り負け（b の push の直前に a が主張する）'
    $id2 = "$id-2"
    $hook = Join-Path $b '.git/hooks/pre-push'
    $marker = (Join-Path $root 'raced').Replace('\', '/')
    $hookBody = "#!/bin/sh`nif [ ! -f '$marker' ]; then`n  touch '$marker'`n  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX`n  AUTO_LOOP_HOME='$((Join-Path $root 'home-a').Replace('\', '/'))' pwsh -NoProfile -File '$((Join-Path $scripts 'claim.ps1').Replace('\', '/'))' claim $id2 >/dev/null 2>&1`nfi`nexit 0`n"
    [IO.File]::WriteAllText($hook, $hookBody, $utf8)
    $c4 = Run 'b' 'claim.ps1' @('claim', $id2)
    Remove-Item $hook -Force
    Check 'b は競り負けて引き下がる' ($c4.Code -eq 2 -and $c4.Text -match 'pc-a-claude が担当中') $c4.Text
    Check '競り負けのあと b に残骸が無い' (-not (Gx $b @('status', '--porcelain')).Text.Trim() -and (Gx $b @('rev-list', '--count', 'origin/main..HEAD')).Text.Trim() -eq '0')
    Check 'リモートの担当は a' ((Gx $b @('show', "origin/main:projects/demo/tasks/$id2.md")).Text -match 'claimed_by: pc-a-claude')

    Write-Output '5. 印・引き継ぎ・主張の喪失'
    $fileA = Join-Path $a $taskRel
    [IO.File]::WriteAllText($fileA, ([IO.File]::ReadAllText($fileA, $utf8) -replace '- 次の一手:', '- 次の一手: B を実装する'), $utf8)
    $h = Run 'a' 'claim.ps1' @('heartbeat', $id, '-Status', 'waiting', '-Note', 'E-2 の判断待ち')
    Check '印と本文の変更が送られる' ($h.Code -eq 0 -and (Gx $b @('pull', '-q', '--rebase')).Code -eq 0 -and ([IO.File]::ReadAllText((Join-Path $b $taskRel), $utf8) -match '(?s)status: waiting.*次の一手: B を実装する.*checkpoint（waiting）: E-2 の判断待ち')) $h.Text
    $t = Run 'b' 'claim.ps1' @('takeover', $id, '-Note', '利用者の指示')
    Check 'b が引き継げる' ($t.Code -eq 0 -and $t.Text -match 'pc-b-claude が担当') $t.Text
    $h2 = Run 'a' 'claim.ps1' @('heartbeat', $id, '-Note', '続き')
    Check 'a は主張の喪失に気づく（終了コード 2）' ($h2.Code -eq 2 -and $h2.Text -match '主張が失われている') $h2.Text

    Write-Output '6. 解放と保管'
    $rv = Run 'b' 'claim.ps1' @('heartbeat', $id, '-Status', 'review', '-Note', 'PR を作成。マージ待ち')
    Check 'マージ待ち（review）にでき、担当は保たれる' ($rv.Code -eq 0 -and ([IO.File]::ReadAllText((Join-Path $b $taskRel), $utf8) -match '(?s)status: review.*claimed_by: pc-b-claude')) $rv.Text
    $rvs = Run 'b' 'status.ps1' @()
    Check '一覧で review は人の対応が要るものに数える' ($rvs.Text -match '人の対応が要る: \d+ 件（[^）]*review') $rvs.Text
    $rl = Run 'b' 'claim.ps1' @('release', $id, '-Status', 'done', '-Note', '完了')
    Check '完了で archive に移る' ($rl.Code -eq 0 -and (Test-Path (Join-Path $b "projects/demo/archive/$id.md")) -and -not (Test-Path (Join-Path $b $taskRel)) -and -not (Test-Path (Join-Path $root "home-b/state/active/demo--$id.json"))) $rl.Text
    $c5 = Run 'a' 'claim.ps1' @('claim', $id)
    Check '保管済みは担当できない' ($c5.Code -eq 2) $c5.Text
    $st2 = Run 'a' 'status.ps1' @()
    Check '一覧は未完了だけ（1 件）' ($st2.Text -match [regex]::Escape($id2) -and $st2.Text -notmatch "$([regex]::Escape($id))\s") $st2.Text

    Write-Output '7. 受付の件数と、同期の競合'
    Run 'a' 'sync.ps1' @('-PullOnly') | Out-Null; Gx $b @('pull', '-q', '--rebase') | Out-Null
    [IO.File]::AppendAllText((Join-Path $a 'inbox.md'), "`n## demo: a からの依頼`n本文`n", $utf8)
    [IO.File]::AppendAllText((Join-Path $b 'inbox.md'), "`n## demo: b からの依頼`n本文`n", $utf8)
    $sa = Run 'a' 'sync.ps1' @('-Message', 'inbox a')
    $sb = Run 'b' 'sync.ps1' @('-Message', 'inbox b')
    Check '後から送った側は競合を報告する' ($sa.Code -eq 0 -and $sb.Code -eq 1 -and $sb.Text -match 'conflict') $sb.Text
    Check '競合のあと rebase の途中で残らない' ((Gx $b @('status')).Text -notmatch 'rebase in progress')
    $st3 = Run 'a' 'status.ps1' @('-Json', '-NoPull')
    Check '受付の未整理が 1 件' (($st3.Text | ConvertFrom-Json).inbox -eq 1) $st3.Text

    Write-Output '8. 着手前の確認'
    & git init -q --bare -b main $targetBare
    Gx $root @('clone', '-q', $targetBare, $target) | Out-Null
    [IO.File]::WriteAllText((Join-Path $target 'a.txt'), "x`n", $utf8)
    Gx $target @('add', '-A') | Out-Null; Gx $target @('commit', '-q', '-m', 'init') | Out-Null; Gx $target @('push', '-q', 'origin', 'HEAD:main') | Out-Null
    $wt = Join-Path $root 'target-wt'
    Gx $target @('worktree', 'add', '-q', '-b', 'loop/x', $wt) | Out-Null
    [IO.File]::WriteAllText((Join-Path $wt 'half.txt'), "途中`n", $utf8)
    $p0 = Run 'a' 'preflight.ps1' @('-Project', 'demo')
    Check '場所が未登録なら WARN' ($p0.Text -match 'WARN 作業コピー main: この PC での場所が未登録') $p0.Text
    $cfgPath = Join-Path $root 'home-a/config.json'
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfg.repoPaths = [pscustomobject]@{ 'demo/main' = $target }
    [IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 5), $utf8)
    $p1 = Run 'a' 'preflight.ps1' @('-Project', 'demo')
    Check '作業コピーと、作業ツリーの置き土産を検出する' ($p1.Code -eq 0 -and $p1.Text -match 'OK\s+作業コピー main' -and $p1.Text -match '未コミットの変更が 1 件。止まった委任') $p1.Text
    Gx $target @('remote', 'set-url', 'origin', (Join-Path $root 'missing.git')) | Out-Null
    $p2 = Run 'a' 'preflight.ps1' @('-Project', 'demo')
    Check '本流のリモートが違えば NG（終了コード 1）' ($p2.Code -eq 1 -and $p2.Text -match 'NG\s+作業コピー main') $p2.Text
    Gx $target @('remote', 'set-url', 'origin', $targetBare) | Out-Null
    Gx $target @('worktree', 'add', '-q', '-b', 'loop/y', (Join-Path $root 'target-wt2')) | Out-Null
    $p3 = Run 'a' 'preflight.ps1' @('-Project', 'demo')
    Check '変更の無い作業ツリーは 1 行にまとめる' ($p3.Text -match '変更の無い作業ツリーが 1 本' -and $p3.Text -notmatch 'target-wt2') $p3.Text
    Check 'ログに残る' ((Get-Content (Join-Path $root 'home-a/logs/auto-loop.log') -Raw) -match '\[preflight\].*NG=1')

    Write-Output '9. 優先度（緊急）と一覧の順'
    $u = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '低い', '-Slug', 'low', '-Priority', 'low', '-Source', 'idle')
    $u2 = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '緊急の件', '-Slug', 'hot', '-Priority', 'urgent')
    $hotId = (($u2.Text -split "`n")[0] -replace '^OK ', '').Trim()
    $lowId = (($u.Text -split "`n")[0] -replace '^OK ', '').Trim()
    $hotText = [IO.File]::ReadAllText((Join-Path $a "projects/demo/tasks/$hotId.md"), $utf8)
    $lowText = [IO.File]::ReadAllText((Join-Path $a "projects/demo/tasks/$lowId.md"), $utf8)
    Check 'urgent・idle で起票できる' ($u.Code -eq 0 -and $u2.Code -eq 0 -and $hotText -match '(?m)^priority: urgent$' -and $lowText -match '(?m)^source: idle$') "$($u.Text)`n$($u2.Text)"
    $st4 = Run 'a' 'status.ps1' @('-Json', '-NoPull')
    $readyIds = @(($st4.Text | ConvertFrom-Json).tasks | Where-Object { $_.status -eq 'ready' } | ForEach-Object { $_.id })
    Check '一覧は、ready の中で緊急が先・低いものが後' ($readyIds.Count -ge 2 -and $readyIds[0] -eq $hotId -and $readyIds[-1] -eq $lowId) $st4.Text
    # order: 同じ優先度（normal）の中では order の小さいものが先、order の無いものは後ろ（古い順）
    $o1 = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '順 1', '-Slug', 'ord1')
    $o2 = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '順 2', '-Slug', 'ord2')
    $o3 = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '順 3', '-Slug', 'ord3')
    $oIds = @($o1, $o2, $o3 | ForEach-Object { (($_.Text -split "`n")[0] -replace '^OK ', '').Trim() })
    foreach ($pair in @(@($oIds[2], '5'), @($oIds[1], '20'))) {
        $f = Join-Path $a "projects/demo/tasks/$($pair[0]).md"
        [IO.File]::WriteAllText($f, ([IO.File]::ReadAllText($f, $utf8) -replace '(?m)^order:.*$', "order: $($pair[1])"), $utf8)
    }
    $st4b = Run 'a' 'status.ps1' @('-Json', '-NoPull')
    $normIds = @(($st4b.Text | ConvertFrom-Json).tasks | Where-Object { $_.status -eq 'ready' -and $_.id -in $oIds } | ForEach-Object { $_.id })
    Check '同じ優先度の中は order の順・無いものは後ろ' (($normIds -join ',') -eq (@($oIds[2], $oIds[1], $oIds[0]) -join ',')) ($normIds -join ',')
    Check 'ひな形に order の行がある' ([IO.File]::ReadAllText((Join-Path $a "projects/demo/tasks/$($oIds[0]).md"), $utf8) -match '(?m)^order:\s*$')
    $st5 = Run 'a' 'status.ps1' @('-NoPull')
    Check '一覧に緊急の件数が出る' ($st5.Text -match '緊急（priority: urgent）: 1 件') $st5.Text
    # 単独（solo）: 緊急の次・高の前。同じアカウントのエージェントが doing の間は exclusive に出る（AGENTS.md 7.3）
    $sl = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '単独の件', '-Slug', 'solo', '-Priority', 'solo')
    $hi = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '高い件', '-Slug', 'hi', '-Priority', 'high')
    $soloId = (($sl.Text -split "`n")[0] -replace '^OK ', '').Trim(); $hiId = (($hi.Text -split "`n")[0] -replace '^OK ', '').Trim()
    $st6 = Run 'a' 'status.ps1' @('-Json', '-NoPull')
    $readyIds6 = @(($st6.Text | ConvertFrom-Json).tasks | Where-Object { $_.status -eq 'ready' } | ForEach-Object { $_.id })
    Check 'solo で起票でき、緊急の次・高の前に並ぶ' ($sl.Code -eq 0 -and ($readyIds6[0..2] -join ',') -eq "$hotId,$soloId,$hiId") ($readyIds6 -join ',')
    $soloFile = Join-Path $a "projects/demo/tasks/$soloId.md"; $soloOrig = [IO.File]::ReadAllText($soloFile, $utf8)
    $rosterFile = Join-Path $a 'roster.md'; $rosterOrig = [IO.File]::ReadAllText($rosterFile, $utf8)
    [IO.File]::WriteAllText($soloFile, ($soloOrig -replace '(?m)^status:.*$', 'status: doing' -replace '(?m)^claimed_by:.*$', 'claimed_by: pc-z-claude'), $utf8)
    $rosterRows = "| ID | PC | 道具 | AI のアカウント | 得意・制約 | 備考 |`n|---|---|---|---|---|---|`n| ``pc-a-claude`` | A | Claude Code | ``acct1`` | | |`n| ``pc-z-claude`` | Z | Claude Code | {0} | | |`n"
    [IO.File]::WriteAllText($rosterFile, "# 名簿`n`n" + ($rosterRows -f '`acct1`'), $utf8)
    $ex1 = (Run 'a' 'status.ps1' @('-Json', '-NoPull')).Text | ConvertFrom-Json
    $ex1t = Run 'a' 'status.ps1' @('-NoPull')
    [IO.File]::WriteAllText($rosterFile, "# 名簿`n`n" + ($rosterRows -f '`acct2`'), $utf8)
    $ex2 = (Run 'a' 'status.ps1' @('-Json', '-NoPull')).Text | ConvertFrom-Json
    [IO.File]::WriteAllText($rosterFile, "# 名簿`n`n" + ($rosterRows -f '`<アカウントの呼び名>`'), $utf8)
    $ex3 = (Run 'a' 'status.ps1' @('-Json', '-NoPull')).Text | ConvertFrom-Json
    $rosterBlank = "| ID | PC | 道具 | AI のアカウント | 得意・制約 | 備考 |`n|---|---|---|---|---|---|`n| ``pc-a-claude`` | A | Claude Code | ``<アカウントの呼び名>`` | | |`n| ``pc-z-claude`` | Z | Claude Code | | | |`n| ``pc-z-copilot`` | Z | Copilot | | | |`n"
    [IO.File]::WriteAllText($rosterFile, "# 名簿`n`n" + $rosterBlank, $utf8)
    $ex4 = (Run 'a' 'status.ps1' @('-Json', '-NoPull')).Text | ConvertFrom-Json
    [IO.File]::WriteAllText($soloFile, ($soloOrig -replace '(?m)^status:.*$', 'status: doing' -replace '(?m)^claimed_by:.*$', 'claimed_by: pc-z-copilot'), $utf8)
    $ex5 = (Run 'a' 'status.ps1' @('-Json', '-NoPull')).Text | ConvertFrom-Json
    [IO.File]::WriteAllText($soloFile, ($soloOrig -replace '(?m)^status:.*$', 'status: doing' -replace '(?m)^claimed_by:.*$', 'claimed_by: pc-y-claude'), $utf8)
    $ex6 = (Run 'a' 'status.ps1' @('-Json', '-NoPull')).Text | ConvertFrom-Json
    Check '同じアカウントのエージェントの単独の doing は exclusive に出る' (@($ex1.exclusive).Count -eq 1 -and @($ex1.exclusive)[0].id -eq $soloId -and $ex1t.Text -match '緊急・単独の着手中（同じアカウント）') ($ex1 | ConvertTo-Json -Depth 4)
    Check 'アカウントが違えば exclusive に出ない（書いた呼び名と、空の既定の Claude も別）' (@($ex2.exclusive).Count -eq 0 -and @($ex3.exclusive).Count -eq 0) "$(@($ex2.exclusive).Count) / $(@($ex3.exclusive).Count)"
    Check 'アカウントの列が空・例のままなら、Claude のエージェントは全部同じアカウント（名簿に無い ID も）' (@($ex4.exclusive).Count -eq 1 -and @($ex6.exclusive).Count -eq 1) "$(@($ex4.exclusive).Count) / $(@($ex6.exclusive).Count)"
    Check 'Claude でないエージェントの単独の doing は、列が空なら exclusive に出ない' (@($ex5.exclusive).Count -eq 0) "$(@($ex5.exclusive).Count)"
    [IO.File]::WriteAllText($rosterFile, $rosterOrig, $utf8)
    [IO.File]::WriteAllText($soloFile, ($soloOrig -replace '(?m)^status:.*$', 'status: dropped'), $utf8)
    [IO.File]::WriteAllText((Join-Path $a "projects/demo/tasks/$hiId.md"), ([IO.File]::ReadAllText((Join-Path $a "projects/demo/tasks/$hiId.md"), $utf8) -replace '(?m)^status:.*$', 'status: dropped'), $utf8)

    Write-Output '10. 自動起動の判断（起こさない）'
    $arFake = Join-Path $root 'auto-resume-global'; $projFake = Join-Path $root 'claude-projects'
    New-Item -ItemType Directory -Force $projFake | Out-Null
    $env:AUTO_LOOP_AUTO_RESUME_HOME = $arFake; $env:AUTO_LOOP_CLAUDE_PROJECTS = $projFake
    $k0 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check 'auto-resume-global が無ければ見送る' ($k0.Code -eq 0 -and $k0.Text -match 'SKIP auto-resume-global が導入されていない') $k0.Text
    New-Item -ItemType Directory -Force $arFake | Out-Null
    $oldAdd = 'auto-loop で管理している作業（~/.claude/auto-loop/state/active/ に印がある）なら、続ける前に /auto-loop resume を実行し、指令リポジトリの状態ファイルを読んで前提を確かめ直してください。'
    [IO.File]::WriteAllText((Join-Path $arFake 'config.json'), (@{ resumePrompt = "続けてください。 $oldAdd"; rebootResumePrompt = '続けてください。' } | ConvertTo-Json), $utf8)
    $k1 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '担当中・ready があれば work を起こす判断' ($k1.Text -match 'KICK work' -and $k1.Text -match 'doing=1' -and $k1.Text -match '緊急=1') $k1.Text
    # 同じアカウントのほかのエージェントが単独を doing の間は起こさない（緊急の ready があれば起こす）。自分の単独なら起こす
    $hotFile = Join-Path $a "projects/demo/tasks/$hotId.md"; $hotOrig = [IO.File]::ReadAllText($hotFile, $utf8)
    [IO.File]::WriteAllText($rosterFile, "# 名簿`n`n" + ($rosterRows -f '`acct1`'), $utf8)
    [IO.File]::WriteAllText($soloFile, ($soloOrig -replace '(?m)^status:.*$', 'status: doing' -replace '(?m)^claimed_by:.*$', 'claimed_by: pc-z-claude'), $utf8)
    $kx1 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    [IO.File]::WriteAllText($hotFile, ($hotOrig -replace '(?m)^status:.*$', 'status: dropped'), $utf8)
    $kx2 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    [IO.File]::WriteAllText($soloFile, ($soloOrig -replace '(?m)^status:.*$', 'status: doing' -replace '(?m)^claimed_by:.*$', 'claimed_by: pc-a-claude'), $utf8)
    $kx3 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '同じアカウントのほかの単独の着手中: 緊急が無ければ見送り、あれば起こす' ($kx1.Text -match 'KICK work' -and $kx2.Text -match 'SKIP 同じアカウントのほかのエージェントが緊急・単独' ) "$($kx1.Text)`n$($kx2.Text)"
    Check '自分の単独の着手中は起こす（next が再開する）' ($kx3.Text -match 'KICK work' -and $kx3.Text -match "緊急・単独の着手中=$soloId") $kx3.Text
    [IO.File]::WriteAllText($hotFile, $hotOrig, $utf8); [IO.File]::WriteAllText($rosterFile, $rosterOrig, $utf8)
    [IO.File]::WriteAllText($soloFile, ($soloOrig -replace '(?m)^status:.*$', 'status: dropped'), $utf8)
    $k2 = Run 'a' 'kick.ps1' @('-SkipSystemChecks')
    Check '有効にしていなければ起こさない' ($k2.Text -match 'SKIP kick.enabled が false' -and -not (Test-Path (Join-Path $root 'home-a/state/kick.json'))) $k2.Text
    New-Item -ItemType Directory -Force (Join-Path $projFake 'p1') | Out-Null
    # セッションの記録の形（Claude Code の内部形式の要点だけ）
    $recUser = '{"parentUuid":null,"type":"user","message":{"role":"user","content":"作業して"}}'
    $recTool = '{"parentUuid":"a","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}'
    $recDone = '{"parentUuid":"b","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"終わりました"}]}}'
    $recNote = '{"parentUuid":"c","type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>done</task-notification>"}}'
    $recLimit = '{"parentUuid":"d","type":"assistant","apiError":"usage_limit_reached","message":{"role":"assistant","content":[{"type":"text","text":"limit"}]}}'
    $sFile = Join-Path $projFake 'p1/s.jsonl'
    [IO.File]::WriteAllText($sFile, "$recUser`n$recTool`n", $utf8)
    $k3 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check 'ほかのセッションが動いていれば見送る（ツールの呼び出し中）' ($k3.Text -match 'SKIP ほかのセッションが動いている') $k3.Text
    [IO.File]::WriteAllText($sFile, "$recUser`n$recTool`n$recDone`n$recNote`n", $utf8)
    $k3b = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '入力待ちのセッションは数えない（あとに付いた通知は飛ばす）' ($k3b.Text -match 'KICK work' -and $k3b.Text -match 'waiting-input=1') $k3b.Text
    [IO.File]::WriteAllText($sFile, "$recUser`n$recLimit`n", $utf8)
    $k3c = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '上限で止まったセッションは数えない' ($k3c.Text -match 'KICK work' -and $k3c.Text -match 'limit=1') $k3c.Text
    [IO.File]::WriteAllText($sFile, '', $utf8)
    $k3d = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '指示の無いセッションは数えない' ($k3d.Text -match 'KICK work' -and $k3d.Text -match 'empty=1') $k3d.Text
    # 本体の記録は古いが、サブエージェントの記録が新しい → 動いている
    [IO.File]::WriteAllText($sFile, "$recUser`n$recTool`n", $utf8)
    (Get-Item $sFile).LastWriteTime = (Get-Date).AddMinutes(-40)
    New-Item -ItemType Directory -Force (Join-Path $projFake 'p1/s/subagents') | Out-Null
    [IO.File]::WriteAllText((Join-Path $projFake 'p1/s/subagents/agent-1.jsonl'), "$recUser`n", $utf8)
    $k3e = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check 'サブエージェントが書いていれば動いているとみなす' ($k3e.Text -match 'SKIP ほかのセッションが動いている') $k3e.Text
    Remove-Item (Join-Path $projFake 'p1/s') -Recurse -Force
    (Get-Item $sFile).LastWriteTime = (Get-Date).AddMinutes(-40)
    Import-Module (Join-Path $scripts 'lib/AutoLoop.psm1') -Force
    Check '長く書かれていない作業中の形は stale（数えない）' ((Get-SessionActivity -Path $sFile -BusyMinutes 15).State -eq 'stale')
    $aLong = Get-SessionActivity -Path $sFile -BusyMinutes 15 -LongToolMinutes 240
    Check 'ツールの実行中（結果がまだ無い）は、longToolMinutes までは動いているとみなす' ($aLong.State -eq 'working' -and $aLong.PendingTool) ($aLong | Out-String)
    (Get-Item $sFile).LastWriteTime = (Get-Date).AddMinutes(-300)
    Check 'ツールの実行中でも、longToolMinutes を超えれば stale' ((Get-SessionActivity -Path $sFile -BusyMinutes 15 -LongToolMinutes 240).State -eq 'stale')
    [IO.File]::WriteAllText($sFile, "$recUser`n", $utf8)
    (Get-Item $sFile).LastWriteTime = (Get-Date).AddMinutes(-40)
    $aUser = Get-SessionActivity -Path $sFile -BusyMinutes 15 -LongToolMinutes 240
    Check 'ツールの実行中でなければ、longToolMinutes は効かない（stale）' ($aUser.State -eq 'stale' -and -not $aUser.PendingTool) ($aUser | Out-String)
    Remove-Item $sFile -Force
    [IO.File]::WriteAllText((Join-Path $arFake 'disabled'), '', $utf8)
    $k4 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check 'auto-resume-global が停止中なら見送る' ($k4.Text -match 'SKIP auto-resume-global が停止中') $k4.Text
    Remove-Item (Join-Path $arFake 'disabled') -Force
    [IO.File]::WriteAllText((Join-Path $root 'home-a/state/kick.json'), (@{ lastLaunchedAt = (Get-Date).AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:sszzz'); lastKind = 'work'; lastIdleAt = '' } | ConvertTo-Json), $utf8)
    $k5 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '前に起こしてから間が無ければ見送る' ($k5.Text -match 'SKIP 前に起こしてから') $k5.Text

    # 即時実行の印（ダッシュボードの「いま実行」「このタスクを実行」。state/kick/<ID>.json）
    $kn0 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks', '-Trigger', 'now')
    Check '即時実行: 印が無ければ何もしない' ($kn0.Text -match 'SKIP 即時実行の印が無い') $kn0.Text
    $reqRel = 'state/kick/pc-a-claude.json'; $reqPath = Join-Path $a $reqRel
    New-Item -ItemType Directory -Force (Split-Path -Parent $reqPath) | Out-Null
    $writeReq = { param([string]$T, [double]$AgoHours = 0) [IO.File]::WriteAllText($reqPath, (@{ requestedAt = (Get-Date).AddHours(-$AgoHours).ToString('yyyy-MM-ddTHH:mm:sszzz'); by = 'dashboard:test'; task = $T } | ConvertTo-Json), $utf8) }
    & $writeReq ''
    $kn1 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks', '-Trigger', 'now')
    Check '即時実行: 前に起こしてから間が無くても起こす判断' ($kn1.Text -match 'KICK work') $kn1.Text
    $mineId = @((Run 'a' 'status.ps1' @('-Json', '-NoPull')).Text | ConvertFrom-Json | ForEach-Object { $_.tasks } | Where-Object { $_.claimedBy -eq 'pc-a-claude' } | ForEach-Object { $_.id })[0]
    & $writeReq $mineId
    $kn2 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks', '-Trigger', 'now')
    Check '即時実行: 指定のタスクを渡す' ($kn2.Text -match 'KICK work' -and $kn2.Text -match "指定=$([regex]::Escape([string]$mineId))") $kn2.Text
    # ほかのエージェントが担当するタスクを指定されたら、見送らずにそのエージェントに回す（エスカレーション）
    $nE = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '試験: エスカレーション', '-Slug', 'escalate', '-Stage', 'implement')
    $idE = (($nE.Text -split "`n")[0] -replace '^OK ', '').Trim()
    $relE = "projects/demo/tasks/$idE.md"
    # 担当はほかのエージェント（pc-b-claude）。b の clone は 7 の競合の試験のあとなので、a の手元で担当を書いてコミットする
    $pE = Join-Path $a $relE
    [IO.File]::WriteAllText($pE, ([IO.File]::ReadAllText($pE, $utf8) -replace '(?m)^status: .*$', 'status: doing' -replace '(?m)^claimed_by:.*$', 'claimed_by: pc-b-claude'), $utf8)
    Gx $a @('add', '--', $relE) | Out-Null
    $gcE = Gx $a @('commit', '-q', '-m', 'claim by b', '--', $relE)
    $okE = ([IO.File]::ReadAllText($pE, $utf8) -match '(?m)^claimed_by: pc-b-claude$') -and $gcE.Code -eq 0
    $otherT = if ($okE) { [pscustomobject]@{ id = $idE; claimedBy = 'pc-b-claude' } } else { $null }
    if ($otherT) {
        & $writeReq $otherT.id
        $knE = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks', '-Trigger', 'now')
        Check '即時実行: ほかのエージェントが担当するタスクは、そのエージェントに回す（DryRun）' ($knE.Text -match "ESCALATE $([regex]::Escape([string]$otherT.claimedBy))（DryRun") $knE.Text
        $toRelE = "state/kick/$($otherT.claimedBy).json"
        Gx $a @('add', '--', $reqRel) | Out-Null; Gx $a @('commit', '-q', '-m', 'kick request', '--', $reqRel) | Out-Null
        $knE2 = Run 'a' 'kick.ps1' @('-SkipSystemChecks', '-Trigger', 'now')
        $toJ = if (Test-Path (Join-Path $a $toRelE)) { [IO.File]::ReadAllText((Join-Path $a $toRelE), $utf8) | ConvertFrom-Json } else { $null }
        Check '即時実行: 回し先の印を書き、自分の印を消して 1 コミット（無効の PC でも回す）' ($knE2.Text -match "ESCALATE $([regex]::Escape([string]$otherT.claimedBy)):" -and -not (Test-Path $reqPath) -and $toJ -and $toJ.task -eq $otherT.id -and $toJ.escalatedFrom -eq 'pc-a-claude' -and $toJ.by -eq 'dashboard:test' -and (Gx $a @('log', '-1', '--format=%s')).Text -match 'エスカレーション' -and -not (Gx $a @('ls-files', '--', $reqRel)).Text.Trim()) "$($knE2.Text) / $((Gx $a @('log', '-1', '--stat')).Text)"
        # 回された依頼（escalatedFrom あり）は、回し直さない
        [IO.File]::WriteAllText($reqPath, (@{ requestedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'); by = 'dashboard:test'; task = $otherT.id; escalatedFrom = 'x-y' } | ConvertTo-Json), $utf8)
        $knE3 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks', '-Trigger', 'now')
        Check '即時実行: 回された依頼は回し直さず、見送る' ($knE3.Text -cnotmatch '(?m)^ESCALATE' -and $knE3.Text -match 'SKIP 即時実行の指定のタスク') $knE3.Text
        Gx $a @('rm', '-q', '--', $toRelE) | Out-Null; Gx $a @('commit', '-q', '-m', 'cleanup', '--', $toRelE) | Out-Null
        Gx $a @('rm', '-q', '--', $relE) | Out-Null; Gx $a @('commit', '-q', '-m', 'cleanup escalate task', '--', $relE) | Out-Null
    }
    else { Check '即時実行のエスカレーション: 試験の前提（ほかのエージェントが担当するタスク）がある' $false "担当を書けなかった: $($nE.Text) / commit $($gcE.Text)" }
    & $writeReq '20991231-none'
    $kn3 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks', '-Trigger', 'now')
    Check '即時実行: 着手・再開できないタスクの指定は見送る' ($kn3.Text -match 'SKIP 即時実行の指定のタスク 20991231-none は') $kn3.Text
    & $writeReq 'x; rm -rf'
    $kn4 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks', '-Trigger', 'now')
    Check '即時実行: タスク ID の形が違えば見送る' ($kn4.Text -match 'SKIP 即時実行の印のタスク ID の形が違う') $kn4.Text
    & $writeReq '' 30
    $kn5 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks', '-Trigger', 'now')
    Check '即時実行: 古い印（24 時間超）は見送る' ($kn5.Text -match 'SKIP 即時実行の印が古い') $kn5.Text
    & $writeReq ''
    $kp1 = Run 'a' 'kick-poll.ps1' @('-DryRun', '-SkipSystemChecks')
    Check 'kick-poll: 印があれば kick.ps1 -Trigger now を呼ぶ' ($kp1.Text -match 'KICK work') $kp1.Text
    Gx $a @('add', '--', $reqRel) | Out-Null; Gx $a @('commit', '-q', '-m', 'kick request', '--', $reqRel) | Out-Null
    $kn6 = Run 'a' 'kick.ps1' @('-SkipSystemChecks', '-Trigger', 'now')
    $tracked = (Gx $a @('ls-files', '--', $reqRel)).Text.Trim()
    Check '即時実行: 起こせない理由が続く見送り（無効）では印を消してコミットする' ($kn6.Text -match 'SKIP kick.enabled が false' -and -not (Test-Path $reqPath) -and -not $tracked -and (Gx $a @('log', '-1', '--format=%s')).Text -match 'kick-request') $kn6.Text
    Remove-Item (Join-Path $root 'home-a/state/kick.json') -Force
    Check '見送りの理由がログに残る' ((Get-Content (Join-Path $root 'home-a/logs/auto-loop.log') -Raw) -match '\[kick\] 見送り')

    Write-Output '10a. セッションの記録の上限（復帰タスクが無くても、解除時刻が先なら起こさない）'
    $tsOf = { param([double]$Min) (Get-Date).AddMinutes($Min).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    $unixOf = { param([double]$Min) [DateTimeOffset]::new((Get-Date).AddMinutes($Min)).ToUnixTimeSeconds() }
    $recLim = { param([double]$ResetMin, [string]$Kind, [double]$AtMin) '{"parentUuid":"f","type":"assistant","timestamp":"' + (& $tsOf $AtMin) + '","error":"rate_limit","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":' + (& $unixOf $ResetMin) + ',"rateLimitType":"' + $Kind + '"}},"message":{"role":"assistant","content":[{"type":"text","text":"limit"}]}}' }
    $recOk = { param([double]$AtMin) '{"parentUuid":"g","type":"assistant","timestamp":"' + (& $tsOf $AtMin) + '","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}' }
    $lFile = Join-Path $projFake 'p1/l.jsonl'; $oFile = Join-Path $projFake 'p2/o.jsonl'
    New-Item -ItemType Directory -Force (Join-Path $projFake 'p2') | Out-Null
    # 上限の前の応答は、解除の印にならない
    [IO.File]::WriteAllText($lFile, "$recUser`n$(& $recOk -30)`n$recUser`n$(& $recLim 120 'five_hour' -10)`n", $utf8)
    $kl1 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '復帰タスクが無くても、記録の上限の解除時刻が先なら見送る' ($kl1.Text -match 'SKIP 上限の解除待ち（セッションの記録: five_hour') $kl1.Text
    $kl1f = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks', '-Force')
    Check '-Force では記録の上限を見ない' ($kl1f.Text -match 'KICK work') $kl1f.Text
    [IO.File]::AppendAllText($lFile, "$recUser`n", $utf8)
    $kl2 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '上限のあとに利用者が入力しただけなら、まだ見送る' ($kl2.Text -match 'SKIP 上限の解除待ち') $kl2.Text
    [IO.File]::WriteAllText($lFile, "$recUser`n$(& $recLim 120 'five_hour' -10)`n", $utf8)   # 末尾の入力を外す（手を動かしているセッションに数えないため）
    [IO.File]::WriteAllText($oFile, "$recUser`n$(& $recOk -1)`n", $utf8)
    $kl3 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '上限のあとに別のセッションで普通の応答があれば、解除済みとみなす' ($kl3.Text -match 'KICK work') $kl3.Text
    Remove-Item $oFile -Force
    [IO.File]::WriteAllText($lFile, "$recUser`n$(& $recLim -5 'five_hour' -300)`n", $utf8)
    $kl4 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '解除時刻が過ぎた上限では見送らない' ($kl4.Text -match 'KICK work') $kl4.Text
    [IO.File]::WriteAllText($lFile, "$recUser`n$(& $recLim 60 'five_hour' -20)`n", $utf8)
    # 週の解除時刻は 1 つの時刻から、記録（resetsAt）と期待値の両方を作る（別々に今の時刻を読むと、分の境目をまたいだときに 1 分ずれる）
    $weekAt = (Get-Date).AddMinutes(3 * 1440)
    $recWeek = (& $recLim (3 * 1440) 'seven_day' -10) -replace '"resetsAt":\d+', ('"resetsAt":' + [DateTimeOffset]::new($weekAt).ToUnixTimeSeconds())
    [IO.File]::WriteAllText($oFile, "$recUser`n$recWeek`n", $utf8)
    $kl5 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    $expWeek = $weekAt.ToString('MM/dd HH:mm')
    Check '5 時間と週の上限が両方なら、遅いほう（週）の解除時刻で見送る' ($kl5.Text -match 'SKIP 上限の解除待ち（セッションの記録: seven_day、解除 ' + [regex]::Escape($expWeek)) $kl5.Text
    Import-Module (Join-Path $scripts 'lib/AutoLoop.psm1') -Force
    (Get-Item $lFile).LastWriteTime = (Get-Date).AddHours(-200); (Get-Item $oFile).LastWriteTime = (Get-Date).AddHours(-200)
    Check '調べる範囲（LookbackHours）より前に書かれた記録は読まない' ($null -eq (Find-PendingLimit -ProjectsDir $projFake -LookbackHours 170))
    Check '範囲を広げれば読む' ((Find-PendingLimit -ProjectsDir $projFake -LookbackHours 300).Kind -eq 'seven_day')
    Remove-Item $lFile, $oFile -Force

    Write-Output '10b. 起動のきっかけ（週の解除時刻・一定間隔。タスクスケジューラには登録しない）'
    Import-Module (Join-Path $scripts 'lib/AutoLoop.psm1') -Force
    $kw0 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '週の上限の記録が無ければ、解除時刻は分からない' ($kw0.Text -match 'INFO 週の解除時刻: 分からない') $kw0.Text
    $resetUnix = [DateTimeOffset]::new((Get-Date).Date.AddDays(-2).AddHours(8)).ToUnixTimeSeconds()   # 2 日前の 08:00
    $recWeek = '{"parentUuid":"e","type":"assistant","error":"rate_limit","apiErrorParams":{"rate_limit_info":{"status":"rejected","resetsAt":' + $resetUnix + ',"rateLimitType":"seven_day"}},"message":{"role":"assistant","content":[{"type":"text","text":"limit"}]}}'
    $wFile = Join-Path $projFake 'p1/w.jsonl'
    [IO.File]::WriteAllText($wFile, "$recUser`n$recWeek`n", $utf8)
    $expReset = [DateTimeOffset]::FromUnixTimeSeconds($resetUnix).LocalDateTime
    $found = Find-WeeklyResetFromTranscripts -ProjectsDir $projFake -Since (Get-Date).AddDays(-1)
    Check '記録から週の上限の解除時刻を読む' ($found -eq $expReset) "$found / $expReset"
    $slot = Get-NextWeeklySlot -ResetAt $expReset -Now (Get-Date)
    Check '次の起動は解除時刻 + 6 分の 7 日刻みで、これから 7 日の内' ($slot -gt (Get-Date) -and $slot -le (Get-Date).AddDays(7) -and $slot.DayOfWeek -eq $expReset.DayOfWeek -and $slot.ToString('HH:mm') -eq $expReset.AddMinutes(6).ToString('HH:mm')) "$slot"
    $kw1 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check 'DryRun で週の解除時刻と次の起動を表示する（状態は書かない）' ($kw1.Text -match 'INFO 週の解除時刻: .*セッションの記録' -and -not (Test-Path (Join-Path $root 'home-a/state/kick-weekly.json'))) $kw1.Text
    $man = ConvertFrom-WeeklyText 'Thu 08:00'
    Check '手で書いた曜日・時刻を読む（Thu 08:00・木 8:00）' ($man.DayOfWeek -eq 'Thursday' -and $man.ToString('HH:mm') -eq '08:00' -and $man -le (Get-Date) -and (ConvertFrom-WeeklyText '木 8:00') -eq $man -and -not (ConvertFrom-WeeklyText 'あとで'))
    $xm = [xml](New-KickTaskXml -Kind main -KickScript 'C:\x y\kick.ps1' -Shell 'C:\pwsh.exe' -User 'PC\me' -IntervalMinutes 15)
    $xw = [xml](New-KickTaskXml -Kind weekly -KickScript 'C:\x y\kick.ps1' -Shell 'C:\pwsh.exe' -User 'PC\me' -WeeklyAt $slot)
    Check 'タスクの XML: 間隔の繰り返し（PT15M）と、週次は PC を起こして -Trigger weekly' ($xm.Task.Triggers.TimeTrigger.Repetition.Interval -eq 'PT15M' -and $xm.Task.Settings.WakeToRun -eq 'false' -and $xw.Task.Settings.WakeToRun -eq 'true' -and $xw.Task.Triggers.CalendarTrigger.ScheduleByWeek.WeeksInterval -eq '1' -and $xw.Task.Actions.Exec.Arguments -match '-Trigger weekly$')
    $xm0 = [xml](New-KickTaskXml -Kind main -KickScript 'C:\k.ps1' -Shell 'C:\pwsh.exe' -User 'PC\me' -IntervalMinutes 0)
    Check '間隔 0 なら繰り返しのトリガーを付けない' (-not $xm0.Task.Triggers.TimeTrigger)
    [IO.File]::WriteAllText((Join-Path $root 'home-a/state/kick.json'), (@{ lastLaunchedAt = (Get-Date).AddHours(-1).ToString('yyyy-MM-ddTHH:mm:sszzz'); lastKind = 'work'; lastIdleAt = '' } | ConvertTo-Json), $utf8)
    $kw2 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks', '-Trigger', 'weekly')
    Check '週の解除時刻の起動では、前に起こしてからの間隔を見ない' ($kw2.Text -match 'KICK work') $kw2.Text
    Remove-Item (Join-Path $root 'home-a/state/kick.json') -Force
    Remove-Item $wFile -Force

    Write-Output '10c. PC の状況（指令リポジトリの state/pcs/<ID>.json）'
    Run 'a' 'sync.ps1' @('-Message', '前の節の起票を送る') | Out-Null    # 作業ツリーをきれいにしておく（ほかの変更があると push しないため）
    $cfgK = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $cfgK | Add-Member -NotePropertyName kick -NotePropertyValue ([pscustomobject]@{ enabled = $true; statusEveryMinutes = 60 }) -Force
    [IO.File]::WriteAllText($cfgPath, ($cfgK | ConvertTo-Json -Depth 5), $utf8)
    [IO.File]::WriteAllText($sFile, "$recUser`n$recTool`n", $utf8)      # 手を動かしているセッション → 見送り（ウィンドウは開かない）
    $before = (Gx $a @('rev-list', '--count', 'HEAD')).Text.Trim()
    $ks1 = Run 'a' 'kick.ps1' @('-SkipSystemChecks')
    $pcFile = Join-Path $a 'state/pcs/pc-a-claude.json'
    $pc = if (Test-Path $pcFile) { Get-Content $pcFile -Raw | ConvertFrom-Json } else { $null }
    Check '見送りでも状況を書く（判断・理由・セッションの数）' ($ks1.Text -match 'SKIP ほかのセッション' -and $pc -and $pc.decision -eq 'skip' -and $pc.sessions.working -eq 1 -and $pc.agentId -eq 'pc-a-claude' -and $pc.kickEnabled) $ks1.Text
    $pcRaw = if (Test-Path $pcFile) { Get-Content $pcFile -Raw } else { '' }
    Check '状況にパスを書かない' ($pcRaw -and $pcRaw -notmatch [regex]::Escape($root) -and $pcRaw -notmatch '[A-Za-z]:\\\\')
    Check '状況のファイルだけをコミットして push する' ((Gx $a @('log', '-1', '--format=%s')).Text.Trim() -eq '[pc-a-claude] pc-status' -and (Gx $a @('ls-remote', 'origin', 'main')).Text -match (Gx $a @('rev-parse', 'HEAD')).Text.Trim())
    $mid = (Gx $a @('rev-list', '--count', 'HEAD')).Text.Trim()
    $ks2 = Run 'a' 'kick.ps1' @('-SkipSystemChecks')
    Check '中身が同じなら書き直さない（コミットが増えない）' ((Gx $a @('rev-list', '--count', 'HEAD')).Text.Trim() -eq $mid -and [int]$mid -eq [int]$before + 1) "$before → $mid → $((Gx $a @('rev-list', '--count', 'HEAD')).Text.Trim())"
    # ほかの変更（別のセッションの書きかけ）があれば、状況はコミットしても push しない。書きかけはコミットに入れない
    [IO.File]::WriteAllText((Join-Path $a 'half-edit.md'), "書きかけ`n", $utf8)
    [IO.File]::WriteAllText($sFile, "$recUser`n$recTool`n$recDone`n", $utf8)   # 入力待ち → 中身が変わる（見送りの理由も変わる）
    $ks3 = Run 'a' 'kick.ps1' @('-SkipSystemChecks', '-DryRun')
    Check 'DryRun では状況を書かない' ((Gx $a @('rev-list', '--count', 'HEAD')).Text.Trim() -eq $mid)
    $cfgK.kick | Add-Member -NotePropertyName minIntervalHours -NotePropertyValue 0 -Force
    [IO.File]::WriteAllText((Join-Path $root 'home-a/state/kick.json'), (@{ lastLaunchedAt = (Get-Date).AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:sszzz'); lastKind = 'work'; lastIdleAt = '' } | ConvertTo-Json), $utf8)
    $cfgK.kick.minIntervalHours = 1
    [IO.File]::WriteAllText($cfgPath, ($cfgK | ConvertTo-Json -Depth 5), $utf8)
    $ks4 = Run 'a' 'kick.ps1' @('-SkipSystemChecks')     # 間隔で見送り（ウィンドウは開かない）
    $tracked = (Gx $a @('ls-files', 'half-edit.md')).Text.Trim()
    Check '書きかけがあれば、状況はコミットだけして push しない（書きかけは入れない）' ($ks4.Text -match 'SKIP 前に起こしてから' -and -not $tracked -and (Gx $a @('log', '-1', '--format=%s')).Text.Trim() -eq '[pc-a-claude] pc-status' -and (Gx $a @('ls-remote', 'origin', 'main')).Text -notmatch (Gx $a @('rev-parse', 'HEAD')).Text.Trim()) $ks4.Text
    Remove-Item (Join-Path $a 'half-edit.md') -Force
    Gx $a @('push', '-q', 'origin', 'HEAD:main') | Out-Null
    Remove-Item (Join-Path $root 'home-a/state/kick.json') -Force
    $cfgK.kick.enabled = $false
    [IO.File]::WriteAllText($cfgPath, ($cfgK | ConvertTo-Json -Depth 5), $utf8)
    Remove-Item $sFile -Force

    # 上限の窓（ダッシュボードの帯。20261121-dashboard-improve）: 関数を直接呼ぶ（kick は起こさない）
    Import-Module (Join-Path $scripts 'lib/AutoLoop.psm1') -Force
    $limProj = Join-Path $root 'lim-projects'; New-Item -ItemType Directory -Force (Join-Path $limProj 'p') | Out-Null
    $oldHome = $env:AUTO_LOOP_HOME; $env:AUTO_LOOP_HOME = Join-Path $root 'home-lim'
    $ux = { param([double]$H) [DateTimeOffset]::Now.AddHours($H).ToUnixTimeSeconds() }
    $limRec = { param($Reset, [string]$Kind, [string]$St) '{"type":"assistant","error":"rate_limit","apiErrorParams":{"rate_limit_info":{"status":"' + $St + '","resetsAt":' + $Reset + ',"rateLimitType":"' + $Kind + '"}}}' }
    $r5 = & $ux 2; $r7 = & $ux 72; $rOld = & $ux (-200)
    [IO.File]::WriteAllText((Join-Path $limProj 'p/a.jsonl'), ((& $limRec $r5 'five_hour' 'allowed_warning'), (& $limRec $r5 'five_hour' 'rejected'), (& $limRec $r7 'seven_day_overage_included' 'rejected'), (& $limRec $rOld 'five_hour' 'rejected')) -join "`n", $utf8)
    $lw = @(Update-LimitWindows -ProjectsDir $limProj -Days 7)
    $w5 = @($lw | Where-Object { $_.kind -eq 'five_hour' }); $w7 = @($lw | Where-Object { $_.kind -eq 'seven_day' })
    Check '上限の窓: 種類と解除時刻ごとに 1 件、7 日より前は捨てる、週の派生の種類は seven_day' ($lw.Count -eq 2 -and $w5.Count -eq 1 -and $w5[0].hit -and $w7.Count -eq 1 -and ([datetimeoffset]::Parse($w5[0].resetsAt).ToUnixTimeSeconds() -eq $r5) -and (([datetimeoffset]::Parse($w5[0].resetsAt) - [datetimeoffset]::Parse($w5[0].startsAt)).TotalHours -eq 5) -and (([datetimeoffset]::Parse($w7[0].resetsAt) - [datetimeoffset]::Parse($w7[0].startsAt)).TotalDays -eq 7)) ($lw | ConvertTo-Json)
    # 2 回目: 古い記録のファイルは読まず（前回の結果を使う）、新しく書かれた記録だけを足す
    (Get-Item (Join-Path $limProj 'p/a.jsonl')).LastWriteTime = (Get-Date).AddHours(-1)
    $r5b = & $ux 6
    [IO.File]::WriteAllText((Join-Path $limProj 'p/b.jsonl'), (& $limRec $r5b 'five_hour' 'rejected'), $utf8)
    $lw2 = @(Update-LimitWindows -ProjectsDir $limProj -Days 7)
    Check '上限の窓: 前回の結果に、新しい記録の分を足す' ($lw2.Count -eq 3 -and @($lw2 | Where-Object { $_.kind -eq 'five_hour' }).Count -eq 2 -and (Test-Path (Join-Path $root 'home-lim/state/kick-limits.json'))) ($lw2 | ConvertTo-Json)
    $env:AUTO_LOOP_HOME = $oldHome

    Write-Output '10d. 判断待ち・完了で終わらせる見張り（close-watch.ps1。Windows だけ）'
    if (-not $IsWindows) { Write-Output '  skip Windows ではない' }
    else {
        Import-Module (Join-Path $scripts 'lib/AutoLoop.psm1') -Force
        $oldSidW = $env:CLAUDE_CODE_SESSION_ID; $oldPidW = $env:CLAUDE_PID
        $env:CLAUDE_CODE_SESSION_ID = $null; $env:CLAUDE_PID = $null     # 印にセッションを書かない（試験を流すセッションのものにしない）
        $hostsW = @()
        # claude の代わりに ping を子に持つシェル（見張りは子だけを終わらせ、シェルは自分で終わる）
        $newHost = {
            $h = Start-Process -FilePath 'pwsh' -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-Command', '& ping.exe -n 120 127.0.0.1 | Out-Null')
            for ($w = 0; $w -lt 50 -and -not @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($h.Id)" | Where-Object Name -eq 'PING.EXE').Count; $w++) { Start-Sleep -Milliseconds 100 }
            $h
        }
        try {
            $nw = Run 'a' 'new-task.ps1' @('-Project', 'demo', '-Title', '試験: 見張り', '-Slug', 'closewatch', '-Stage', 'implement')
            $idW = (($nw.Text -split "`n")[0] -replace '^OK ', '').Trim()
            Run 'a' 'sync.ps1' @('-Message', 'intake closewatch') | Out-Null
            $cw0 = Run 'a' 'claim.ps1' @('claim', $idW)
            New-Item -ItemType Directory -Force (Join-Path $projFake 'p3') | Out-Null
            $sidK = 'cw-k-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $kFile = Join-Path $projFake "p3/$sidK.jsonl"
            $recClaim = '{"parentUuid":"h","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"PowerShell","input":{"command":"pwsh -NoProfile -File \"C:\\x\\claim.ps1\" claim ' + $idW + ' -Note \"着手\""}}]}}'
            $recMention = '{"parentUuid":"i","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"例: claim.ps1 heartbeat 20991231-other"}]}}'
            [IO.File]::WriteAllText($kFile, "$recUser`n$recClaim`n$recMention`n$recDone`n", $utf8)
            (Get-Item $kFile).LastWriteTime = (Get-Date).AddMinutes(-10)
            $refs = @(Get-SessionTaskRefs @($kFile))
            Check '記録から、claim.ps1 で触れたタスクを拾う（文中の例は拾わない）' ($cw0.Code -eq 0 -and $refs.Count -eq 1 -and $refs[0] -eq $idW) "$($cw0.Text) / $($refs -join ',')"
            $h1 = & $newHost; $hostsW += $h1
            $w1 = Run 'a' 'close-watch.ps1' @('-SessionId', $sidK, '-HostPid', $h1.Id, '-Once')
            Check '担当中（doing）のタスクがあれば終わらせない' ($w1.Text -match "KEEP waiting-input（担当中: $([regex]::Escape($idW))=doing" -and -not $h1.HasExited) $w1.Text
            Run 'a' 'claim.ps1' @('heartbeat', $idW, '-Status', 'waiting', '-Note', '判断待ち') | Out-Null
            (Get-Item $kFile).LastWriteTime = (Get-Date).AddMinutes(-1)
            $w2 = Run 'a' 'close-watch.ps1' @('-SessionId', $sidK, '-HostPid', $h1.Id, '-Once')
            Check '入力待ちになって間もなければ（settledCloseMinutes の内）終わらせない' ($w2.Text -match 'KEEP waiting-input（1\.\d 分）' -and -not $h1.HasExited) $w2.Text
            (Get-Item $kFile).LastWriteTime = (Get-Date).AddMinutes(-10)
            $sidR = 'cw-r-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $rFile = Join-Path $projFake "p3/$sidR.jsonl"
            [IO.File]::WriteAllText($rFile, "$recUser`n$recDone`n", $utf8)
            (Get-Item $rFile).LastWriteTime = (Get-Date).AddMinutes(-10)
            $w3 = Run 'a' 'close-watch.ps1' @('-SessionId', $sidR, '-HostPid', $h1.Id, '-Source', 'resume', '-Once')
            Check '再開したセッションは、auto-loop のタスクに触れていなければ終わらせない' ($w3.Text -match 'KEEP waiting-input（auto-loop のタスクに触れていない）' -and -not $h1.HasExited) $w3.Text
            # 判断待ちになった → 別のプロセスの見張り（Start-CloseWatch）が claude（ping）を終わらせ、シェルも終わる
            Start-CloseWatch -SessionId $sidK -HostPid $h1.Id -Source kick -IntervalSeconds 1 | Out-Null
            $h1.WaitForExit(30000) | Out-Null
            $lockW = Join-Path $root "home-a/state/close-watch/$sidK.json"
            for ($w = 0; $w -lt 100 -and (Test-Path $lockW); $w++) { Start-Sleep -Milliseconds 100 }
            $logW = Get-Content (Join-Path $root 'home-a/logs/auto-loop.log') -Raw
            Check '判断待ちになれば、見張りが claude を終わらせ、シェルも終わる（ログ・印の片付け）' ($h1.HasExited -and $logW -match "閉じた: kick session=$([regex]::Escape($sidK.Substring(0, 8))) host=\d+ settled-close.*$([regex]::Escape($idW))=waiting.*PING\.EXE" -and $logW -match '見張りを始めた: kick' -and -not (Test-Path $lockW)) (($logW -split "`n" | Select-String 'close-watch') -join "`n")
            # 再開したセッション: 印が再開元の ID のままなら自分のもの、別のセッションの印なら自分のものとしない
            Run 'a' 'claim.ps1' @('heartbeat', $idW, '-Status', 'doing', '-Note', '再開') | Out-Null
            $mkW = Join-Path $root "home-a/state/active/demo--$idW.json"
            $setOwner = { param($Sid) $mk = Get-Content $mkW -Raw | ConvertFrom-Json; $mk | Add-Member -NotePropertyName sessionId -NotePropertyValue $Sid -Force; [IO.File]::WriteAllText($mkW, ($mk | ConvertTo-Json), $utf8) }
            & $setOwner 'cw-parent'
            [IO.File]::WriteAllText($rFile, "$recUser`n$recClaim`n$recDone`n", $utf8)
            (Get-Item $rFile).LastWriteTime = (Get-Date).AddMinutes(-10)
            $h2 = & $newHost; $hostsW += $h2
            $w4 = Run 'a' 'close-watch.ps1' @('-SessionId', $sidR, '-HostPid', $h2.Id, '-Source', 'resume', '-ParentSessionId', 'cw-parent', '-Once')
            & $setOwner 'cw-other'
            $w5 = Run 'a' 'close-watch.ps1' @('-SessionId', $sidR, '-HostPid', $h2.Id, '-Source', 'resume', '-ParentSessionId', 'cw-parent', '-Once')
            Check '再開元の ID の印は自分のもの、別のセッションの印は自分のものとしない' ($w4.Text -match 'KEEP waiting-input（担当中' -and $w5.Text -match '(?m)^CLOSE settled-close') "$($w4.Text)`n$($w5.Text)"
            $h2.WaitForExit(10000) | Out-Null
            Check '終わらせればシェルも終わる（再開のセッション）' $h2.HasExited
            # 記録が書かれない（自動起動のセッションだけ。見張りの開始から数える）
            $iFile = Join-Path $projFake 'p3/cw-i.jsonl'
            [IO.File]::WriteAllText($iFile, "$recUser`n", $utf8)
            (Get-Item $iFile).LastWriteTime = (Get-Date).AddMinutes(-90)
            $env:AUTO_LOOP_HOME = Join-Path $root 'home-a'
            $cfgW = Get-LoopConfig
            $dk = Get-CloseDecision -Config $cfgW -Source kick -SessionIds @('cw-i') -TranscriptPaths @($iFile) -WatchStartedAt (Get-Date).AddMinutes(-90)
            $dr = Get-CloseDecision -Config $cfgW -Source resume -SessionIds @('cw-i') -TranscriptPaths @($iFile) -WatchStartedAt (Get-Date).AddMinutes(-90)
            $dn = Get-CloseDecision -Config $cfgW -Source kick -SessionIds @('cw-i') -TranscriptPaths @($iFile) -WatchStartedAt (Get-Date).AddMinutes(-5)
            Check '記録が idleCloseMinutes 分書かれなければ、自動起動のセッションだけ終わらせる' ($dk.Close -and $dk.Reason -match '^idle-close' -and -not $dr.Close -and -not $dn.Close) "$($dk.Reason) / $($dr.Reason) / $($dn.Reason)"
            # ツールの実行中（試験などの長い実行）は、longToolMinutes（既定 240 分）までは終わらせない
            [IO.File]::WriteAllText($iFile, "$recUser`n$recTool`n", $utf8)
            (Get-Item $iFile).LastWriteTime = (Get-Date).AddMinutes(-90)
            $dt1 = Get-CloseDecision -Config $cfgW -Source kick -SessionIds @('cw-i') -TranscriptPaths @($iFile) -WatchStartedAt (Get-Date).AddMinutes(-90)
            (Get-Item $iFile).LastWriteTime = (Get-Date).AddMinutes(-300)
            $dt2 = Get-CloseDecision -Config $cfgW -Source kick -SessionIds @('cw-i') -TranscriptPaths @($iFile) -WatchStartedAt (Get-Date).AddMinutes(-300)
            Check 'ツールの実行中は longToolMinutes まで終わらせない（超えれば終わらせる）' (-not $dt1.Close -and $dt1.Reason -match '^tool-running' -and $dt2.Close -and $dt2.Reason -match '^idle-close') "$($dt1.Reason) / $($dt2.Reason)"
            # long-run のスキルを使った・利用者が「終了しないで」と書いたセッションは、終わらせない
            $recSkill = '{"parentUuid":"s","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t9","name":"Skill","input":{"skill":"my-plugin:long-run"}}]}}'
            [IO.File]::WriteAllText($iFile, "$recUser`n$recSkill`n$recDone`n", $utf8)
            (Get-Item $iFile).LastWriteTime = (Get-Date).AddMinutes(-90)
            $dks = Get-CloseDecision -Config $cfgW -Source kick -SessionIds @('cw-i') -TranscriptPaths @($iFile) -WatchStartedAt (Get-Date).AddMinutes(-90)
            $recKeep = '{"parentUuid":"k","type":"user","message":{"role":"user","content":[{"type":"text","text":"今日は Keep Open で、終了しないでください"}]}}'
            [IO.File]::WriteAllText($iFile, "$recKeep`n$recDone`n", $utf8)
            (Get-Item $iFile).LastWriteTime = (Get-Date).AddMinutes(-90)
            $dkp = Get-CloseDecision -Config $cfgW -Source kick -SessionIds @('cw-i') -TranscriptPaths @($iFile) -WatchStartedAt (Get-Date).AddMinutes(-90)
            # ツールの結果・通知に同じ言い回しがあっても、利用者の入力ではないので数えない
            $recRes = '{"parentUuid":"r","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"終了しないで"}]}}'
            [IO.File]::WriteAllText($iFile, "$recUser`n$recTool`n$recRes`n$recNote`n$recDone`n", $utf8)
            (Get-Item $iFile).LastWriteTime = (Get-Date).AddMinutes(-90)
            $dkn = Get-CloseDecision -Config $cfgW -Source kick -SessionIds @('cw-i') -TranscriptPaths @($iFile) -WatchStartedAt (Get-Date).AddMinutes(-90)
            Check 'long-run のスキル・利用者の「終了しないで」があれば終わらせない（ツールの結果の文は数えない）' (-not $dks.Close -and $dks.Reason -match '^keep-open.*long-run' -and -not $dkp.Close -and $dkp.Reason -match '^keep-open' -and $dkn.Close) "$($dks.Reason) / $($dkp.Reason) / $($dkn.Reason)"
            # 開いているセッションは、別のセッションの起動のたびに時刻の無いメタデータの行を書き足す（ファイルの更新時刻が新しくなる）。
            # 最後の時刻つきの行で数える（2026-11-21 の本番で、60 分の見張りが一度も働かなかった原因）
            $tsOld = (Get-Date).AddMinutes(-90).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $mFile = Join-Path $projFake 'p3/cw-m.jsonl'
            [IO.File]::WriteAllText($mFile, ($recUser -replace '^\{', ('{"timestamp":"' + $tsOld + '",')) + "`n" + ($recDone -replace '^\{', ('{"timestamp":"' + $tsOld + '",')) + "`n" + '{"type":"ai-title","aiTitle":"x","sessionId":"cw-m"}' + "`n" + '{"type":"bridge-session","sessionId":"cw-m"}' + "`n", $utf8)
            $am = Get-SessionActivity -Path $mFile
            $dm = Get-CloseDecision -Config $cfgW -Source kick -SessionIds @('cw-m') -TranscriptPaths @($mFile) -WatchStartedAt (Get-Date).AddMinutes(-90)
            Check '記録の更新時刻ではなく、最後の時刻つきの行で数える（メタデータの書き足しで見張りがのびない）' ($am.State -eq 'waiting-input' -and ((Get-Date) - $am.LastWrite).TotalMinutes -gt 85 -and $dm.Close -and $dm.Reason -match '^idle-close') "$($am.LastWrite) / $($dm.Reason)"
            Remove-Item $mFile -Force
            $de = Get-CloseDecision -Config $cfgW -Source kick -SessionIds @('cw-none') -TranscriptPaths @() -WatchStartedAt (Get-Date)
            Check '記録がまだ無ければ、終わらせずに待つ（起動の直後）' (-not $de.Close -and $de.State -eq 'empty') $de.Reason
            # 再開したセッションの一覧（auto-resume-global の state/running の印。pid が動いているものだけ）
            $h3 = & $newHost; $hostsW += $h3
            $runW = Join-Path $arFake 'state/running'; New-Item -ItemType Directory -Force $runW | Out-Null
            [IO.File]::WriteAllText((Join-Path $runW 'live.json'), (@{ sessionId = 'live'; parentSessionId = 'p0'; pid = $h3.Id; startedAt = (Get-Date).ToString('o') } | ConvertTo-Json), $utf8)
            [IO.File]::WriteAllText((Join-Path $runW 'gone.json'), (@{ sessionId = 'gone'; pid = $h2.Id; startedAt = (Get-Date).ToString('o') } | ConvertTo-Json), $utf8)
            $rsW = @(Get-ResumedSessions $arFake)
            Check '再開したセッションは、印のうち pid が動いているものだけ' ($rsW.Count -eq 1 -and $rsW[0].SessionId -eq 'live' -and $rsW[0].ParentSessionId -eq 'p0') ($rsW | Out-String)
            $kd = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
            Check 'DryRun で、見張りを付ける再開のセッションを表示する' ($kd.Text -match 'INFO 再開したセッション live') $kd.Text
            # 印の時刻は ConvertFrom-Json で DateTime になる。ISO 8601 に戻して渡し、見張りが引数の誤りで止まらない
            Start-CloseWatch -SessionId 'live' -HostPid $h3.Id -Source resume -ParentSessionId 'p0' -HostStartedAt $rsW[0].StartedAt -IntervalSeconds 1 | Out-Null
            $startedW = $false
            for ($w = 0; $w -lt 100 -and -not $startedW; $w++) { Start-Sleep -Milliseconds 100; $startedW = (Get-Content (Join-Path $root 'home-a/logs/auto-loop.log') -Raw) -match '見張りを始めた: resume session=live' }
            Check '再開の印の時刻を渡しても、見張りが動き始める' ($startedW -and $rsW[0].StartedAt -match '^\d{4}-\d\d-\d\dT' -and (Test-CloseWatchRunning 'live')) $rsW[0].StartedAt
            $kd2 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
            Check '見張りが動いていれば、付け直さない' ($kd2.Text -notmatch 'INFO 再開したセッション live') $kd2.Text
            Remove-Item $runW -Recurse -Force
            Remove-Item $kFile, $rFile, $iFile -Force
            Run 'a' 'claim.ps1' @('release', $idW, '-Status', 'done', '-Note', '試験の後始末') | Out-Null
        }
        finally {
            foreach ($h in $hostsW) { if (-not $h.HasExited) { & taskkill.exe /PID $h.Id /T /F 2>&1 | Out-Null } }
            $env:CLAUDE_CODE_SESSION_ID = $oldSidW; $env:CLAUDE_PID = $oldPidW
        }
    }

    Write-Output '11. 手が空いた時のタスク（リモートの無い指令リポジトリ）'
    $c = Join-Path $root 'ctl-c'
    Run 'c' 'new-control-repo.ps1' @('-Path', $c) | Out-Null
    Run 'c' 'install.ps1' @('-NoCopy', '-AgentId', 'pc-c-claude', '-ControlRepoPath', $c) | Out-Null
    $inboxC = Join-Path $c 'inbox.md'
    $st6 = (Run 'c' 'status.ps1' @('-Json')).Text | ConvertFrom-Json
    Check 'ひな形の例は止めてある（定義 0 件・受付 0 件）' (@($st6.idle).Count -eq 0 -and $st6.inbox -eq 0)
    $k6 = Run 'c' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '通常のタスクも定義も無ければ idle を起こす判断' ($k6.Text -match 'KICK idle') $k6.Text
    $t0 = [IO.File]::ReadAllText($inboxC, $utf8)
    $t1 = $t0.Replace('### （停止）my-app: 小さなリファクタリング', '### my-app: 小さなリファクタリング')
    [IO.File]::WriteAllText($inboxC, $t1, $utf8)
    $st7 = (Run 'c' 'status.ps1' @('-Json')).Text | ConvertFrom-Json
    $d0 = @($st7.idle)[0]
    Check '定義を読む（案件・段階・間隔）' (@($st7.idle).Count -eq 1 -and $d0.project -eq 'my-app' -and $d0.stage -eq 'implement' -and $d0.intervalDays -eq 1 -and $d0.interval -eq '毎日' -and $d0.due -and $st7.inbox -eq 0) ($st7 | ConvertTo-Json -Depth 5)
    $mark = "範囲: 1 回に PR / MR 1 本（1 つのモジュール・変更 200 行まで）`n最終実施:"
    [IO.File]::WriteAllText($inboxC, $t1.Replace($mark, "$mark $((Get-Date).ToString('yyyy-MM-dd')) 済み"), $utf8)
    $k7 = Run 'c' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '間隔の内に実施済みなら見送る' ($k7.Text -match 'SKIP やることが無い') $k7.Text
    [IO.File]::WriteAllText($inboxC, $t1.Replace($mark, "$mark $((Get-Date).AddDays(-8).ToString('yyyy-MM-dd')) 済み"), $utf8)
    $k8 = Run 'c' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '間隔を過ぎていれば idle を起こす判断' ($k8.Text -match 'KICK idle') $k8.Text
    [IO.File]::AppendAllText($inboxC, "`n## demo: 急ぎ`n優先: 緊急`n本文`n", $utf8)
    $k9 = Run 'c' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '受付に件があれば work（緊急を数える）' ($k9.Text -match 'KICK work' -and $k9.Text -match '受付=1 緊急=1') $k9.Text
    # 冒頭の案内（「この下に足してください」）の直後、「手が空いた時」の節より上に書いた依頼も数える
    $t2 = [IO.File]::ReadAllText($inboxC, $utf8)
    $t3 = $t2.Replace("`n## 手が空いた時に実行するタスク", "`n## demo: 冒頭に書いた依頼`n優先: 高`n本文`n`n## demo: 冒頭に書いた急ぎ`n優先: 緊急`n本文`n`n## 手が空いた時に実行するタスク")
    [IO.File]::WriteAllText($inboxC, $t3, $utf8)
    $st8 = (Run 'c' 'status.ps1' @('-Json')).Text | ConvertFrom-Json
    Check '目印より上に書いた依頼も数える（例の囲みと定義は数えない）' ($st8.inbox -eq 3 -and $st8.inboxUrgent -eq 2 -and @($st8.idle).Count -eq 1) ($st8 | ConvertTo-Json -Depth 5)

    Write-Output '12. 再開の指示の案内（auto-resume-global の設定は一時フォルダ）'
    $l1 = Run 'c' 'install.ps1' @('-NoCopy', '-LinkAutoResume')
    $arj = [IO.File]::ReadAllText((Join-Path $arFake 'config.json'), $utf8) | ConvertFrom-Json
    $n1 = ([regex]::Matches($arj.resumePrompt, '/auto-loop resume')).Count
    Check '前の版の案内を置き換え、無いほうには足す' ($arj.resumePrompt -match '/auto-loop next' -and $n1 -eq 1 -and $arj.rebootResumePrompt -match '/auto-loop next' -and (Get-ChildItem (Join-Path $root 'home-c/state') -Filter 'auto-resume-global.config.*.json').Count -eq 1) $l1.Text
    $l2 = Run 'c' 'install.ps1' @('-NoCopy', '-LinkAutoResume')
    Check '2 回目は何もしない' ($l2.Text -match '案内は入っている')

    Write-Output '13. 配布先とのずれ（比べ方は一時の git で確かめる）'
    $kf = Join-Path $root 'kit-fake'; $sf = Join-Path $root 'skills-fake'
    foreach ($d in @($kf, $sf)) { & git init -q -b main $d; Gx $d @('config', 'user.email', 'smoke@example.invalid') | Out-Null; Gx $d @('config', 'user.name', 'smoke') | Out-Null }
    $put = { param($Base, $Rel, $Text) $p = Join-Path $Base $Rel; New-Item -ItemType Directory -Force (Split-Path -Parent $p) | Out-Null; [IO.File]::WriteAllText($p, $Text, $utf8) }
    foreach ($m in $distMap) {
        $isDir = $m.Name -match 'auto-loop$|scripts$'
        foreach ($pair in @(@($kf, $m.Kit), @($sf, $m.Dist))) { if ($isDir) { & $put $pair[0] "$($pair[1])/a.ps1" "x $($m.Name)" } else { & $put $pair[0] $pair[1] "x $($m.Name)" } }
    }
    & $put $kf 'skills/auto-resume-global/DISTRIBUTION.md' 'not distributed'
    foreach ($d in @($kf, $sf)) { Gx $d @('add', '-A') | Out-Null; Gx $d @('commit', '-q', '-m', 'init') | Out-Null }
    $c1 = Compare-Distribution $kf 'HEAD' $sf 'HEAD'
    Check 'そろっていれば、ずれなし' (@($c1 | Where-Object { -not $_.Same }).Count -eq 0 -and @($c1).Count -eq $distMap.Count + 1) ($c1 | Format-Table | Out-String)
    & $put $kf 'skills/auto-resume-global/scripts/a.ps1' 'changed in kit'
    & $put $sf 'packages/claude-skill-auto-resume-global/skills/auto-resume-global/extra.md' 'only in dist'
    foreach ($d in @($kf, $sf)) { Gx $d @('add', '-A') | Out-Null; Gx $d @('commit', '-q', '-m', 'drift') | Out-Null }
    $c2 = Compare-Distribution $kf 'HEAD' $sf 'HEAD'
    $bad = @($c2 | Where-Object { -not $_.Same } | ForEach-Object Name)
    Check 'キットだけ変えた・配布先にだけ足したものを見つける' ($bad.Count -eq 2 -and ($bad -contains 'auto-resume-global/scripts') -and ($bad -contains 'auto-resume-global の中身（名前）')) ($c2 | Format-Table | Out-String)

    # 実物の配布先（-SkillsRepo か AUTO_LOOP_SKILLS_REPO を渡したときだけ。手元に取得済みの版で比べ、取得はしない）
    if (-not $SkillsRepo) { $SkillsRepo = $env:AUTO_LOOP_SKILLS_REPO }
    $kitDir = Split-Path -Parent $PSScriptRoot
    if (-not $SkillsRepo) { Write-Output '  skip 実物の配布先（-SkillsRepo <yzkn/skills の clone> で比べる）' }
    elseif (-not (Test-Path -LiteralPath (Join-Path $SkillsRepo '.git'))) { Write-Output "  skip 実物の配布先: git の clone ではない（$SkillsRepo）" }
    elseif ((Gx $SkillsRepo @('rev-parse', '--verify', '-q', "$SkillsRef^{commit}")).Code -ne 0) { Write-Output "  skip 実物の配布先: $SkillsRef が無い（-SkillsRef で替える。先に git fetch しておく）" }
    else {
        $c3 = Compare-Distribution $kitDir $KitRef $SkillsRepo $SkillsRef
        foreach ($x in $c3) { Check "配布先とそろっている: $($x.Name)（キット $KitRef / 配布先 $SkillsRef）" $x.Same "キット $($x.KitValue) / 配布先 $($x.DistValue)。キットを直したなら配布先に PR を出す（skills/auto-resume-global/DISTRIBUTION.md）" }
    }
}
finally {
    $env:AUTO_LOOP_HOME = $null
    $env:AUTO_LOOP_AUTO_RESUME_HOME = $null; $env:AUTO_LOOP_CLAUDE_PROJECTS = $null
    Write-Output ''
    Write-Output "結果: 成功 $script:pass / 失敗 $script:fail"
    if ($Keep -or $script:fail) { Write-Output "一時フォルダ: $root" }
    else { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($script:fail) { exit 1 } else { exit 0 }
