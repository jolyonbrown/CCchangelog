# CCchangelog

A bot that monitors [Claude Code](https://claude.ai/code) releases and posts changelog summaries to Bluesky as threaded posts.

Follow at [@claudecodechanges.bsky.social](https://bsky.app/profile/claudecodechanges.bsky.social)

## How it works

Every 15 minutes, a GitHub Actions cron job:

1. Checks the npm registry for the latest `@anthropic-ai/claude-code` version
2. Compares it against the last posted version (cached between runs)
3. If a new version is detected:
   - Fetches the changelog from the GitHub releases API
   - Parses bullet-point entries from the release body
   - Sends them to Claude Haiku to generate concise summaries
   - Posts a thread to Bluesky with a headline, changelog link, and detail posts

If no new version is found, the bot exits immediately without touching any API keys.

## Thread format

- **Post 1**: Version number, one-line AI summary, and a link to the full changelog
- **Posts 2+**: Batches of ~4 changelog entries, each summarized into ≤250 characters, numbered `[1/N]`, `[2/N]`, etc.

## Stack

Written in [Zig](https://ziglang.org/) (0.15.2). All HTTP and JSON handling uses the standard library — no external dependencies or shell scripts.

A prebuilt static Linux x86_64 binary is committed to the repo, so CI runs don't need to install Zig or compile anything.

## Setup

To run your own instance, fork this repo and add three secrets in **Settings > Secrets and variables > Actions**:

| Secret | Description |
|--------|-------------|
| `ANTHROPIC_API_KEY` | Anthropic API key (used for Claude Haiku summaries) |
| `BLUESKY_HANDLE` | Your Bluesky handle (e.g. `yourbot.bsky.social`) |
| `BLUESKY_APP_PASSWORD` | A Bluesky app password |

The workflow runs automatically on the 15-minute schedule and can also be triggered manually via **Actions > Check Claude Code Release > Run workflow**.

## Building from source

```bash
zig build                      # Debug build
zig build -Doptimize=ReleaseSafe  # Release build
zig build test                 # Run unit tests
zig build run                  # Build and run (requires env vars)
```

To update the committed binary after making changes:

```bash
zig build -Doptimize=ReleaseSafe
strip ./zig-out/bin/ccchangelog
cp ./zig-out/bin/ccchangelog ./ccchangelog
```
