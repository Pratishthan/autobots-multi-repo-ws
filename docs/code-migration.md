Since autobots-agents-mer/ has its own .git, all bundle commands run from inside it.

# Step 1 — First Full Bundle

  `cd /Users/pralhad/work/src/ws-autobots/autobots-agents-mer`

## Tag the current state so you can reference it later

  `git tag bundle-v1`

## Create the full bundle

  `git bundle create ~/Desktop/mer-bundle-v1.bundle --all`

## Share mer-bundle-v1.bundle with yourself.

---

# Step 2 — On the Other end (Receive)

## Clone from the bundle

    `git clone mer-bundle-v1.bundle autobots-agents-mer`

# Set up a real remote once you have org repo access

  `git remote set-url origin <org-repo-url>`

---

# Step 3 — Next Incremental Bundle (After More Commits)

  `cd /Users/pralhad/work/src/ws-autobots/autobots-agents-mer`

## Tag the new state

  `git tag bundle-v2`

## Bundle only what's new since last tag

  `git bundle create ~/Desktop/mer-bundle-v2.bundle bundle-v1..bundle-v2`

---

# Step 4 — On the Other Laptop (Apply Incremental)

  `cd autobots-agents-mer`

## Verify the bundle is valid before applying

  `git bundle verify ~/path/to/mer-bundle-v2.bundle`

## Fetch and merge the new commits

  `git fetch ~/path/to/mer-bundle-v2.bundle 'refs/heads/*:refs/heads/*'`

---

#  Cheatsheet for Ongoing Workflow

## Each new sync cycle — replace N with version number

  `git tag bundle-vN`
  `git bundle create ~/Desktop/mer-bundle-vN.bundle bundle-v(N-1)..bundle-vN`

  Tip: List your tags anytime to see where you left off:
  `git tag -l "bundle-*"`
