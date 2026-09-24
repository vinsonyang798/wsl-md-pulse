These skill directories were copied so Cloud Agents on this repo pick
them up from checkout (`.cursor/skills/<name>/SKILL.md`).

They are also installed onto a Cloud Agent VM at `~/.cursor/skills`
by `scripts/install-cloud-skills.sh` when the environment `install` runs.

Canonical copy: https://github.com/vinsonyang798/agent-env
(`.cursor/skills`). Missing or stale skills are synced from that tree.

Synced skill set (20), matching `agent-env` `main` at
`0a8d2b2fc4b2edecdf7879dbd5fbc57159dc7dcb`:

- ask-matt
- code-review
- codebase-design
- domain-modeling
- grill-me
- grill-with-docs
- grilling
- handoff
- implement
- improve-codebase-architecture
- kb
- prototype
- research
- setup-matt-pocock-skills
- tdd
- to-spec
- to-tickets
- wayfinder
- wizard
- writing-for-agents

Earlier Matt Pocock skills also came via skillslm / `mattpocock/skills`
at commit `74ca5fe077456a0b3b2f5310cf9430999fd0b5fd`.

License for the Matt Pocock skills: MIT, Copyright (c) 2026 Matt Pocock.
The upstream LICENSE is in this directory.
