# 複製元

このフォルダは、`auto-resume-global` スキルの**複製**です。正本は別のリポジトリにあります。ここで直さず、正本を直してから複製し直してください（このファイル以外は、正本とバイト単位で同じに保つ）。

| 項目 | 内容 |
|---|---|
| 正本 | https://github.com/yzkn/skills の `packages/claude-skill-auto-resume-global/` |
| 複製した版 | コミット `327b1b9`（yzkn/skills の PR #8 のブランチ `auto-resume-global-weekly-sleep`。`upstream/main` の `7ec1661` の上。2026-11-19 に複製。PR #8 は同日マージ（af6fe7c）。マージ後の `upstream/main` のパッケージのツリーの値は 327b1b9 と同じ fc3f75c） |
| 複製したもの | `skills/auto-resume-global/` の全体 → このフォルダ。パッケージの `README.md`・`MANUAL.md` → このフォルダ |
| 複製していないもの | パッケージの `LICENSE`（キットの `LICENSE` と同じ Apache-2.0）、`.gitignore` |

`README.md`・`MANUAL.md` の中のパス（`packages/claude-skill-auto-resume-global/...`）は、正本のリポジトリでの場所です。このキットでは、`skills/auto-resume-global/` に読み替えてください。

## 複製し直す手順

```bash
# yzkn/skills の clone で（リモート upstream = yzkn/skills）
git fetch upstream
git -C <skills の clone> archive -o <一時フォルダ>.tar upstream/main packages/claude-skill-auto-resume-global
tar -xf <一時フォルダ>.tar -C <一時フォルダ>
# PowerShell では archive を | でつながない（バイナリが壊れる）。core.autocrlf が true だと CRLF で出てくるので、LF に直してから比べる
P=<一時フォルダ>/packages/claude-skill-auto-resume-global
cp -r $P/skills/auto-resume-global/. skills/auto-resume-global/
cp $P/README.md $P/MANUAL.md skills/auto-resume-global/
# 改行は .gitattributes が LF にそろえる。上の表の「複製した版」を更新する
```

## このキットとの関係

- `auto-resume-global` は、上限で止まった対話セッションを、解除時刻に PC を起こして再開する（Windows 専用）
- `auto-loop` は、再開したセッションが**何を読んで続けるか**を受け持つ。`auto-loop` の `install.ps1 -LinkAutoResume` が、`auto-resume-global` の再開の指示に「`/auto-loop resume` を実行する」案内を足す
