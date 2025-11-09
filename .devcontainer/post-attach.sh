#!/bin/bash

# Fix Docker socket permissions (run as sudo without password)
if [ -S /var/run/docker.sock ]; then
    sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
fi

echo "=== GAR Development Environment ==="
echo "Ruby version: $(ruby -v)"
echo "Bundler:      $(bundler -v)"
echo "Node.js:      $(node -v)"
echo "PostgreSQL:   $(psql --version)"
echo ""
echo "Dev DB:  postgresql://postgres@db-dev:5432/gar_db_dev"
echo "Test DB: postgresql://postgres@db-test:5432/gar_db_test"
echo ""
echo "=== Quick Start ==="
echo "make help             - show available commands"
echo "bundle exec rspec     - run tests"
echo "bundle exec rubocop   - run linter"
