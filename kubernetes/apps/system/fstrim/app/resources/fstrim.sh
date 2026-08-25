#!/bin/sh
# Periodically hand freed blocks back to the SSD controller (FITRIM) for the
# Talos EPHEMERAL filesystem.
#
# Talos mounts EPHEMERAL without the `discard` option and ships no fstrim timer,
# so nothing ever tells the drive which blocks the filesystem has released. The
# controller keeps treating every LBA it has ever written as live data, dynamic
# over-provisioning collapses toward zero, and write amplification climbs --
# which is how a control-plane system disk reached 160% of its rated endurance
# while its filesystem was only 41% full.
#
# Runs as a DaemonSet, not a CronJob: a CronJob schedules one Pod per firing, so
# it would only ever trim a single node. See helmrelease.yaml.
set -eu

MOUNTPOINT="${MOUNTPOINT:-/host/var}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-86400}"
JITTER_MAX_SECONDS="${JITTER_MAX_SECONDS:-1800}"

log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

if [ ! -d "${MOUNTPOINT}" ]; then
  log "FATAL: ${MOUNTPOINT} is not present; refusing to start"
  exit 1
fi

# Stagger the nodes. fstrim discards every free extent it finds, so letting a
# whole cluster fire simultaneously queues a large burst of discards against
# every drive at once -- harmless, but pointless when the schedule is arbitrary.
jitter="$(awk -v max="${JITTER_MAX_SECONDS}" 'BEGIN { srand(); print int(rand() * max) }')"

log "start node=${NODE_NAME:-unknown} mountpoint=${MOUNTPOINT} interval=${INTERVAL_SECONDS}s jitter=${jitter}s"
sleep "${jitter}"

while :; do
  started="$(date +%s)"

  # fstrim is expected to succeed against a read-only bind mount: FITRIM gates
  # on the *superblock* being writable, not the mount's MNT_READONLY flag, and
  # it does not take mnt_want_write(). If this ever returns EROFS, drop the
  # `readOnly: true` from the hostvar globalMount in helmrelease.yaml.
  if output="$(fstrim -v "${MOUNTPOINT}" 2>&1)"; then
    log "trim ok in $(($(date +%s) - started))s: ${output}"
  else
    rc=$?
    log "trim FAILED (exit ${rc}) in $(($(date +%s) - started))s: ${output}"
  fi

  log "sleeping ${INTERVAL_SECONDS}s"
  sleep "${INTERVAL_SECONDS}"
done
