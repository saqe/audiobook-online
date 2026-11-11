# Audiobookshelf on Fly.io, with audiobooks in S3

This repo runs [Audiobookshelf](https://github.com/advplyr/audiobookshelf) on a small Fly.io machine. Your audiobooks stay in an S3 bucket and are never copied to the server. The app is private: it's published through Cloudflare Tunnel, and Cloudflare Access lets in only the people you allow.

## How it fits together

- **Audio stays in S3.** The bucket is mounted read-only at `/audiobooks`, so Audiobookshelf reads files as if they were on disk. Audio is streamed from S3 when played and is not stored on the server.
- **The server keeps only small files.** Audiobookshelf's database, settings, and cover images live on a 1 GB Fly volume at `/data`.
- **Access is private.** The Fly app has no public address. `cloudflared` runs in the same container and dials out to Cloudflare. Cloudflare Access checks who you are at Cloudflare's edge, before any request reaches the machine.

```
Fly machine
├── tini                              process manager (PID 1)
└── start.sh
    ├── rclone lsf                    checks the bucket, endpoint, and key
    ├── rclone mount (read-only)      S3 bucket  ->  /audiobooks
    ├── cloudflared tunnel run        outbound tunnel to Cloudflare, forwards to port 80
    └── node dist-server/index.js     Audiobookshelf
```

### Why a mount instead of copying or symlinks

- **Copying the bucket at boot** would make startup slower as the library grows, and the volume would need to be as large as the whole library.
- **A symlink can't point at S3 on its own.** Something has to present the bucket as a filesystem. FUSE does that, so one mount covers the whole bucket and no per-file links are needed.
- **A mount starts fast.** Files are fetched only when they are read, and the volume holds only the database and covers.

### Safety

- **Read-only.** The mount is read-only and the S3 key only needs read access. Audiobookshelf can't change or delete your books.
- **Fail-fast.** If the endpoint, bucket, prefix, or key is wrong, the machine exits with a clear error instead of starting with an empty library.
- **Self-healing.** If the mount dies, Audiobookshelf stops, and Fly restarts the machine.
- **Secrets stay out of the app.** S3 credentials are removed from the environment before Audiobookshelf starts.

## Architecture

```mermaid
flowchart LR
    subgraph devices["Your devices (no client install needed)"]
        phone["iPhone: Audiobookshelf app or Safari"]
        mac["Mac: browser"]
    end

    subgraph cf["Cloudflare edge"]
        access["Cloudflare Access<br/>login + policy check"]
    end

    subgraph fly["Fly machine: sin, shared-cpu-1x, 256 MB RAM + 512 MB swap"]
        direction TB
        start["start.sh (PID 1 via tini)"]
        cfd["cloudflared (outbound only)"]
        abs["Audiobookshelf :80"]
        rclone["rclone mount, read-only, at /audiobooks"]
        vol[("Fly volume /data, 1 GB<br/>database, config, covers")]
    end

    s3[("S3 bucket (Cloudflare R2)<br/>audio files, read-only key")]

    phone -->|"HTTPS"| access
    mac -->|"HTTPS"| access
    cfd ==>|"outbound tunnel"| access
    access -->|"allowed requests only"| cfd
    cfd -->|"HTTP :80"| abs
    start -.->|starts| cfd
    start -.->|starts| rclone
    start -.->|starts| abs
    abs -->|"reads files"| rclone
    abs -->|"SQLite, covers"| vol
    rclone -->|"S3 API: list, ranged GET"| s3
```

The machine has no public service and no public IP address. `cloudflared` only makes outbound connections, so there is no open port to attack. Every request comes in through the tunnel, and Access has already checked it.

## Playback and seeking

```mermaid
sequenceDiagram
    actor U as Player
    participant A as Audiobookshelf
    participant R as rclone mount
    participant B as S3 bucket

    U->>A: GET the audio file, Range bytes=N-
    A->>R: read at offset N
    R->>B: GET the object, Range bytes=N-
    B-->>R: 206 stream
    R-->>A: bytes
    A-->>U: 206 Partial Content
    Note over U,B: Seeking closes the stream and opens a new ranged GET at the new offset. With VFS_CACHE_MODE=off nothing is stored on disk.
```

The request shapes above are typical, not captured logs.

## Where data lives

| Data | Where | Kept across redeploys? |
|---|---|---|
| Audio files | S3 bucket, read-only | Yes. Never copied. |
| Database, settings, covers | Fly volume `abs_data`, mounted at `/data` | Yes |
| Swap | Separate device, 512 MB | Not needed |
| S3 secrets and tunnel token | Fly secrets | Yes |
| Tunnel hostname and Access policy | Cloudflare Zero Trust dashboard | Yes |

## Deploy to Fly.io

### 1. Prepare the bucket and a read-only key

Create a bucket (for example `audiobooks`) and arrange books by author and title:

```
audiobooks/
  Author Name/
    Book Title/
      01.m4b
      cover.jpg
```

Create an access key that can **read and list only that bucket**. The table under [Provider settings](#provider-settings) shows how to do this for each provider.

### 2. Create the app and volume

```sh
fly launch --copy-config --no-deploy     # keeps this fly.toml; choose a unique app name
fly volumes create abs_data --region sin --size 1   # same region as primary_region
```

One gigabyte is the smallest volume Fly offers, and it's plenty for the database and covers.

### 3. Set the S3 secrets

```sh
fly secrets set \
  S3_ENDPOINT="https://<account-id>.r2.cloudflarestorage.com" \
  S3_BUCKET="audiobooks" \
  S3_ACCESS_KEY_ID="..." \
  S3_SECRET_ACCESS_KEY="..."
```

Set `S3_PROVIDER` and `S3_REGION` in `fly.toml` to match your provider. To mount only one folder of the bucket, set `S3_PREFIX`.

### 4. Set up Cloudflare Tunnel and Access, then deploy

Follow [Private access with Cloudflare](#private-access-with-cloudflare) first, then run:

```sh
fly deploy
```

### 5. Create the admin account and add a library

Open `https://<your-hostname>/` and sign in through Cloudflare Access (see [Private access](#private-access-with-cloudflare)). Create the admin account, then add a library:

- **Folder:** `/audiobooks`
- **Watch for changes:** off, if your version shows this option. Changes in S3 don't trigger filesystem events, so use **Scan** instead.
- **Store metadata with item:** off, if your version shows this option. Metadata has to stay on the volume, because `/audiobooks` is read-only.

Run **Scan** again after you upload new books to the bucket.

### Redeploys keep your data

The database, settings, and covers live on the `abs_data` volume, and `fly deploy` reattaches that same volume to the new machine. Only these actions delete data:

- `fly volumes destroy`
- `fly apps destroy`
- changing `source` in `[[mounts]]`, which creates a new, empty volume

Don't run `fly launch` again on an existing app, because it can create a new app and volume.

### Provider settings

| Provider | `S3_PROVIDER` | `S3_ENDPOINT` | `S3_REGION` |
|---|---|---|---|
| Cloudflare R2 | `Cloudflare` | `https://<account-id>.r2.cloudflarestorage.com` | `auto` |
| Backblaze B2 (S3 API) | `Other` | `https://s3.<region>.backblazeb2.com` | `<region>`, for example `us-west-004` |
| Tigris (Fly's S3) | `Other` | `https://fly.storage.tigris.dev` | `auto` |
| AWS S3 | `AWS` | `https://s3.<region>.amazonaws.com` | `<region>` |
| MinIO or other | `Minio` or `Other` | your endpoint URL | `us-east-1` or your region |

Use a read-only key:
- **Cloudflare R2:** an "Object Read" token.
- **Backblaze B2:** an application key limited to the bucket, with read-only capabilities.
- **AWS:** an IAM policy with `s3:GetObject` and `s3:ListBucket`.

## Private access with Cloudflare

The app is published on a hostname in your Cloudflare zone, for example `books.example.com`. Cloudflare Access sits in front of it, so only people who match your policy can load it. `start.sh` refuses to start without a tunnel token, so the app never runs unreachable.

Do these in the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/). You need a domain on Cloudflare.

1. **Create the Access application first**, so the hostname is never public, even for a moment. Go to **Access → Applications → Add an application → Self-hosted**.
   - **Domain:** `books.example.com`
   - **Policy:** action **Allow**, include **Emails** with your own address (or **Emails ending in** your domain). Add more emails for family members.
   - **Login methods:** One-time PIN works with no setup. Google or GitHub also work if you've added them under **Settings → Authentication**.
   - **Session duration:** a long one, such as 1 month, so the player isn't sent back to the login page often.
2. **Create the tunnel.** Go to **Networks → Tunnels → Create a tunnel → Cloudflared**, and name it `audiobookshelf`. Copy the token from the install command (the long string after `--token`). Skip the connector install step, because the container runs `cloudflared` itself.
3. **Add the public hostname** to the tunnel: subdomain `books`, your domain, service type **HTTP**, URL **`localhost:80`**. Cloudflare creates the DNS record for you.
4. **Store the token as a Fly secret.** Don't put it in the repo, `fly.toml`, the Dockerfile, or GitHub:
   ```sh
   fly secrets set --stage TUNNEL_TOKEN=eyJ...
   ```
5. **Deploy** with `fly deploy`, then open `https://books.example.com/`. Cloudflare shows its login page first, then Audiobookshelf.

### The Audiobookshelf phone app

The phone app can't show the Access login page, so give it a service token instead:

1. In Zero Trust, go to **Access → Service credentials → Service Tokens → Create Service Token**. Copy the Client ID and Client Secret.
2. In the Access application, add a second policy: action **Service Auth**, include **Service Token** set to that token.
3. In the phone app, when you add the server, open the advanced options and add two custom headers: `CF-Access-Client-Id` and `CF-Access-Client-Secret`, set to the values from step 1. If your app version doesn't offer custom headers, use the web player in Safari instead.

A service token works without a login, so treat it like a password. Revoke it in the dashboard if a phone is lost.

**Checks:**
- `fly logs` should show `[start] tunnel: connected to Cloudflare`, and the tunnel shows **Healthy** in the dashboard.
- If the token is wrong, `start.sh` exits with `cloudflared exited during startup. Check TUNNEL_TOKEN`.
- In a private browser window, `https://books.example.com/` should show the Cloudflare Access login page, not Audiobookshelf.

### Moving from Tailscale

Earlier versions of this repo used Tailscale. To switch an existing deployment:

1. Do steps 1–4 above.
2. Stage the removal of the old key, then deploy, so the machine restarts only once:
   ```sh
   fly secrets unset --stage TS_AUTHKEY
   fly deploy
   ```
3. Delete the old machine from the Tailscale admin console (**Machines**).
4. Optionally, remove the old Tailscale state from the volume: `fly ssh console -C "rm -rf /data/tailscale"`.

## Configuration

Set credentials as Fly secrets. Set everything else in `fly.toml` under `[env]`.

| Variable | Required | Default | What it does |
|---|---|---|---|
| `S3_ENDPOINT` | yes | | S3 API endpoint URL |
| `S3_BUCKET` | yes | | Bucket name |
| `S3_ACCESS_KEY_ID` | yes | | Read-only key ID (secret) |
| `S3_SECRET_ACCESS_KEY` | yes | | Read-only key secret (secret) |
| `TUNNEL_TOKEN` | yes | | Cloudflare Tunnel token (secret) |
| `S3_PROVIDER` | no | `Other` | rclone provider name (see the table above) |
| `S3_REGION` | no | `auto` | Region |
| `S3_PREFIX` | no | (bucket root) | Mount only this folder of the bucket |
| `MOUNT_POINT` | no | `/audiobooks` | Where the bucket appears |
| `VFS_CACHE_MODE` | no | `off` | `off` streams audio from S3 and stores nothing on the volume. `full` caches played files on the volume |
| `VFS_CACHE_MAX_SIZE` | no | `5G` | Cache size cap. Only used when `VFS_CACHE_MODE=full` |
| `DIR_CACHE_TIME` | no | `5m` | How long directory listings are cached before rereading the bucket |
| `CACHE_DIR` | no | `/data/rclone-cache` | Cache location, on the volume |

Set in the image, you don't need to change these: `CONFIG_PATH=/data/config` and `METADATA_PATH=/data/metadata`.

**Sizing.** With `VFS_CACHE_MODE=off`, the volume holds only the database, settings, and covers. In testing, that was about 0.5 MB. A 1 GB volume leaves plenty of room. Volumes can grow with `fly volumes extend` but can't shrink, so start small.

## Test locally first

The compose file runs an rclone S3 server as a stand-in bucket, so you can test without cloud accounts.

```sh
mkdir -p local-bucket/audiobooks/"Author One"/"Book A"
cp some-book.m4b local-bucket/audiobooks/"Author One"/"Book A"/01.m4b
docker compose up --build
```

Open http://localhost:8080 and add `/audiobooks` as a library. Local testing needs Docker with FUSE access. The compose file grants it with `/dev/fuse`, `SYS_ADMIN`, and `apparmor:unconfined`.

## Checks before going live

1. **FUSE on Fly.** After the first deploy, confirm the device exists and the mount works:
   ```sh
   fly ssh console -C "ls -l /dev/fuse"
   fly logs    # look for: [start] mounted /audiobooks
   ```
   If the mount fails, the startup script exits with a clear error. The fallback is to sync the bucket to the volume, which is slower to start and needs a volume as large as the library.
2. **Image versions.** The Dockerfile and `fly.toml` pin Audiobookshelf 2.37.2, rclone 1.76.0, and cloudflared 2026.10.7, each by tag and digest (`image:tag@sha256:...`). Docker pulls by the digest, so a re-pushed tag can't change the build. To upgrade, get the new digest with `docker buildx imagetools inspect <image>:<tag>`, then update it in the Dockerfile, `fly.toml`, and, for rclone, `docker-compose.yml`. Before you upgrade Audiobookshelf, check its start command against the new image:
   ```sh
   docker inspect ghcr.io/advplyr/audiobookshelf:<tag> --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}} {{json .Config.WorkingDir}}'
   ```
   The Dockerfile's `CMD` must match. On 2.37.2 it is `["node", "dist-server/index.js"]`, run from `/app`. On 2.19.0 it was `["node", "index.js"]`, run from `/`.
3. **Base image OS.** The Dockerfile installs `fuse3`, `tini`, and `ca-certificates` with `apk` or `apt-get`. It fails the build on any other base image.
4. **Swap.** `swap_size_mb` must be a top-level key in `fly.toml`. Inside `[[vm]]`, Fly ignores it without an error. After a deploy, check the machine with `fly ssh console -C "free -m"`.

## Operations

- **One machine only.** The volume attaches to a single machine, and Audiobookshelf uses SQLite, so don't scale beyond one machine.
- **The machine stays on.** `min_machines_running = 1` and `auto_stop_machines = "off"` keep playback from being interrupted. To save money when idle, set `auto_stop_machines = "stop"` and `min_machines_running = 0`, at the cost of a cold start.
- **Cache behavior.** With the default `VFS_CACHE_MODE=off`, every play streams from S3, so no audio is stored on the volume. This uses more S3 requests and bandwidth. Set `full` only if you want played books cached on the volume, and size the volume to fit `VFS_CACHE_MAX_SIZE`.
- **S3 charges.** Some providers charge per request or per download. Cloudflare R2 has no egress fees.
- **Adding books.** Upload new books to the bucket, then run **Scan** in Audiobookshelf. Directory listings are cached for `DIR_CACHE_TIME`, so new folders can take up to that long to appear.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds Audiobookshelf with rclone, FUSE, tini, and cloudflared |
| `start.sh` | Checks S3 access, mounts the bucket read-only, starts Cloudflare Tunnel, runs Audiobookshelf, handles shutdown |
| `fly.toml` | Fly app config: region, volume, environment, VM size, and swap |
| `docker-compose.yml` | Local test setup with an rclone S3 stand-in |
| `.env.example` | Template for the environment variables. Copy to `.env` (git-ignored) |
| `.github/workflows/docker-build.yml` | CI: lints `start.sh` and smoke-tests the image |
| `AGENTS.md` | Guidance for AI agents working in this repo |
| `SECURITY.md` | How to report a vulnerability, and the security model |
| `.dockerignore` | Keeps secrets and git data out of the image |
