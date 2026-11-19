#requires -Version 7.0
<#
.SYNOPSIS
  auto-loop のスクリプトの通し試験。一時フォルダに「リモート（bare）+ エージェント 2 つ分の clone」を作って確かめる。
.DESCRIPTION
  ネットワーク・GitHub・利用者の ~/.claude には触れない（AUTO_LOOP_HOME を一時フォルダに向ける）。
  確かめること: 起票 → 一覧 → 担当の主張 → 二重の主張の拒否 → push の競り負け → 印 → 引き継ぎ → 主張の喪失の検出 → 解放と保管 → 同期の競合 → 着手前の確認
              → 優先度（緊急）と一覧の順 → 自動起動の判断（kick.ps1 -DryRun。セッションは起こさない）→ 手が空いた時のタスクの定義 → 再開の指示の案内
  自動起動・自動再開の場所は、環境変数（AUTO_LOOP_AUTO_RESUME_HOME・AUTO_LOOP_CLAUDE_PROJECTS）で一時フォルダに向ける。タスクスケジューラには触れない
.EXAMPLE
  pwsh -NoProfile -File tests/smoke.ps1
  pwsh -NoProfile -File tests/smoke.ps1 -Keep    # 一時フォルダを残す
#>
param([switch]$Keep)
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
    Check 'a が担当できる' ($c1.Code -eq 0 -and (Test-Path (Join-Path $root "home-a/state/active/$id.json"))) $c1.Text
    $c2 = Run 'b' 'claim.ps1' @('claim', $id)
    Check 'b は担当できない（終了コード 2）' ($c2.Code -eq 2 -and $c2.Text -match 'pc-a-claude が担当中') $c2.Text
    Check 'b の作業コピーは汚れていない' (-not (Gx $b @('status', '--porcelain')).Text.Trim())
    $c3 = Run 'a' 'claim.ps1' @('claim', $id)
    Check 'a の再主張は継続になる' ($c3.Code -eq 0) $c3.Text

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
    $rl = Run 'b' 'claim.ps1' @('release', $id, '-Status', 'done', '-Note', '完了')
    Check '完了で archive に移る' ($rl.Code -eq 0 -and (Test-Path (Join-Path $b "projects/demo/archive/$id.md")) -and -not (Test-Path (Join-Path $b $taskRel)) -and -not (Test-Path (Join-Path $root "home-b/state/active/$id.json"))) $rl.Text
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
    $st5 = Run 'a' 'status.ps1' @('-NoPull')
    Check '一覧に緊急の件数が出る' ($st5.Text -match '緊急（priority: urgent）: 1 件') $st5.Text

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
    $k2 = Run 'a' 'kick.ps1' @('-SkipSystemChecks')
    Check '有効にしていなければ起こさない' ($k2.Text -match 'SKIP kick.enabled が false' -and -not (Test-Path (Join-Path $root 'home-a/state/kick.json'))) $k2.Text
    New-Item -ItemType Directory -Force (Join-Path $projFake 'p1') | Out-Null
    [IO.File]::WriteAllText((Join-Path $projFake 'p1/s.jsonl'), "{}`n", $utf8)
    $k3 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check 'ほかのセッションが動いていれば見送る' ($k3.Text -match 'SKIP ほかのセッションが動いている') $k3.Text
    Remove-Item (Join-Path $projFake 'p1/s.jsonl') -Force
    [IO.File]::WriteAllText((Join-Path $arFake 'disabled'), '', $utf8)
    $k4 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check 'auto-resume-global が停止中なら見送る' ($k4.Text -match 'SKIP auto-resume-global が停止中') $k4.Text
    Remove-Item (Join-Path $arFake 'disabled') -Force
    [IO.File]::WriteAllText((Join-Path $root 'home-a/state/kick.json'), (@{ lastLaunchedAt = (Get-Date).AddHours(-1).ToString('yyyy-MM-ddTHH:mm:sszzz'); lastKind = 'work'; lastIdleAt = '' } | ConvertTo-Json), $utf8)
    $k5 = Run 'a' 'kick.ps1' @('-DryRun', '-SkipSystemChecks')
    Check '前に起こしてから間が無ければ見送る' ($k5.Text -match 'SKIP 前に起こしてから') $k5.Text
    Remove-Item (Join-Path $root 'home-a/state/kick.json') -Force
    Check '見送りの理由がログに残る' ((Get-Content (Join-Path $root 'home-a/logs/auto-loop.log') -Raw) -match '\[kick\] 見送り')

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
    Check '定義を読む（案件・段階・間隔）' (@($st7.idle).Count -eq 1 -and $d0.project -eq 'my-app' -and $d0.stage -eq 'implement' -and $d0.intervalDays -eq 7 -and $d0.due -and $st7.inbox -eq 0) ($st7 | ConvertTo-Json -Depth 5)
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

    Write-Output '12. 再開の指示の案内（auto-resume-global の設定は一時フォルダ）'
    $l1 = Run 'c' 'install.ps1' @('-NoCopy', '-LinkAutoResume')
    $arj = [IO.File]::ReadAllText((Join-Path $arFake 'config.json'), $utf8) | ConvertFrom-Json
    $n1 = ([regex]::Matches($arj.resumePrompt, '/auto-loop resume')).Count
    Check '前の版の案内を置き換え、無いほうには足す' ($arj.resumePrompt -match '/auto-loop next' -and $n1 -eq 1 -and $arj.rebootResumePrompt -match '/auto-loop next' -and (Get-ChildItem (Join-Path $root 'home-c/state') -Filter 'auto-resume-global.config.*.json').Count -eq 1) $l1.Text
    $l2 = Run 'c' 'install.ps1' @('-NoCopy', '-LinkAutoResume')
    Check '2 回目は何もしない' ($l2.Text -match '案内は入っている')
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
