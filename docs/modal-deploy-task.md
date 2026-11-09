# Task: Deploy Audiobookshelf on Modal.com

Deploy Audiobookshelf (a Node.js app, not a Python app) on Modal.com so it runs on demand and scales to zero when idle.

## Goal

- Public HTTPS URL that wakes the app on the first request, with no manual enable step and no extra auth.
- Container stops automatically after about 5 minutes without requests, and I'm billed only while it runs.
- My data must never be corrupted or lost.

## Constraints

- Use the official Docker image `ghcr.io/advplyr/audiobookshelf` via `modal.Image.from_registry(...)`. Pin a specific version tag, not `latest`.
- The Python file is only the Modal wrapper. Launch the app with `@modal.web_server(13378, startup_timeout=120)` and start the Node process from it. Check the image's entrypoint and working directory first, and don't guess the start command.
- `max_containers=1`, `@modal.concurrent(max_inputs=...)` for multiple requests, and `scaledown_window=300`.
- SQLite must NOT run directly on a Modal Volume (locking and commit semantics make it unsafe). Instead:
  - Keep `/config` and `/metadata` on the container's local disk while running.
  - In `@modal.enter`, restore them from a Modal Volume.
  - In `@modal.exit`, copy them back and call `volume.commit()`.
  - Also run a background thread that syncs and commits every 2 to 3 minutes, using SQLite's backup API or a safe copy of the DB so there is no half-written file.
- Audiobooks and podcasts: mount my S3 bucket read-only with `modal.CloudBucketMount` at `/audiobooks`. Ask me for the bucket name, region and credentials. Create a `modal.Secret` for the AWS keys and don't hardcode them.
- Handle SIGTERM gracefully so the final sync finishes before shutdown.

## Process

1. Read the Modal docs for `web_server`, Volumes, `CloudBucketMount` and lifecycle hooks, and check the current API names.
2. Write `modal_app.py` in `~/audiobookshelf-modal/`.
3. Show me the file and explain it.
4. **STOP and ask my permission** before running `modal deploy` or `uv run modal deploy`. It overwrites live apps.
5. After I approve: deploy, print the URL, open it, and confirm the first-run setup page loads.
6. Test the lifecycle: wait for scale-down, check that the container stopped, request the URL again, and confirm my user, library and progress survived the restart.

## Report

- The URL, the estimated idle cost, and the monthly cost for my usage.
- Known risks, such as cold-start time and what is lost if the container is killed without a clean exit.
- How to back up the Volume.
