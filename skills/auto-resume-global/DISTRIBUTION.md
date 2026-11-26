# 配布先

このフォルダが `auto-resume-global` スキルの**正本**です（`skills/auto-loop/` と同じ扱い。2026-11-19 に決定）。[yzkn/skills](https://github.com/yzkn/skills) は配布先（従）で、配布先では直しません。直すときは、ここを直してから配布し直します。

このファイルは配布しません（配布先には置かない）。

| 項目 | 内容 |
|---|---|
| 配布先 | https://github.com/yzkn/skills の `packages/claude-skill-auto-resume-global/` |
| 配布するもの | このフォルダの `SKILL.md`・`scripts/` → パッケージの `skills/auto-resume-global/`。このフォルダの `README.md`・`MANUAL.md` → パッケージの直下 |
| 配布しないもの | このファイル。パッケージの `LICENSE`（キットの `LICENSE` と同じ Apache-2.0）・`.gitignore` は配布先にだけある |
| 最後にそろえた版 | 2026-11-26。キット 62bc14b（#26〜#30 のマージ後）の `skills/auto-loop/` が、配布先 2c8f2fd（yzkn/skills#17・#18・#19・#21 のマージ後）とそろった（`skills/auto-loop/` はツリー bdee204、auto-resume-global は変わっていない）。#17 は #29（`kick.minIntervalHours` の既定 0.5）、#18 は #26〜#28、#21 は #30 の分。#18 のマージでコンフリクトを解消したとき `install.ps1` の `pollMinutes = 3` が落ちたので、#19 で配り直した。`tests/smoke.ps1 -SkillsRepo <clone> -SkillsRef upstream/main` の「13. 配布先とのずれ」がすべて ok。その前は 2026-11-21。キット 102aa7b（#23・#24 のマージ後）の `skills/auto-loop/` を、配布先の yzkn/skills#16 に配布（#23 の `status.ps1` の分。#24 は yzkn/skills#15 でマージ済み）。`tests/smoke.ps1 -SkillsRepo <clone> -SkillsRef sync/status-json-this-session` の「13. 配布先とのずれ」がすべて ok。その前も 2026-11-21。キット ec0f57d（#24。#21・#22 の分を含む）を、配布先の yzkn/skills#15 に配布（auto-loop と、auto-resume-global の `SKILL.md`。スクリプトは変わっていない）。`tests/smoke.ps1 -SkillsRepo <clone> -SkillsRef sync/close-on-wait` の「13. 配布先とのずれ」がすべて ok。#24 がマージされる前に出したので、#24 に変更が入ったら配り直す。その前は 2026-11-20。キット 5e8d7e8（#16・#17）を、配布先 989fbdd（yzkn/skills#14）に配布（auto-loop だけ。auto-resume-global は変わっていない）。`skills/auto-loop/` はツリー 0170266 で、配布先と同じ（`tests/smoke.ps1 -SkillsRepo` の「13. 配布先とのずれ」がすべて ok）。その前は 2026-11-20、キット 7f2389c（#11〜#14）を、配布先 136e649（yzkn/skills#13）に配布（auto-loop だけ。auto-resume-global は変わっていない）。このフォルダの `SKILL.md`・`README.md`・`MANUAL.md`・`scripts/`（ツリー 21fca1d）と、`skills/auto-loop/`（ツリー bdb6ce2）が、blob・ツリーの値で同じ。その前は 2026-11-19、キット 74281a0（#9）を配布先 b0be7fc（yzkn/skills#11）に配布（`skills/auto-loop/` はツリー 6439543）。このフォルダの `SKILL.md`・`README.md`・`MANUAL.md`・`scripts/`（ツリー 21fca1d）と、`skills/auto-loop/`（ツリー 6439543）が、blob・ツリーの値で同じ。それより前（キット 9953cc9 まで）は配布先が正本で、キットは複製だった |

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
