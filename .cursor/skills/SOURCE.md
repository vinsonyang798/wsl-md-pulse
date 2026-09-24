These skill directories were copied so Cloud Agents on this repo pick
them up from checkout (`.cursor/skills/<name>/SKILL.md`).

They are also installed onto a Cloud Agent VM at `~/.cursor/skills`
by `scripts/install-cloud-skills.sh` when the environment `install` runs.

Most skills came from the skillslm repository (`.cursor/skills`).
Upstream origin (via skillslm):
https://github.com/mattpocock/skills
at commit `74ca5fe077456a0b3b2f5310cf9430999fd0b5fd`.

`kb` was synced from the personal GitHub repo
https://github.com/vinsonyang798/agent-env
(`.cursor/skills/kb`).

License for the Matt Pocock skills: MIT, Copyright (c) 2026 Matt Pocock.
The upstream LICENSE is in this directory.
