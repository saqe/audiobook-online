# Audiobookshelf + a read-only FUSE mount of an S3-compatible bucket.
#
# Build args let you pin versions without editing this file:
#   ABS_IMAGE    the upstream Audiobookshelf image
#   RCLONE_IMAGE the rclone image; only its static /usr/local/bin/rclone binary is used
ARG ABS_IMAGE=ghcr.io/advplyr/audiobookshelf:2.37.2
ARG RCLONE_IMAGE=rclone/rclone:1.76.0
ARG TAILSCALE_IMAGE=tailscale/tailscale:v1.104.4

FROM ${RCLONE_IMAGE} AS rclone
FROM ${TAILSCALE_IMAGE} AS tailscale

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
COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscale
COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscaled
COPY start.sh /usr/local/bin/start.sh
RUN chmod 0755 /usr/local/bin/start.sh && rclone version

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
