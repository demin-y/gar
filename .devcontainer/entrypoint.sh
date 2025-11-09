#!/bin/bash
set -e

# Fix Docker socket permissions for non-root access
if [ -S /var/run/docker.sock ]; then
    # Make socket accessible to all users (needed for bind-mounted Docker socket)
    # Note: This is acceptable for local development environment
    sudo chmod 666 /var/run/docker.sock
fi

# Execute the command
exec "$@"
