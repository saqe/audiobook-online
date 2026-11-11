# AGENTS.md

Guidance for AI coding agents working in this repo.

## What this repo is

A thin deployment wrapper around the public Audiobookshelf image. It runs Audiobookshelf on Fly.io, with audiobooks mounted read-only from an S3-compatible bucket via rclone FUSE. See `README.md` for the architecture and deploy steps.

There is no application source code here. The code is:

- `start.sh`: shell entrypoint. Checks S3 access, mounts the bucket, starts Audiobookshelf, handles shutdown.
- `Dockerfile`: layers rclone, fuse3, and tini onto the Audiobookshelf image.
- `fly.toml`: Fly app config (volume, env, HTTP service, VM).
- `docker-compose.yml`: local test rig with an rclone S3 server standing in for a real bucket.

## Testing

There is no unit test suite. Verify changes with these:

1. **Syntax-check the shell script:**
   ```sh
   sh -n start.sh
   ```
   If `shellcheck` is installed, run `shellcheck start.sh` too.
2. **Local end-to-end test** (needs Docker with FUSE access):
   ```sh
   mkdir -p local-bucket/audiobooks/"Author One"/"Book A"
   cp some-book.m4b local-bucket/audiobooks/"Author One"/"Book A"/01.m4b
   docker compose up --build
   ```
   Then open http://localhost:8080 and add `/audiobooks` as a library. Check the logs for `[start] mounted /audiobooks`.
3. **Image build only:**
   ```sh
   docker build -t abs-s3 .
   ```
4. **Fly config check** (no deploy):
   ```sh
   fly config validate
   ```

Do not run `fly deploy` or change Fly secrets unless the user asks. Those affect a live app.

## Conventions

- Keep `start.sh` POSIX-compatible `sh` unless there is a reason to change it. The Dockerfile supports base images with either `apk` or `apt-get`.
- Fail fast with a clear message. Startup should exit on a bad endpoint, bucket, prefix, or key rather than start with an empty library.
- The S3 mount must stay read-only (`--read-only`). Don't add write paths to the bucket.
- Unset S3 credentials and `TUNNEL_TOKEN` in the environment before starting Audiobookshelf, so the app never sees them.
- Access is through Cloudflare Tunnel plus Cloudflare Access only. Don't add an `[http_service]` or public IPs to `fly.toml`.
- Pin image versions (`fly.toml`, `docker-compose.yml`). Don't switch to `latest`.
- Keep config values in `fly.toml` `[env]` and credentials in Fly secrets. Never commit credentials.

## Gotchas

- `.dockerignore` excludes `*.md`, `fly.toml`, and `docker-compose.yml`. Changes to those files don't affect the image build.
- `.gitignore` excludes `local-bucket/`. Put test audio there, not in tracked paths.
- Audiobookshelf uses SQLite, so the app must run on a single Fly machine with one volume. Don't suggest scaling out.
- `README.md` is tracked. Edit it in place rather than creating a new readme file.

## Git

- Current working branch: `feat-cloudflare-tunnel-access`. `main` is the PR base.
- Don't commit or push unless the user asks.
- A PR from a branch with no commits beyond `main` will be refused by GitHub, so new work needs its own branch.
