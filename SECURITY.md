# Security policy

## Reporting a vulnerability

Please don't open a public issue for a security problem.

Report it privately through GitHub instead: go to the **Security** tab of this repo and choose **Report a vulnerability**. Include:

- what the problem is and which file it's in (`start.sh`, `Dockerfile`, `fly.toml`, ...)
- how to reproduce it
- what an attacker could do with it

You should get a reply within a week. Once a fix is ready, it is released and the report is credited, unless you'd rather stay anonymous.

## Scope

This repo is a deployment wrapper. It contains no application code of its own. In scope:

- `start.sh`: credential handling, the S3 mount, Cloudflare Tunnel setup, and process shutdown
- `Dockerfile`: what gets installed, and with which privileges
- `fly.toml` and `docker-compose.yml`: exposed ports, mounts, and defaults
- the CI workflow in `.github/workflows/`
- any README instruction that would leave a deployment insecure if followed

Bugs in the software this repo packages belong upstream:

| Component | Report to |
|---|---|
| Audiobookshelf | https://github.com/advplyr/audiobookshelf/security |
| rclone | https://github.com/rclone/rclone/security |
| cloudflared | https://github.com/cloudflare/cloudflared/security |
| Fly.io platform | Fly.io's own security contact |

If you aren't sure where a problem belongs, report it here and it will be passed on.

## Supported versions

Only the latest commit on the default branch is supported. The images in `Dockerfile` and `fly.toml` are pinned by tag and digest, and they are updated to pick up upstream security fixes.

## Security model

What a deployment of this repo is meant to guarantee:

- **No public address.** The Fly app has no HTTP service and no open ports. It is reachable only through an outbound Cloudflare Tunnel, and Cloudflare Access checks every request against the owner's policy before it enters the tunnel.
- **The library is read-only.** The bucket is mounted with `--read-only`, and the S3 key should allow only read and list on that bucket.
- **Credentials are never committed.** S3 credentials and the tunnel token live in Fly secrets. `.env` is ignored by both git and the Docker build.
- **The app doesn't inherit credentials.** `start.sh` removes them from the environment before Audiobookshelf starts.

Known limitation: Audiobookshelf currently runs as root in the container. A compromised Audiobookshelf process could therefore read the credentials from other processes through `/proc`, including the tunnel token held by `cloudflared`. Anyone with the tunnel token can run a connector for the tunnel, so rotate it in the Cloudflare dashboard if you suspect a compromise.

## Hardening your deployment

- Use a read-only S3 key scoped to the one bucket. See "Provider settings" in `README.md`.
- Create the Cloudflare Access application before you add the tunnel's public hostname, so the app is never public. Allow only named emails, not "everyone".
- Give each phone its own Access service token, and revoke it if the phone is lost.
- Check that the Fly app has no public IPs: `fly ips list`.
- Create the Audiobookshelf admin account right after the first deploy, and give it a strong password.
- Keep the pinned image versions current.
