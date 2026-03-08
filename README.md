# SaintBot

Control [Claude Code](https://claude.com/claude-code) from your phone via Signal.

SaintBot polls your Signal account for messages and forwards them to Claude Code with full tool access. Claude can read files, write code, run commands — everything it does in the terminal, but from your phone.

## Requirements

- Linux (tested on Fedora 43)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- Java 17+ (for signal-cli)
- `jq` and `qrencode` installed
- A Signal account on your phone

## Setup

### 1. Clone it

```bash
git clone https://github.com/GingerRouxt/saintbot.git
cd saintbot
```

### 2. Install signal-cli

```bash
# Download latest release (check https://github.com/AsamK/signal-cli/releases)
cd ~/bin  # or wherever you keep binaries
curl -L -o signal-cli.tar.gz "https://github.com/AsamK/signal-cli/releases/download/v0.14.0/signal-cli-0.14.0.tar.gz"
tar xzf signal-cli.tar.gz
ln -sf ~/bin/signal-cli-0.14.0/bin/signal-cli ~/bin/signal-cli
rm signal-cli.tar.gz
signal-cli --version
```

### 3. Install dependencies

```bash
# Fedora
sudo dnf install jq qrencode java-latest-openjdk

# Ubuntu/Debian
sudo apt install jq qrencode default-jdk
```

### 4. Link to your Signal account

```bash
./setup.sh
```

This shows a QR code in your terminal. Open Signal on your phone: **Settings > Linked Devices > Link New Device** and scan it.

### 5. Test the link

```bash
signal-cli -a +1YOURNUMBER receive
```

If you see sync messages, it worked.

### 6. Configure

```bash
cp saintbot.conf.example saintbot.conf
```

Edit `saintbot.conf` — add your phone number (with country code) to both `SIGNAL_ACCOUNT` and `ALLOWED_NUMBERS`.

### 7. Run it

```bash
./saintbot.sh
```

## Usage

Open **Note to Self** in Signal on your phone and send messages:

| Command | What it does |
|---------|-------------|
| `ping` | Check if SaintBot is alive |
| `status` | System stats (uptime, load, memory, disk) |
| `help` | List all built-in commands |
| `run ls -la` | Execute any shell command |
| Anything else | Sent to Claude Code — it will execute, not just chat |

### Examples

- "Make a directory called myproject"
- "What's in ~/projects?"
- "Create a Python script that checks disk usage"
- "Edit the config file in ~/myapp and change the port to 8080"
- `run docker ps`
- `status`

## Run in background

```bash
nohup ./saintbot.sh >> saintbot.log 2>&1 &
```

## Security

- Only phone numbers in `ALLOWED_NUMBERS` can send commands — everyone else is silently dropped
- `saintbot.conf` is gitignored so your number never gets committed
- Claude runs with `--dangerously-skip-permissions` — it can do anything on your machine. Only run this on machines you own.

## License

Do whatever you want with it.
