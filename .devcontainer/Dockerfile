FROM ruby:3.4.5-slim

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    openssh-client \
    git \
    curl \
    wget \
    gnupg \
    procps \
    pkg-config \
    libssl-dev \
    libpq-dev \
    postgresql-client \
    sudo \
    vim \
    nano \
    htop \
    less \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/debian \
            "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js LTS (через NodeSource)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g yarn

# Update RubyGems and install Bundler version
RUN gem update --system && gem install bundler

# Create docker group and non-root user
RUN groupadd -g 999 docker || true && \
    useradd -m -s /bin/bash vscode && \
    usermod -aG docker vscode && \
    echo "vscode ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/vscode && \
    chmod 0440 /etc/sudoers.d/vscode

# Create workspace directory
RUN mkdir -p /workspace && \
    chown -R vscode:vscode /workspace

# Copy entrypoint script
COPY --chmod=755 .devcontainer/entrypoint.sh /usr/local/bin/entrypoint.sh

# Switch to non-root user
USER vscode

ENV BUNDLE_PATH=/home/vscode/.bundle
ENV GEM_HOME=/home/vscode/.bundle

WORKDIR /workspace

# Pre-install Ruby dependencies for faster rebuilds
COPY --chown=vscode:vscode Gemfile gar.gemspec ./
COPY --chown=vscode:vscode lib/gar/version.rb lib/gar/version.rb
RUN bundle install --jobs=$(nproc) --retry=3

# Configure git for mounted workspace
RUN git config --global --add safe.directory /workspace

# Set entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
