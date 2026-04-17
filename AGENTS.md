# Repository Guidelines

## Project Overview
This repository provides automated deployment scripts for OpenHands.

## Directory Structure
- `deploy.sh`: The main, executable deployment script.
- `templates/`: Contains configuration templates, specifically `nginx.conf.template`.

## Deployment Guidelines
- **Execution**: The `deploy.sh` script is executable (`chmod +x`). Run it with `./deploy.sh`.
- **Requirements**:
  - `uv`: Ensure the `uv` package manager is installed.
  - `openssl`: Required for SSL and authentication.
- **Modifications**:
  - The script uses absolute paths (resolved from the script location) to access files in `templates/`.
  - When modifying `deploy.sh`, maintain the use of absolute directory resolution for robust execution.
  - Passwords generated for Nginx (`.htpasswd`) use `openssl passwd -1`.

## Development & Testing
- When testing changes, ensure the `deploy.sh` remains functional in non-interactive shell environments (if applicable).
- Always verify shell script paths are absolute when changing working directories within the script to avoid "file not found" errors.

## Commit Guidelines
- Use clear, descriptive commit messages.
- Always include `Co-authored-by: openhands <openhands@all-hands.dev>` in commit messages.
- Avoid committing secrets or local configuration files (`.env`, `ssl/`, `nginx/`).
