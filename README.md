# Plasma Codex Usage

A Plasma 6 panel widget for Codex account limits. It shows short-window and weekly usage with reset times.

## Requirements

- KDE Plasma 6
- Python 3 and a signed-in Codex CLI

## Install

```bash
git clone https://github.com/JungleM0nkey/plasma-codex-usage.git
cd plasma-codex-usage
kpackagetool6 --type Plasma/Applet --install .
```

Open **Add Widgets** and add **Codex Usage** to a panel.

The widget asks `codex app-server` for `account/rateLimits/read`. Codex takes care of auth.

License: GPL-3.0-or-later.
