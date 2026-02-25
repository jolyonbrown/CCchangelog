# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

CCchangelog is a Zig bot that monitors Claude Code releases via the GitHub Releases API and posts changelog summaries to Bluesky as threaded posts. It uses the Anthropic API (Claude Haiku) to generate concise summaries.

## Architecture

```
Every 15 min (GitHub Actions cron):
  1. GitHub Releases API → fetch latest release (version + changelog body)
  2. Compare with cached last_version.txt
  3. If new version:
     a. Parse changelog into bullet entries
     b. Anthropic API (Haiku) → generate headline + detail summaries
     c. Bluesky AT Protocol → post thread
     d. Write new version to last_version.txt
```

All logic is in `src/main.zig` — pure Zig with no shell scripts or external dependencies.

## Build & Run

```bash
zig build                # Build the project
zig build run            # Build and run
zig build test           # Run all tests
zig build -Doptimize=ReleaseSafe  # Release build
```

Requires Zig 0.15.2.

## Environment Variables

Required at runtime:
- `ANTHROPIC_API_KEY` — Anthropic API key for Claude Haiku summaries
- `BLUESKY_HANDLE` — Bluesky account handle
- `BLUESKY_APP_PASSWORD` — Bluesky app password

## Key Files

- `src/main.zig` — All bot logic (HTTP, APIs, parsing, posting)
- `build.zig` — Build configuration
- `.github/workflows/check_release.yml` — 15-minute cron job
- `last_version.txt` — State file (cached, not committed)
