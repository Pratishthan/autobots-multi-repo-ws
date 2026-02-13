# Objective

To create a sample repo `autobots-agents-jarvis` which provides users an insight on how to use functionality provided by `autobots-devtools-shared-lib.dynagent`


# Motivation

Users of `autobots-devtools-shared-lib.dynagent` can quickly clone the Jarvis repo and tailor it for their use case.


# Conditions:

1. Jarvis should have atleast 2 business agents
   1. Joke agent
   2. Weather agent
2. Should also have a welcome agent that will be default agent
3. At least 1 of the 2 business agents should have a output schema
4. At least 1 of the 2 business agents should be batch enabled along with a snippet to call the agent in batch mode.

# Values

APP_NAME=jarvis

USE_CASE=jarvis

# How

1. Make a copy of `autobots-agents-bro` and call it `autobots-agents-jarvis`
2. Update `configs/bro` to `configs/jarvis`
3. Copy relevant files and tests
4. Avoid the word BRO, Use case etc.
