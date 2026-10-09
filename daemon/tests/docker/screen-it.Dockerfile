# Runtime for the ignored screen test, `screen_lifecycle_end_to_end` in daemon/src/screen.rs.
# The image holds the programs the screen needs. The test binary is built in rust:1-bookworm
# and runs here, so no Rust toolchain is installed in this image. Commands: see the comment
# above the test in screen.rs.
FROM debian:bookworm-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xvfb x11vnc xauth x11-utils xdotool openbox imagemagick \
    && rm -rf /var/lib/apt/lists/*
