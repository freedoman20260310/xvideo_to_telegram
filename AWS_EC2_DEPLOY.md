# AWS EC2 deployment

This project can run on one Ubuntu EC2 instance:

- `telegram-bot-api.service`: Dockerized local Telegram Bot API server on `127.0.0.1:8081`
- `xvideo-to-telegram.service`: Python bot using the local Bot API server

Use Ubuntu 22.04 or 24.04 LTS. A small instance such as `t3.small` works for light use; use a larger disk if you expect many large temporary videos. The security group only needs inbound SSH. Do not expose port `8081`.

## Credentials

You need three values:

- `XVIDEO_BOT_TOKEN`: Bot token from BotFather
- `TELEGRAM_API_ID`: Application `api_id` from `https://my.telegram.org`
- `TELEGRAM_API_HASH`: Application `api_hash` from `https://my.telegram.org`

The installer stores them in `/etc/xvideo-to-telegram.env` with mode `600`.

If `/getMe` returns HTTP `404`, the bot token is wrong or was copied with extra characters. The token must be the full BotFather value, for example `123456789:AA...`, not the bot username and not the `api_hash`.

Upload progress pacing can be tuned in the same env file:

- `XVIDEO_LOCAL_UPLOAD_PROGRESS_CAP`: percent reserved for submitting the file to the local Bot API server, default `12`
- `XVIDEO_TELEGRAM_UPLOAD_EST_MBPS`: estimated Bot API server to Telegram upload speed in MB/s, default `0.35`

## Install

Copy this repository to the EC2 instance, then run:

```bash
chmod +x deploy_ec2.sh
./deploy_ec2.sh
```

For non-interactive deployment:

```bash
XVIDEO_BOT_TOKEN='123:abc' \
TELEGRAM_API_ID='123456' \
TELEGRAM_API_HASH='abcdef123456' \
./deploy_ec2.sh
```

If you are moving the bot from the official Telegram Bot API to the local Bot API server, run the installer with:

```bash
CALL_TELEGRAM_LOGOUT=1 ./deploy_ec2.sh
```

Stop the old local bot instance before enabling the EC2 instance, otherwise Telegram long polling will return `409 Conflict`.

## Operations

```bash
systemctl status telegram-bot-api.service xvideo-to-telegram.service
journalctl -u xvideo-to-telegram.service -f
systemctl restart xvideo-to-telegram.service
```

The app is installed under `/opt/xvideo-to-telegram`. Temporary videos are staged in `/tmp/xvideo-dl` and removed after each job.
