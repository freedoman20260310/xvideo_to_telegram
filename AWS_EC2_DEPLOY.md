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

Optional values:

- `XVIDEO_ADMIN_CHAT_IDS`: Telegram numeric user/chat IDs allowed to manage X cookies
- `XVIDEO_COOKIES_FILE`: where the bot stores Netscape-format X cookies, default `/var/lib/xvideo-to-telegram/x-cookies.txt`
- `XVIDEO_STAGING_DIR`: where temporary videos are downloaded and merged, default `/var/lib/xvideo-to-telegram/staging/default`
- `FFMPEG_BIN`: ffmpeg path used for post-processing and Telegram video thumbnails, default `/usr/bin/ffmpeg`

The installer stores them in `/etc/xvideo-to-telegram.env` with mode `600`.

If `/getMe` returns HTTP `404`, the bot token is wrong or was copied with extra characters. The token must be the full BotFather value, for example `123456789:AA...`, not the bot username and not the `api_hash`.

If a bad token was already written to `/etc/xvideo-to-telegram.env`, rerun the installer and it will ask again. You can also override it in one command:

```bash
sudo XVIDEO_BOT_TOKEN='123456789:AA...' \
TELEGRAM_API_ID='123456' \
TELEGRAM_API_HASH='abcdef123456' \
./deploy_ec2.sh
```

Upload progress pacing can be tuned in the same env file:

- `XVIDEO_LOCAL_UPLOAD_PROGRESS_CAP`: percent reserved for submitting the file to the local Bot API server, default `12`
- `XVIDEO_TELEGRAM_UPLOAD_EST_MBPS`: estimated Bot API server to Telegram upload speed in MB/s, default `0.35`

## X Cookies

Some X posts only expose video metadata to a logged-in browser session. The bot supports an optional `cookies.txt` file:

- If `XVIDEO_COOKIES_FILE` points to a readable file, yt-dlp uses it for both probing and downloading.
- If the file is missing, the bot continues in guest mode.
- Only IDs in `XVIDEO_ADMIN_CHAT_IDS` can upload, inspect, or delete cookies.

To enable Telegram-based cookie upload:

1. Send `/id` to the bot and note your `user_id`.
2. Add that ID to the server env and restart:

```bash
sudo sed -i 's/^XVIDEO_ADMIN_CHAT_IDS=.*/XVIDEO_ADMIN_CHAT_IDS="123456789"/' /etc/xvideo-to-telegram.env
sudo systemctl restart xvideo-to-telegram.service
```

3. Export X cookies from a logged-in browser in Netscape `cookies.txt` format.
4. Send the `cookies.txt` file to the bot as a Telegram document.

Admin commands:

```text
/cookie_status
/delete_cookie
```

Treat `cookies.txt` like a password. It grants access to the logged-in X session until it expires or is revoked.

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

The app is installed under `/opt/xvideo-to-telegram`. Temporary videos are staged in `/var/lib/xvideo-to-telegram/staging/default` and removed after each job. Avoid using `/tmp` on small EC2 instances because it can be a small tmpfs and large HLS downloads need enough room for video, audio, and the merged temporary MP4 at the same time.

Before uploading with `sendVideo`, the bot also generates a small JPEG preview frame from the downloaded video and sends it as Telegram's `thumbnail`/`cover` fields. If thumbnail generation fails, the video is still sent normally.

## Add Another Bot

The local Telegram Bot API service is shared. To add another bot, create only a new bot instance:

```bash
sudo ./add_ec2_bot.sh bot2
```

The script asks for the new BotFather token, writes `/etc/xvideo-to-telegram/bot2.env`, and starts:

```bash
xvideo-to-telegram@bot2.service
```

Non-interactive:

```bash
sudo BOT_NAME='bot2' \
XVIDEO_BOT_TOKEN='123456789:AA...' \
./add_ec2_bot.sh
```

Each bot gets its own staging directory and log file:

```text
/var/lib/xvideo-to-telegram/staging/bot2
/var/log/xvideo-to-telegram/bot2.log
```

Additional bot instances inherit `XVIDEO_ADMIN_CHAT_IDS` and `XVIDEO_COOKIES_FILE` from the base deployment unless you override them when running `add_ec2_bot.sh`.
