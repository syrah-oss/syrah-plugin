# Syrah Plugin

Agent skills from [Syrah](https://syrah.dev), packaged as a single plugin for
**Claude Code**, **Codex** and **OpenCode**.

Site: <https://syrah-oss.github.io/syrah-plugin/> · source in [`docs/`](docs/).

Open source from Syrah, an independent security studio in Belgium. Built on the
community, given back to it.

One plugin — `syrah` — bundles the skills and their MCP servers. Install it once
and the agent picks up all of them; new work ships with the next update. No
per-skill setup, no copy-paste into dotfiles.

It is built on open community work and given back under MIT: what an engagement
teaches us goes into the repo instead of staying internal.

## Install

### Claude Code

```bash
# add this repo as a marketplace, then install the plugin from it
claude plugin marketplace add syrah-oss/syrah-plugin
claude plugin install syrah@syrah-plugin
```

In a session the same flow is `/plugin marketplace add syrah-oss/syrah-plugin`
followed by `/plugin install syrah@syrah-plugin`. Skills are namespaced under
the plugin, so a skill `foo` is invoked as `/syrah:foo`.

Check what landed with `claude plugin list`.

### Codex

```bash
# register this repo as a plugin marketplace
codex plugin marketplace add syrah-oss/syrah-plugin
```

Enable the plugin from the Plugins Directory in the ChatGPT desktop app, or in
`~/.codex/config.toml`:

```toml
[plugins."syrah@syrah-plugin"]
enabled = true
```

Restart Codex, then `/skills` lists the plugin's skills. Codex also reads the
legacy-compatible `.claude-plugin/marketplace.json`, so one marketplace entry
serves both hosts.

### OpenCode

OpenCode has no marketplace; it reads skills from a skills directory. Point it at
this repo's `skills/` once:

```bash
# OpenCode — user level (~/.config/opencode/skills)
for s in "$PWD"/skills/*/; do mkdir -p ~/.config/opencode/skills && ln -sfn "$s" ~/.config/opencode/skills/"$(basename "$s")"; done
```

For a single project, use `.opencode/skills` instead and commit the links. The
`SKILL.md` frontmatter is the same one Claude Code and Codex read, so no edits
are needed.

### From a local clone

```bash
# Claude Code — load the working copy for one session
claude --plugin-dir "$PWD"

# Codex — point the marketplace at the checkout instead of the remote
codex plugin marketplace add "$PWD"
```

### Plain skills, no plugin host

Any host that reads the Agent Skills format (`SKILL.md`) can consume `skills/`
directly — Claude Code at `~/.claude/skills`, Codex at `~/.agents/skills`, and
so on. The plugin routes above are preferred because they keep versions, but
the directories are interchangeable:

```bash
# Claude Code — user level, one link per skill
for s in "$PWD"/skills/*/; do mkdir -p ~/.claude/skills && ln -sfn "$s" ~/.claude/skills/"$(basename "$s")"; done

# Codex — user level
for s in "$PWD"/skills/*/; do mkdir -p ~/.agents/skills && ln -sfn "$s" ~/.agents/skills/"$(basename "$s")"; done
```

## Skills

| Skill | What it does | Needs |
| --- | --- | --- |
| [`mullvad`](skills/mullvad/SKILL.md) | Changes the public IP through Mullvad — rotate the relay, pick a country or city, verify the new exit from outside, restore the previous settings. | `mullvad` CLI with a running daemon, `jq`, `curl` |

Each skill is self-contained: `SKILL.md` is the instruction set the agent
reads, `scripts/` holds anything executable, `references/` holds detail that is
loaded only when needed.

## Layout

```
.
├── plugin.json                        portable Agent Plugins manifest (Codex)
├── .claude-plugin/
│   ├── plugin.json                    Claude Code plugin manifest
│   └── marketplace.json               marketplace catalog (Claude Code, and
│                                      legacy-compatible for Codex)
├── .agents/plugins/
│   └── marketplace.json               marketplace catalog (Codex)
├── docs/                              landing page (GitHub Pages)
└── skills/
    └── mullvad/
        ├── SKILL.md
        ├── scripts/
        └── references/
```

The plugin identity lives in three places and they must agree on `name`:

- `plugin.json` — root, portable, consumed by Codex
- `.claude-plugin/plugin.json` — Claude Code
- the `plugins[]` entries in both marketplace files

## Adding a skill

1. Create `skills/<name>/SKILL.md` with frontmatter `name` (kebab-case, matching
   the directory) and a `description` that says both when to use it and when not
   to — that description is all the model sees before it loads the skill.
2. Put executable helpers in `scripts/` and long-form detail in `references/`.
   Reference them from `SKILL.md` so they are reachable but not always loaded.
3. Bump `version` in `plugin.json` and `.claude-plugin/plugin.json`.
4. Validate and commit:

   ```bash
   # schema + metadata check for the plugin and marketplace manifests
   claude plugin validate . --strict
   ```

## Landing page

`docs/` is a static page built on the syrah.dev stylesheet. To publish it:

1. Push the repository to GitHub.
2. Settings → Pages → Source: **Deploy from a branch**, branch `main`, folder `/docs`.

It then serves at `https://<org>.github.io/<repo>/`. If the repo is named
`<org>.github.io`, the page is served at the root instead; paths are relative, so
both work.

## Security

Skills can run commands. Read `SKILL.md` and `scripts/` before installing a
plugin from any source, including this one. Report problems to
[security@syrah.dev](mailto:security@syrah.dev).

## License

MIT — see [LICENSE](LICENSE).
