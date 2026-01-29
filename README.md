# Claude Token Battery

A macOS menu bar app that displays Claude Code's 5-hour rate limit as a battery indicator.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- Token remaining percentage displayed in menu bar
- Color-coded status (green/yellow/red) based on remaining tokens
- Click to view detailed information including reset time
- Auto-detects subscription plan (Pro, Max5, Max20)
- Lightweight - calculates usage from local files without API calls

## Installation

### Build from Source

```bash
# Clone the repository
git clone https://github.com/tanukiti1987/ClaudeTokenBattery.git
cd ClaudeTokenBattery

# Build release version
./scripts/build-release.sh

# Install to Applications
cp -r .build/release/ClaudeTokenBattery.app /Applications/
```

### Run Directly

```bash
open .build/release/ClaudeTokenBattery.app
```

## How It Works

The app calculates token usage by parsing JSONL session files in `~/.claude/projects/`. It counts `input_tokens` and `output_tokens` from the last 5 hours (Claude Code's rate limit window).

### Plan Detection

The app automatically detects your subscription plan from `~/.claude/.credentials.json`.

Token limits are **estimated values** based on Max5 measurements:

| Plan | Token Limit (5h) | Multiplier | Rate Limit Tier |
|------|------------------|------------|-----------------|
| Pro | 12,000 | 1x (base) | `pro` |
| Max5 | 60,000 | 5x Pro | `default_claude_max_5x` |
| Max20 | 240,000 | 4x Max5 | `default_claude_max_20x` |

> **Note:** These are estimates. Actual limits may vary and are subject to change by Anthropic.

## Requirements

- macOS 13.0 or later
- Apple Silicon Mac (M1/M2/M3/M4)
- Claude Code CLI installed and authenticated

## Auto-start on Login

To launch automatically when you log in:

1. Open **System Settings** → **General** → **Login Items**
2. Add `ClaudeTokenBattery.app`

## Debug

Debug logs are written to `/tmp/claude-battery-debug.log`:

```bash
tail -f /tmp/claude-battery-debug.log
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [ccusage](https://github.com/ryoppippi/ccusage) - Reference for token calculation
- [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) - Similar project
