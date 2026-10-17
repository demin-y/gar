.PHONY: help setup install clean
.PHONY: dev-db-up dev-db-down dev-db-reset dev-db-logs dev-db-shell dev-db-psql
.PHONY: test-db-up test-db-down test-db-reset test-db-logs test-db-shell test-db-psql
.PHONY: db-up db-down db-reset db-status db-info
.PHONY: test console rubocop rubocop-fix

# Цвета для вывода
CYAN := \033[0;36m
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m

# Default target
.DEFAULT_GOAL := help

# Docker Compose команды
COMPOSE := docker compose
COMPOSE_PROJECT := -p gar
COMPOSE_DEV := $(COMPOSE) $(COMPOSE_PROJECT) up -d db-dev
COMPOSE_TEST := $(COMPOSE) $(COMPOSE_PROJECT) up -d db-test
COMPOSE_ALL := $(COMPOSE) $(COMPOSE_PROJECT) up -d db-dev db-test

# Database URLs
DEV_DB_URL := postgresql://postgres:postgres@localhost:6432/gar_db_dev
TEST_DB_URL := postgresql://postgres:postgres@localhost:6433/gar_db_test

##@ Общие команды

help: ## Показать это сообщение помощи
	@echo '$(CYAN)Использование:$(NC)'
	@echo '  make <target>'
	@echo ''
	@awk 'BEGIN {FS = ":.*##"; printf ""} /^[a-zA-Z_-]+:.*?##/ { printf "  $(CYAN)%-20s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(YELLOW)%s$(NC)\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

setup: ## Первоначальная настройка проекта (bundle install + dev БД)
	@echo "$(GREEN)Первоначальная настройка GAR...$(NC)"
	@echo "$(CYAN)Установка зависимостей...$(NC)"
	@bundle install
	@echo "$(CYAN)Запуск dev БД...$(NC)"
	@$(MAKE) dev-db-up
	@echo "$(GREEN)Настройка завершена!$(NC)"
	@echo "$(YELLOW)Запустите 'make console' для интерактивной консоли$(NC)"

install: ## Установить Ruby gems
	@echo "$(CYAN)Установка Ruby gems...$(NC)"
	@bundle install
	@echo "$(GREEN)Gems установлены!$(NC)"

clean: ## Очистить все Docker контейнеры и volumes
	@echo "$(YELLOW)Остановка всех контейнеров и удаление volumes...$(NC)"
	@$(COMPOSE) $(COMPOSE_PROJECT) down -v --remove-orphans
	@echo "$(GREEN)Очистка завершена!$(NC)"

##@ Development База Данных (порт 6432)

dev-db-up: ## Запустить dev БД
	@echo "$(CYAN)Запуск dev PostgreSQL (порт 6432)...$(NC)"
	@$(COMPOSE_DEV)
	@echo "$(GREEN)Dev БД запущена!$(NC)"
	@echo "$(YELLOW)Connection: $(DEV_DB_URL)$(NC)"
	@echo "$(YELLOW)Для примеров: export GAR_DATABASE_URL=$(DEV_DB_URL)$(NC)"

dev-db-down: ## Остановить dev БД
	@echo "$(CYAN)Остановка dev БД...$(NC)"
	@$(COMPOSE) $(COMPOSE_PROJECT) stop db-dev
	@echo "$(GREEN)Dev БД остановлена!$(NC)"

dev-db-reset: ## Сбросить dev БД (удалить volume и пересоздать)
	@echo "$(YELLOW)Сброс dev БД...$(NC)"
	@$(COMPOSE) $(COMPOSE_PROJECT) rm -f -s db-dev
	@docker volume rm -f gar_postgres_dev_data 2>/dev/null || true
	@echo "$(CYAN)Запуск свежей dev БД...$(NC)"
	@$(COMPOSE_DEV)
	@echo "$(GREEN)Dev БД сброшена!$(NC)"

dev-db-logs: ## Показать логи dev БД
	@$(COMPOSE) $(COMPOSE_PROJECT) logs -f db-dev

dev-db-shell: ## Открыть bash shell в dev БД контейнере
	@$(COMPOSE) $(COMPOSE_PROJECT) exec db-dev bash

dev-db-psql: ## Подключиться к dev БД через psql
	@$(COMPOSE) $(COMPOSE_PROJECT) exec db-dev psql -U postgres -d gar_db_dev

##@ Test База Данных (порт 6433)

test-db-up: ## Запустить test БД
	@echo "$(CYAN)Запуск test PostgreSQL (порт 6433)...$(NC)"
	@$(COMPOSE_TEST)
	@echo "$(GREEN)Test БД запущена!$(NC)"
	@echo "$(YELLOW)Connection: $(TEST_DB_URL)$(NC)"

test-db-down: ## Остановить test БД
	@echo "$(CYAN)Остановка test БД...$(NC)"
	@$(COMPOSE) $(COMPOSE_PROJECT) stop db-test
	@echo "$(GREEN)Test БД остановлена!$(NC)"

test-db-reset: ## Сбросить test БД (удалить volume и пересоздать)
	@echo "$(YELLOW)Сброс test БД...$(NC)"
	@$(COMPOSE) $(COMPOSE_PROJECT) rm -f -s db-test
	@docker volume rm -f gar_postgres_test_data 2>/dev/null || true
	@echo "$(CYAN)Запуск свежей test БД...$(NC)"
	@$(COMPOSE_TEST)
	@echo "$(GREEN)Test БД сброшена!$(NC)"

test-db-logs: ## Показать логи test БД
	@$(COMPOSE) $(COMPOSE_PROJECT) logs -f db-test

test-db-shell: ## Открыть bash shell in test БД контейнере
	@$(COMPOSE) $(COMPOSE_PROJECT) exec db-test bash

test-db-psql: ## Подключиться к test БД через psql
	@$(COMPOSE) $(COMPOSE_PROJECT) exec db-test psql -U postgres -d gar_db_test

##@ Управление обеими БД

db-up: ## Запустить ОБЕ БД (dev + test)
	@echo "$(CYAN)Запуск обеих БД...$(NC)"
	@$(COMPOSE_ALL)
	@echo "$(GREEN)Обе БД запущены!$(NC)"
	@echo "$(YELLOW)Dev:  $(DEV_DB_URL)$(NC)"
	@echo "$(YELLOW)Test: $(TEST_DB_URL)$(NC)"

db-down: ## Остановить ОБЕ БД
	@echo "$(CYAN)Остановка обеих БД...$(NC)"
	@$(COMPOSE) $(COMPOSE_PROJECT) stop db-dev db-test
	@echo "$(GREEN)Обе БД остановлены!$(NC)"

db-reset: ## Сбросить ОБЕ БД (алиас для совместимости)
	@$(MAKE) dev-db-reset
	@$(MAKE) test-db-reset

db-status: ## Показать статус всех БД контейнеров
	@echo "$(CYAN)Статус контейнеров:$(NC)"
	@docker ps -a --filter "name=db_dev" --filter "name=db_test" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

db-info: ## Показать информацию о подключении к БД
	@echo "$(CYAN)Информация о БД:$(NC)"
	@echo "$(YELLOW)Development БД:$(NC)"
	@echo "  URL: $(DEV_DB_URL) (GAR_DATABASE_URL для примеров)"
	@echo "  Порт: 6432"
	@echo "  База: gar_db_dev"
	@echo ""
	@echo "$(YELLOW)Test БД:$(NC)"
	@echo "  URL: $(TEST_DB_URL)"
	@echo "  Порт: 6433"
	@echo "  База: gar_db_test"
	@echo "  Данные: Gar::TestSupport.load_fixtures при запуске спек (схема gar)"

##@ Тестирование и разработка

test: ## Запустить тесты (автоматически управляет test БД)
	@echo "$(CYAN)Запуск тестов...$(NC)"
	@bundle exec rake spec
	@echo "$(GREEN)Тесты завершены!$(NC)"

console: ## Запустить интерактивную Ruby консоль
	@echo "$(CYAN)Запуск консоли...$(NC)"
	@bin/console

rubocop: ## Запустить линтер RuboCop
	@echo "$(CYAN)Запуск RuboCop...$(NC)"
	@bundle exec rubocop

rubocop-fix: ## Автоматическое исправление ошибок RuboCop
	@echo "$(CYAN)Автоисправление RuboCop...$(NC)"
	@bundle exec rubocop -a
