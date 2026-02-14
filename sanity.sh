# Grab the .env file
cp autobots-agents-jarvis/.env .env.sanity

# Cleanup
rm -rf autobots-devtools-shared-lib
rm -rf autobots-agents-jarvis

# Clone the repositories
git clone https://github.com/Pratishthan/autobots-devtools-shared-lib.git

git clone https://github.com/Pratishthan/autobots-agents-jarvis.git
cd autobots-agents-jarvis
git checkout develop
cd ..

# Setup
make clean
make setup
source .venv/bin/activate
make install
make install-dev
cp .env.sanity autobots-agents-jarvis/.env
cd autobots-agents-jarvis
make sanity
