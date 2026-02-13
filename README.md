# Python Multi-Repo Workspace

This workspace manages multiple Python repositories with a shared virtual environment. It uses `Dynagent` and `Jarvis` co-development as a use case.

## Pre-requisites

0. **Dependent Softwares**
   - Python 3.12
   - VS Code
   - Docker (OrbStack)
     - For Orbstack via Brew `brew install --cask orbstack`
1. **Getting base configs**
   - git clone repo into your repo directory with a name of your choice. In this case its `ws-jarvis`
     * `git clone https://github.com/Pratishthan/autobots-multi-repo-ws.git ws-jarvis`
   - Open VS Code from cloned location i.e. `ws-jarvis`
     * `cd ws-jarvis && code .`
2. **Cloning Other Repos**
   - Open VS Code terminal
   - Clone the necessary repos (inside the SAME workspace directory that you just cloned `ws-jarvis`)
     * `pwd` <- Should return `ws-jarvis`
     * `git clone https://github.com/Pratishthan/autobots-devtools-shared-lib.git`
     * `git clone https://github.com/Pratishthan/autobots-agents-jarvis.git`
   - In case you have additional repositories, clone the same and make entry in `autobots-multi.code-workspace` in `folders` and `files.exclude` sections
3. **Save Workspace**
   - File -> Save Workspace
   - Restart VS Code or from command pallet `Developer: Reload Window`

## Quick Start

1. **Initial Setup**

   To create a share venv for the workspace run the following commands from a VS Code terminal while in `ws-jarvis` directory
   ```bash
   make setup
   ```

   This creates a shared virtual environment at `.venv/`
2. **In Case of Additional Repositories**

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
## Starting Development

1. Go to `autobots-agents-bro`
2. Open a new terminal
3. IMPORTANT: Ensure .venv is exported before we start docker build
4. Copy .env.example to .env before we run the next commands
5. Run `make docker-build`
6. Run `make docker-up`

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
