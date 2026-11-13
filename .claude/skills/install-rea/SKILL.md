---
name: install-rea
description: Install REA with its deep-analysis providers (Ghidra, JADX MCP, Kuna, Hopper demo) and connect it to Claude Code. Use when the user says "install rea", "set up rea", or asks to install REA's providers.
---

# Install REA

Run the bundled installer in two steps: show the plan, get approval, then apply.

1. Show the plan (changes nothing):

   ```bash
   bash "${CLAUDE_SKILL_DIR:-.claude/skills/install-rea}/install-rea.sh" --plan
   ```

   Pass through any options the user asked for: `--no-hopper`, `--no-ghidra`,
   `--no-jadx`, `--no-kuna`, `--prefix DIR`, `--client NAME`, `--rea-version V`.

2. Show the plan output to the user and ask for approval with AskUserQuestion.
   Mention that Hopper is a commercial demo and that IDA Pro and JEB are not
   installed (commercial, bring-your-own). Do not apply without approval.

3. Apply with the same options plus `--yes`. Downloads are about 600 MB, so use a
   timeout of at least 10 minutes (or run in the background):

   ```bash
   bash "${CLAUDE_SKILL_DIR:-.claude/skills/install-rea}/install-rea.sh" --yes
   ```

4. Report the summary the script prints: `rea setup` status, each provider's
   availability with any failing check, skill state and registration state.
   Report failures as observed; do not retry an unchanged failing step. A SHA-256
   mismatch means the pinned release changed or the download was corrupted; stop
   and tell the user.

5. Tell the user to restart Claude Code so the REA MCP server loads.

Notes:
- Linux x86_64/arm64 only. Node.js 22.23.4+, 24.22.1+ or 26.12.1+ must already
  be installed. JDK 21 and procps are installed through the system package
  manager only when missing.
- Re-running is safe: present components are kept and the shell-profile block
  is added once (with a `.rea-tools.backup` copy made before the first edit).
- In a Claude Code cloud session the container is temporary; rerun this skill in
  each new session, or add the script to the environment's setup script.
