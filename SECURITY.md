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

- `start.sh`: credential handling, the S3 mount, Tailscale setup, and process shutdown
- `Dockerfile`: what gets installed, and with which privileges
- `fly.toml` and `docker-compose.yml`: exposed ports, mounts, and defaults
- the CI workflow in `.github/workflows/`
- any README instruction that would leave a deployment insecure if followed

Bugs in the software this repo packages belong upstream:

| Component | Report to |
|---|---|
| Audiobookshelf | https://github.com/advplyr/audiobookshelf/security |
| rclone | https://github.com/rclone/rclone/security |
| Tailscale | https://github.com/tailscale/tailscale/security |
| Fly.io platform | Fly.io's own security contact |

If you aren't sure where a problem belongs, report it here and it will be passed on.

## Supported versions

Only the latest commit on the default branch is supported. The images in `Dockerfile` and `fly.toml` are pinned by tag and digest, and they are updated to pick up upstream security fixes.

## Security model

What a deployment of this repo is meant to guarantee:

- **No public address.** The Fly app has no HTTP service. It is reachable only from devices on the owner's Tailscale network.
- **The library is read-only.** The bucket is mounted with `--read-only`, and the S3 key should allow only read and list on that bucket.
- **Credentials are never committed.** S3 and Tailscale credentials live in Fly secrets. `.env` is ignored by both git and the Docker build.
- **The app doesn't inherit credentials.** `start.sh` removes them from the environment before Audiobookshelf starts.

Known limitation: Audiobookshelf currently runs as root in the container. A compromised Audiobookshelf process could therefore read the credentials from other processes through `/proc`, and could read the Tailscale node key on the volume.

## Hardening your deployment

- Use a read-only S3 key scoped to the one bucket. See "Provider settings" in `README.md`.
- Use a single-use, tagged Tailscale auth key, and restrict access to the tag with an ACL so only your own devices can reach the app.
- Check that the Fly app has no public IPs: `fly ips list`.
- Create the Audiobookshelf admin account right after the first deploy, and give it a strong password.
- Keep the pinned image versions current.
