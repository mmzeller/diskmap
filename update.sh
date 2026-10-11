#!/bin/bash
# Gets the latest DiskMap from GitHub, then builds and installs it.
# Usage:  bash update.sh
set -uo pipefail
cd "$(dirname "$0")"

if [ ! -d .git ]; then
  printf "\n\033[1;31m%s\033[0m\n" "This copy of DiskMap wasn't downloaded with git, so it can't update itself."
  echo "Set it up once with:"
  echo "    git clone https://github.com/mmzeller/diskmap.git ~/DiskMap"
  echo "Then from now on run:  bash ~/DiskMap/update.sh"
  exit 1
fi

printf "\n\033[1m%s\033[0m\n" "Getting the latest DiskMap…"
if ! git pull --ff-only; then
  printf "\n\033[1;31m%s\033[0m\n" "Couldn't update. If you changed files in this folder, run: git stash   then try again."
  exit 1
fi

bash build.sh
