# auto-loop-engineering

ループエンジニアリング（AI エージェントに、長時間・複数案件の作業を、中断と再開をまたいで進めさせる）のためのひな形です。技術スタックやプログラミング言語には依存しません。

- **指令リポジトリ**のひな形: 複数の案件を横断して、依頼と作業の状態を Markdown で管理する GitHub リポジトリ
- **`auto-loop` スキル**（Claude Code）: 起票・着手前の確認・担当の主張・状態の記録・再開・委任・完了の報告の手順と、そのスクリプト
- **運用の手引き**: 承認の境界、役割分担、報告の型、既知の落とし穴

上限の解除時刻に PC を起こしてセッションを再開する仕組みは、別のスキル [`auto-resume-global`](https://github.com/yzkn/skills) が受け持ちます。このキットは、その**再開のあとに何を読んで続けるか**を受け持ちます。

## 考え方

| 課題（実際に起きたこと） | このキットの答え |
|---|---|
| 作業の状態が会話の中にしかなく、再開のたびに会話を読み直した | 状態の正本を、会話の外の**タスクファイル**（指令リポジトリ）に置く |
| 認証切れ・push 先の削除予定を、作業の最後で知った | 着手・再開・公開操作の前に**着手前の確認**（`preflight`）を行う |
| 作業が GitHub / GitLab の複数のアカウント・リポジトリに分かれている | 指令は 1 つのリポジトリに集め、案件ごとに「どのホストの、どのアカウントの、どれが本流か」を書く |
| 複数の PC・複数のエージェントが同じ作業に手を付けうる | 担当を**git の push の先着**で決める（`claim`）。担当していないタスクは書き換えない |
| セッションが分岐すると、止まったサブエージェントを呼び戻せない | 委任を起動の前に記録し、作業ツリーに残った変更を新しいエージェントに**仕上げ**させる |
| サブエージェントの push・PR 作成が権限の確認で止まった | 外部への公開操作は**親だけ**。承認が要る操作は計画の時点で洗い出し、最後にまとめる |
| 「提案だけ」のつもりが、どこまで進めてよいか曖昧 | 依頼ごとに**段階**（提案だけ / 実装まで / マージまで）を明示する |

設計の根拠と、元になった作業の教訓との対応は [docs/design.md](docs/design.md) にあります。

## 構成

```
skills/auto-loop/                 スキル（そのまま ~/.claude/skills/ に置ける）
  SKILL.md                        入口。サブコマンドごとに references/ を読む
  references/                     setup / status / intake / start / preflight / checkpoint / resume / delegate / finish
  scripts/                        PowerShell 7 のスクリプト（下の表）
  assets/control-repo/            指令リポジトリのひな形
docs/
  design.md                       設計と根拠、未解決の論点
  operations.md                   運用の手引き（人の動き・役割分担・落とし穴）
  field-checks.md                 実地確認の記録（いつ・何が起き・何で確かめたか）
tests/smoke.ps1                   スクリプトの通し試験（一時フォルダで完結）
```

| スクリプト | 役割 |
|---|---|
| `install.ps1` | この PC への導入（スキルの写し、`~/.claude/auto-loop/` の用意）。何度実行しても安全 |
| `new-control-repo.ps1` | 指令リポジトリをひな形から手元に作る（GitHub には触れない） |
| `preflight.ps1` | 着手前の確認（認証・push 先・本流のリモート・作業ツリー） |
| `status.ps1` | 全案件の状態の要約 |
| `new-task.ps1` | タスクファイルの作成 |
| `claim.ps1` | 担当の主張・印・解放・引き継ぎ |
| `sync.ps1` | 指令リポジトリの同期（コミット → 取り込み → 送信） |

## 始め方

前提: Git、PowerShell 7（`pwsh`）、Claude Code。GitHub / GitLab を使う案件では `gh` / `glab`。

```powershell
# 1. 指令リポジトリを手元に作る（すでにあるなら clone する）
pwsh -NoProfile -File skills/auto-loop/scripts/new-control-repo.ps1 -Path <場所>\loop-control

# 2. リモートを非公開で作って送る（利用者が行う。1 のスクリプトがコマンドを示す）

# 3. この PC に導入する（ID は <PC>-<道具>[-<アカウントや用途>]）
pwsh -NoProfile -File skills/auto-loop/scripts/install.ps1 -AgentId pc1-claude-main -ControlRepoPath <場所>\loop-control

# 4. 確かめる
pwsh -NoProfile -File $HOME\.claude\skills\auto-loop\scripts\preflight.ps1
```

あとは Claude Code で `/auto-loop setup`（案件の登録、名簿への追加、`auto-resume-global` との連携）に進みます。2 台目以降の PC では、指令リポジトリを clone して 3 から行います。

日々の使い方は [docs/operations.md](docs/operations.md) にあります。

## 名前の決まり

スキル・実行時のフォルダ・ログの名前を、配布名 `auto-loop` にそろえています（`~/.claude/skills/auto-loop/`、`~/.claude/auto-loop/`、`logs/auto-loop.log`）。似た名前の別物を作ると、人の運用ミスの原因になるためです。

## 確かめたこと・確かめていないこと

- スクリプトは `tests/smoke.ps1`（31 項目）で、起票・一覧・担当の主張・二重の主張の拒否・push の競り負け・引き継ぎ・主張の喪失の検出・解放と保管・同期の競合・着手前の確認を確かめています（Windows 11、PowerShell 7.1、手元の bare リポジトリ）
- 実際の作業で通して使った記録は [docs/field-checks.md](docs/field-checks.md) に足していきます。まだ確かめていないことも、そこにあります

## ライセンス

[Apache License 2.0](LICENSE)
