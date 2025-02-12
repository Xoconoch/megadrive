FROM ubuntu:24.10

ENV DEBIAN_FRONTEND=noninteractive

# Install required dependencies, including unzip for rclone
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    jq \
    fuse3 \
    libfuse3-3 \
    ca-certificates \
    unzip \
    rclone \
    && rm -rf /var/lib/apt/lists/*

# Install MEGAcmd using the provided command.
RUN apt-get update && \
    wget https://mega.nz/linux/repo/xUbuntu_24.10/amd64/megacmd-xUbuntu_24.10_amd64.deb && \
    apt install -y "$PWD/megacmd-xUbuntu_24.10_amd64.deb" && \
    rm megacmd-xUbuntu_24.10_amd64.deb && \
    rm -rf /var/lib/apt/lists/*

# Set the working directory.
WORKDIR /app

# Copy script.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# Ensure the entrypoint script is executable.
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
