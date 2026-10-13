# Musify server

YouTube won't let the phone download songs, so the app asks this server,
which runs [yt-dlp](https://github.com/yt-dlp/yt-dlp) (kept up to date: it
reinstalls the newest on every start and restarts once a day when idle).

- `GET /audio/<video id>.m4a`: the song as M4A (AAC as YouTube has it, not
  re-encoded) with title, artist and cover.
- `GET /charts`: YouTube Music's Top 100 Global, US, UK, Canada, Australia
  and India.
- `GET /playlist?id=<playlist id>`: any public playlist's tracks.
- `GET /health`

Every request needs `X-Musify-Key: <key>` (or `?key=`).

## Deploy (asotool, `~/musify`)

```sh
rsync -a server/ asotool:~/musify/     # .env stays on the server
ssh asotool 'cd ~/musify && echo "MUSIFY_KEY=$(openssl rand -hex 24)" > .env'  # first time only
ssh asotool 'cd ~/musify && docker compose up -d --build'
ssh asotool 'cp ~/musify/musify.caddy ~/caddy-sites/ && docker exec aso_tool-caddy-1 caddy reload --config /etc/caddy/Caddyfile'
```

Logs: `ssh asotool 'docker logs -f musify-api'`.
