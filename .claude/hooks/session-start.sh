#!/bin/bash
# Подготовка облачной сессии Claude Code: гемы, PATH, UTF-8 и тестовый PostgreSQL,
# чтобы сразу работали `bundle exec rspec` и `bundle exec rubocop`.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# Бинарники гемов (rspec, rubocop) ставятся в Gem.bindir, которого нет в PATH облачного образа
GEM_BINDIR="$(ruby -e 'print Gem.bindir')"
export PATH="$GEM_BINDIR:$PATH"
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$GEM_BINDIR:\$PATH\""
    echo "export LANG=C.UTF-8"
  } >> "$CLAUDE_ENV_FILE"
fi

bundle check >/dev/null 2>&1 || BUNDLE_SILENCE_ROOT_WARNING=1 bundle install --quiet

# Тестовый PostgreSQL на :6433 (идемпотентно: если уже запущен — только проверяет базу)
bin/setup_test_db
