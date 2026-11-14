# CLAUDE.md（このキットを保守するときの決まり）

このリポジトリは、ループエンジニアリングのひな形（`auto-loop` スキルと、指令リポジトリのひな形）です。**指令リポジトリ向けの決まりは `skills/auto-loop/assets/control-repo/AGENTS.md` で、このファイルとは別物**です。

## 方針

- **技術スタック・プログラミング言語に依存するものを入れない。** ビルド・試験・lint・CI などは、案件ごとの `project.md`「検証の方法」に書いてもらう
- 名前は配布名 `auto-loop` にそろえる（スキル・`~/.claude/auto-loop/`・ログ）。似た名前の別物を作らない
- スクリプトは、何度実行しても安全にする。拒否・失敗・見送りは、理由と一緒に `logs/auto-loop.log` に残す
- 破壊的な git 操作（強制の push、他人の変更を消す巻き戻し）をスクリプトに入れない。競合は取り消して報告する
- 認証の入力待ちで止まる呼び出しを入れない

## ファイルの書き方

- 応答・文書・コメントは日本語。確かめた事実と推測を分ける
- 文字コードは UTF-8（BOM なし）、改行は LF。スクリプトは PowerShell 7（`#requires -Version 7.0`）。7.1 でも動く書き方にする（外部コマンドは `Invoke-Git` などの包みを通す）
- 大文字・小文字だけが違うファイル名を作らない。外部の道具と同じ名前の関数を作らない
- 文字列の中の `$変数:` は `${変数}:` と書く（PowerShell がスコープの指定と読む）

## 変更したら流すもの

```powershell
pwsh -NoProfile -File tests/smoke.ps1
```

一時フォルダで完結し、ネットワークと `~/.claude` には触れない。スクリプトの挙動を変えたら、試験も足す。

## 文書の対応

手順を変えたら、次をそろえる: `skills/auto-loop/SKILL.md` と `references/`、ひな形の `AGENTS.md`・`README.md`・`policy.md`、`docs/design.md`（決めた理由）、`docs/operations.md`。実地で確かめたことは `docs/field-checks.md` に足す。

## Git

- コミット・push は利用者の指示に従う
- この PC の `gh` の有効なアカウントと、`origin` の持ち主が違うことがある。push の前に確かめる
