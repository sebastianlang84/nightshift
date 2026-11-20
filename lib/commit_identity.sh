#!/usr/bin/env bash
# The identity the Runner commits under. finalize in bin/nightshift.sh writes it; reconcile in
# bin/harvest.sh reads the author mail back to tell a Runner commit from a base commit a branch
# merely points at. Both must see the same value, so it lives here once.
NIGHTSHIFT_COMMIT_NAME="nightshift"
NIGHTSHIFT_COMMIT_EMAIL="nightshift@localhost"
