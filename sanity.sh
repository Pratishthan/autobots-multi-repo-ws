make clean
make setup
source .venv/bin/activate
make install
make install-dev
cd autobots-agents-jarvis
make sanity
