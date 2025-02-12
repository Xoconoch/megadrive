FROM ubuntu:24.10

ENV DEBIAN_FRONTEND=noninteractive

# Install required packages including gosu for privilege dropping.
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    jq \
    fuse3 \
    libfuse3-3 \
    ca-certificates \
    unzip \
    rclone \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Install MEGAcmd.
RUN apt-get update && \
    wget https://mega.nz/linux/repo/xUbuntu_24.10/amd64/megacmd-xUbuntu_24.10_amd64.deb && \
    apt install -y ./megacmd-xUbuntu_24.10_amd64.deb && \
    rm megacmd-xUbuntu_24.10_amd64.deb && \
    rm -rf /var/lib/apt/lists/*

# Set the working directory.
WORKDIR /app

# Copy the entrypoint script.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# Ensure the script is executable.
RUN chmod +x /usr/local/bin/entrypoint.sh

# Default command.
CMD ["/usr/local/bin/entrypoint.sh"]
