.PHONY: help setup clean install install-dev install-hooks test lint format check-format type-check all-checks update-deps

# Python version (customize as needed)
PYTHON := python3.12
# Use absolute path for venv so it works from subdirectories
ROOT_DIR := $(shell pwd)
VENV := $(ROOT_DIR)/.venv
BIN := $(VENV)/bin
PYTHON_BIN := $(BIN)/python
PIP := $(BIN)/pip

# List your repo directories here as you add them
REPOS := autobots-devtools-shared-lib autobots-agent-jarvis
# Example: REPOS := repo1 repo2 repo3

help:
	@echo "Available commands:"
	@echo "  make setup          - Create shared virtual environment and install pre-commit hooks"
	@echo "  make install        - Install dependencies from all repos"
	@echo "  make install-dev    - Install dev dependencies from all repos"
	@echo "  make clean          - Remove virtual environment and cache files"
	@echo "  make test           - Run tests from all repos"
	@echo "  make lint           - Run linter on all repos"
	@echo "  make format         - Format code in all repos"
	@echo "  make check-format   - Check code formatting without modifying"
	@echo "  make type-check     - Run type checker on all repos"
	@echo "  make all-checks     - Run all checks (lint, format check, type check, test)"
	@echo "  make update-deps    - Update all dependencies"
	@echo ""
	@echo "Current repos: $(REPOS)"

setup: $(VENV)/bin/activate

$(VENV)/bin/activate:
	@echo "Creating shared virtual environment..."
	$(PYTHON) -m venv $(VENV)
	$(PIP) install --upgrade pip setuptools wheel
	@echo "Installing common dev tools..."
	$(PIP) install black ruff pytest pytest-cov mypy isort pre-commit
	@echo ""
	@echo "Installing pre-commit hooks in all repos..."
	@for repo in $(REPOS); do \
		if [ -f "$$repo/.pre-commit-config.yaml" ]; then \
			echo "Installing hooks in $$repo..."; \
			(cd $$repo && $(BIN)/pre-commit install && $(BIN)/pre-commit install --hook-type commit-msg) || true; \
		fi; \
	done
	@echo ""
	@echo "Virtual environment created at $(VENV)"
	@echo "Pre-commit hooks installed in all repos"
	@echo "To activate: source $(VENV)/bin/activate"

install: setup
	@echo "Installing dependencies from all repos..."
	@for repo in $(REPOS); do \
		if [ -f "$$repo/requirements.txt" ]; then \
			echo "Installing from $$repo/requirements.txt..."; \
			$(PIP) install -r $$repo/requirements.txt; \
		fi; \
		if [ -f "$$repo/setup.py" ]; then \
			echo "Installing $$repo in editable mode..."; \
			$(PIP) install -e $$repo; \
		fi; \
		if [ -f "$$repo/pyproject.toml" ]; then \
			echo "Installing $$repo via pyproject.toml..."; \
			$(PIP) install -e $$repo; \
		fi; \
	done
	@echo "All dependencies installed!"

install-dev: setup
	@echo "Installing dev dependencies from all repos..."
	@for repo in $(REPOS); do \
		if [ -f "$$repo/requirements-dev.txt" ]; then \
			echo "Installing from $$repo/requirements-dev.txt..."; \
			$(PIP) install -r $$repo/requirements-dev.txt; \
		fi; \
		if [ -f "$$repo/setup.py" ]; then \
			echo "Installing $$repo with dev extras..."; \
			$(PIP) install -e "$$repo[dev]" 2>/dev/null || true; \
		fi; \
		if [ -f "$$repo/pyproject.toml" ]; then \
			echo "Installing $$repo with dev extras..."; \
			$(PIP) install -e "$$repo[dev]" 2>/dev/null || true; \
		fi; \
	done
	@echo "All dev dependencies installed!"

clean:
	@echo "Cleaning up..."
	rm -rf $(VENV)
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name ".mypy_cache" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name ".ruff_cache" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.pyc" -delete 2>/dev/null || true
	@echo "Cleanup complete!"

test: setup
	@echo "Running tests from all repos..."
	@for repo in $(REPOS); do \
		if [ -d "$$repo/tests" ] || [ -d "$$repo/test" ]; then \
			echo "Running tests in $$repo..."; \
			(cd $$repo && $(PYTHON_BIN) -m pytest -v) || true; \
		fi; \
	done

lint: setup
	@echo "Running linter on all repos..."
	@for repo in $(REPOS); do \
		if [ -d "$$repo" ]; then \
			echo "Linting $$repo..."; \
			$(BIN)/ruff check $$repo || true; \
		fi; \
	done

format: setup
	@echo "Formatting code in all repos..."
	@for repo in $(REPOS); do \
		if [ -d "$$repo" ]; then \
			echo "Formatting $$repo..."; \
			$(BIN)/black $$repo; \
			$(BIN)/isort $$repo; \
		fi; \
	done

check-format: setup
	@echo "Checking code formatting..."
	@for repo in $(REPOS); do \
		if [ -d "$$repo" ]; then \
			echo "Checking $$repo..."; \
			$(BIN)/black --check $$repo || true; \
			$(BIN)/isort --check-only $$repo || true; \
		fi; \
	done

type-check: setup
	@echo "Running type checker on all repos..."
	@for repo in $(REPOS); do \
		if [ -d "$$repo" ]; then \
			echo "Type checking $$repo..."; \
			$(BIN)/mypy $$repo || true; \
		fi; \
	done

all-checks: check-format lint type-check test
	@echo "All checks complete!"

update-deps: setup
	@echo "Updating all dependencies..."
	$(PIP) install --upgrade pip setuptools wheel
	@for repo in $(REPOS); do \
		if [ -f "$$repo/requirements.txt" ]; then \
			echo "Updating dependencies from $$repo/requirements.txt..."; \
			$(PIP) install --upgrade -r $$repo/requirements.txt; \
		fi; \
	done
	@echo "Dependencies updated!"
