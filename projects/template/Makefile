.PHONY: up down lint test test-unit test-integration test-e2e

# CI runs exactly these targets (one job each, all required to merge into main).
# Replace the placeholders with your project's real commands.

up:
	docker compose up -d --wait

down:
	docker compose down -v

lint:
	@echo "TODO: add linters (e.g. ruff check . / npm run lint)"

test: test-unit test-integration test-e2e

test-unit:
	@echo "TODO: add unit tests (e.g. pytest tests/unit / npm run test:unit)"

# Integration and e2e tests may use AWS through $AWS_ENDPOINT_URL (Floci).
# Locally run `make up` first; in CI Floci is started as a service container.
test-integration:
	@echo "TODO: add integration tests (e.g. pytest tests/integration)"

test-e2e:
	@echo "TODO: add end-to-end tests (e.g. pytest tests/e2e / npx playwright test)"
