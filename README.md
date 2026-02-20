# MoviePilot Installer & Manager

This is a bash script to seamlessly install, update, and manage the [MoviePilot](https://github.com/jxxghp/MoviePilot) project along with its frontend and plugins in a single Systemd service environment.

## Features
- **Auto Installation**: Checks and installs Python 3.12 and Node.js v20.
- **Unified Service**: Merges Frontend and Backend into a single `moviepilot.service` under `systemd`.
- **Interactive Configuration**: Prompts for custom `IP`, `Frontend Port`, and `Backend Port` on installation.
- **Easy Updates**: One-click update through `git pull` across all 3 components.
- **Service Management**: Simple menu to view logs, status, or restart services.

## Usage

```bash
chmod +x moviepilot_manager.sh
sudo ./moviepilot_manager.sh
```

Follow the on-screen interactive menu to manage your MoviePilot instance.