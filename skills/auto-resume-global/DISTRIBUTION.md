# 配布先

このフォルダが `auto-resume-global` スキルの**正本**です（`skills/auto-loop/` と同じ扱い。2026-11-19 に決定）。[yzkn/skills](https://github.com/yzkn/skills) は配布先（従）で、配布先では直しません。直すときは、ここを直してから配布し直します。

このファイルは配布しません（配布先には置かない）。

| 項目 | 内容 |
|---|---|
| 配布先 | https://github.com/yzkn/skills の `packages/claude-skill-auto-resume-global/` |
| 配布するもの | このフォルダの `SKILL.md`・`scripts/` → パッケージの `skills/auto-resume-global/`。このフォルダの `README.md`・`MANUAL.md` → パッケージの直下 |
| 配布しないもの | このファイル。パッケージの `LICENSE`（キットの `LICENSE` と同じ Apache-2.0）・`.gitignore` は配布先にだけある |
| 最後にそろえた版 | 2026-11-19。キット 74281a0（#9）を、配布先 b0be7fc（yzkn/skills#11）に配布。このフォルダの `SKILL.md`・`README.md`・`MANUAL.md`・`scripts/`（ツリー 21fca1d）と、`skills/auto-loop/`（ツリー 6439543）が、blob・ツリーの値で同じ。それより前（キット 9953cc9 まで）は配布先が正本で、キットは複製だった |

`README.md`・`MANUAL.md` の中のパス（`packages/claude-skill-auto-resume-global/...`）は、配布先のリポジトリでの場所です。このキットでは、`skills/auto-resume-global/` に読み替えてください。

## 配布の手順

ここを直した PR がキットにマージされたら、配布先に PR を出します。

```bash
# yzkn/skills の clone で（リモート upstream = yzkn/skills、origin = 自分のフォーク）
git fetch upstream
git switch -c sync/auto-resume-global upstream/main
P=packages/claude-skill-auto-resume-global
K=<キットの clone>/skills/auto-resume-global
cp $K/SKILL.md $P/skills/auto-resume-global/
rm -rf $P/skills/auto-resume-global/scripts && cp -r $K/scripts $P/skills/auto-resume-global/
cp $K/README.md $K/MANUAL.md $P/
# 改行は .gitattributes がそろえる。core.autocrlf が true の PC では、作業コピーが CRLF でも blob は LF になる
# 照らす: 配布先の PR がマージされたら git fetch upstream し、キットで
#   pwsh -NoProfile -File tests/smoke.ps1 -SkillsRepo <yzkn/skills の clone>
# 「13. 配布先とのずれ」がすべて ok なら、そろっている（auto-loop も同じ試験で見る）
```

配布したら、上の表の「最後にそろえた版」を書き換えます。

キットを直したあと、配布の前に `-SkillsRepo` 付きで試験を流すと、直したところが FAIL になります（ずれている＝配布が要る、という印）。配布を忘れていないかの確かめに使います。

## このキットとの関係

- `auto-resume-global` は、上限で止まった対話セッションを、解除時刻に PC を起こして再開する（Windows 専用）。指令リポジトリを知らず、単体で使える
- `auto-loop` は、再開したセッションが**何を読んで続けるか**を受け持つ。`auto-loop` が読む `auto-resume-global` のもの（設定のキー・ファイル・タスクの名前）は、`docs/design.md` の「1.1 2 つのスキルの関係」と、`SKILL.md` の「auto-loop との関係」にある。変えるときは、両方を同じ PR で直す
