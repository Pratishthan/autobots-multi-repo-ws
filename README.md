# Python Multi-Repo Workspace

This workspace manages multiple Python repositories with a shared virtual environment.

## Quick Start

1. **Initial Setup**
   ```bash
   make setup
   ```
   This creates a shared virtual environment at `.venv/`

2. **Add Your Repositories**
   - Clone your Python repos into this directory
   - Update `REPOS` variable in `Makefile` with repo directory names
   - Update `autobots-multi.code-workspace` to add folder entries for each repo

3. **Install Dependencies**
   ```bash
   make install        # Install all requirements
   make install-dev    # Install dev dependencies
   ```

4. **Open in VS Code**
   ```bash
   code autobots-multi.code-workspace
   ```

## Makefile Commands

- `make help` - Show all available commands
- `make setup` - Create shared virtual environment
- `make install` - Install dependencies from all repos
- `make install-dev` - Install dev dependencies
- `make clean` - Remove venv and cache files
- `make test` - Run tests from all repos
- `make lint` - Lint all repos
- `make format` - Format all code
- `make type-check` - Run type checker
- `make all-checks` - Run all checks
- `make update-deps` - Update all dependencies

## Directory Structure

```
autobots-multi/
├── .venv/                    # Shared virtual environment
├── autobots-multi.code-workspace   # VS Code workspace config
├── Makefile                  # Setup and task automation
├── .gitignore               # Git ignore rules
├── repo1/                   # Your first Python repo
│   ├── requirements.txt
│   └── ...
├── repo2/                   # Your second Python repo
│   ├── requirements.txt
│   └── ...
└── ...
```

## Adding a New Repository

1. Clone the repo:
   ```bash
   git clone <repo-url>
   ```

2. Update `Makefile`:
   ```makefile
   REPOS := repo1 repo2 new-repo
   ```

3. Update `autobots-multi.code-workspace`:
   ```json
   {
     "name": "new-repo",
     "path": "./new-repo"
   }
   ```

4. Install dependencies:
   ```bash
   make install
   ```

## VS Code Integration

The workspace is configured with:
- Shared Python interpreter from `.venv/`
- Auto-formatting with Black on save
- Import organization with isort
- Pytest integration
- Recommended extensions

## Notes

- All repos share the same virtual environment
- Install packages that all repos need in the shared venv
- Repo-specific packages are installed via each repo's requirements.txt
- The venv is git-ignored and local to your machine
