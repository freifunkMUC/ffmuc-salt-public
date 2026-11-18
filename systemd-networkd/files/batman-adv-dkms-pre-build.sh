#!/bin/sh
# Runs in the DKMS build copy, not in the git checkout.
# Some distribution kernels (e.g. Ubuntu 6.8) backport the spinlock_bh lock
# guard. The batman-adv compat header then defines it a second time and the
# build fails. Drop the compat copy when the kernel already has the guard.
set -e
cd "$(dirname "$0")"
# Without .git the module reports the release version, not "<ver>-dirty".
rm -rf .git
if grep -q '^DEFINE_LOCK_GUARD_1(spinlock_bh,' "$1/include/linux/spinlock.h" 2>/dev/null; then
  sed -i '/^DEFINE_LOCK_GUARD_1(spinlock_bh,/,/))$/d' compat-include/linux/spinlock.h
fi
