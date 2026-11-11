# Audiobookshelf + a read-only FUSE mount of an S3-compatible bucket.
#
# Build args let you pin versions without editing this file:
#   ABS_IMAGE    the upstream Audiobookshelf image
#   RCLONE_IMAGE the rclone image; only its static /usr/local/bin/rclone binary is used
#   CLOUDFLARED_IMAGE the cloudflared image; only its static cloudflared binary is used
#
# Each image is pinned by digest. The tag is kept for readability, but Docker
# pulls by the digest, so a re-pushed tag can't change what gets built. The
# digests are multi-arch indexes (amd64 for Fly, arm64 for Apple Silicon).
# To bump a version, get the new digest with:
#   docker buildx imagetools inspect <image>:<tag>
# and update it here and in fly.toml [build.args] (and docker-compose.yml for rclone).
ARG ABS_IMAGE=ghcr.io/advplyr/audiobookshelf:2.37.2@sha256:b897c33f05972fb1bf484f7487bc878fa91ec8691335c1db6e2929c3a7658efa
ARG RCLONE_IMAGE=rclone/rclone:1.76.0@sha256:7cbeec24a44f206067597c0368be4de90ae19a64d5113c7d1938bd737a81e466
ARG CLOUDFLARED_IMAGE=cloudflare/cloudflared:2026.10.7@sha256:4955524aeaa379e154023d5a027c250f7b35041a2e7e950cf13f144bc9b9c5ba

FROM ${RCLONE_IMAGE} AS rclone
FROM ${CLOUDFLARED_IMAGE} AS cloudflared

FROM ${ABS_IMAGE}

# FUSE userspace tools (needed for rclone mount), tini (PID 1 signal handling
# and zombie reaping), and CA certificates for HTTPS to the S3 endpoint.
# Works on Alpine- or Debian/Ubuntu-based images.
RUN set -eux; \
    if command -v apk >/dev/null 2>&1; then \
        apk add --no-cache fuse3 tini ca-certificates; \
    elif command -v apt-get >/dev/null 2>&1; then \
        apt-get update; \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends fuse3 tini ca-certificates; \
        rm -rf /var/lib/apt/lists/*; \
    else \
        echo "Unsupported base image: need apk or apt-get" >&2; exit 1; \
    fi; \
    ln -sf "$(command -v tini)" /usr/local/bin/tini; \
    echo "user_allow_other" >> /etc/fuse.conf

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY --from=cloudflared /usr/local/bin/cloudflared /usr/local/bin/cloudflared
COPY start.sh /usr/local/bin/start.sh
RUN chmod 0755 /usr/local/bin/start.sh && rclone version && cloudflared --version

# Config and metadata live on one persistent volume (see fly.toml).
# Audiobooks are served from the read-only mount at /audiobooks.
ENV CONFIG_PATH=/data/config \
    METADATA_PATH=/data/metadata \
    MOUNT_POINT=/audiobooks \
    CACHE_DIR=/data/rclone-cache

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/tini", "--", "/usr/local/bin/start.sh"]
# Start command for Audiobookshelf (run from the image's WORKDIR, /app on 2.37.x).
# Confirm it against the pinned image with:
#   docker inspect ghcr.io/advplyr/audiobookshelf:2.37.2 --format '{{json .Config.Cmd}} {{json .Config.Entrypoint}} {{json .Config.WorkingDir}}'
CMD ["node", "dist-server/index.js"]
