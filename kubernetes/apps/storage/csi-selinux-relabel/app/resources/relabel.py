#!/usr/bin/env python3
"""Keep CSI block-volume filesystems labelled `ephemeral_t` for SELinux.

Both CSI drivers here hand back a bare filesystem that was mkfs'd with no
`security.selinux` xattrs -- democratic-csi's iSCSI LUNs (formatted on TrueNAS)
and Rook's RBD images alike. Every file and directory on such a volume is
therefore `unlabeled_t`, and a confined pod (`pod_t`) writing to one produces an
AVC denial per access. SELinux is permissive on Talos, so the write *succeeds*
and nothing breaks -- the only consequence is an audit record. That is not free:
on 2026-09-10 a single pod on an unlabelled volume produced 205,826 denials in
74 minutes, overflowed the kernel audit backlog (`audit_lost=60209`) and wedged
the node. See docs/incidents/2026-09-10-worker-02-wedge.md.

The fix that works is relabelling the volume root's xattr; new files, subdirs and
nested files all inherit the label from their parent directory. The fix that does
*not* work -- and was tried first -- is a `context=` mount option on the
StorageClass: democratic-csi runs mount(8) from inside its node-plugin container,
where libselinux reports SELinux disabled, so libmount strips every
`context=`-family option before the kernel sees it, silently and with no error.

Why `ephemeral_t` and not `container_file_t`: Talos ships its own SELinux policy
with ~121 types and `container_file_t` is not one of them. `pod_t` carries the
`pod_p` attribute, and the policy allows `pod_p -> ephemeral_t` for both `dir`
and `file` with full read/write/create. It is also the label Talos gives its own
EPHEMERAL partition, where pod data normally lives.

Runs as a DaemonSet so it sees every node's mounts, and re-scans on an interval
so a *newly provisioned* volume gets labelled shortly after it is first attached
rather than only when someone remembers to do it by hand.

## The two invariants that make this cheap and safe to re-run

1. **The root directory's label is the "this volume is done" marker, and it is
   written LAST.** A volume whose root is already correct is skipped without
   being walked, so steady state costs one lstat per volume per cycle rather
   than a full tree walk. That is only sound because a partial walk -- killed
   pod, node reboot, evicted mid-run -- leaves the root still wrong, so the next
   cycle redoes it. Do not "optimise" this by setting the root first.

2. **The walk never crosses a device boundary and never follows a symlink.**
   `st_dev` is checked against the mount's own device before descending, and
   every xattr call passes `follow_symlinks=False`. Without both, a symlink or a
   nested mount inside a volume would walk the script out onto the host
   filesystem and relabel things that are correctly labelled something else.

Relabelling is safe against live, running databases: it writes an xattr, not
data. Postgres, Prometheus and VictoriaLogs were all relabelled in place during
the 2026-09-11 rollout with zero restarts.

One-shot use (this is also how the original rollout was done, before this ran as
a DaemonSet) -- against any pod that mounts the host's /var/lib/kubelet:

    kubectl exec -n rook-ceph <rbd-nodeplugin-pod> -c csi-rbdplugin -i -- \
      python3 - < relabel.py

with RELABEL_INTERVAL_SECONDS=0 to exit after one pass, or RELABEL_DRY_RUN=true
to report without writing.
"""

import collections
import os
import select
import sys
import time

ATTR = "security.selinux"

# Only CSI volume mounts, and only local block filesystems. NFS and CephFS are
# deliberately excluded: they are shared filesystems whose labels are not the
# node's to set, they are reported to SELinux as `nfs_t`/`network_fs_t` rather
# than `unlabeled_t`, and most NFS exports reject `security.*` xattrs outright.
PREFIX = "/var/lib/kubelet/plugins/kubernetes.io/csi/"
MARKER = "/globalmount"

CONTEXT = os.environ.get("RELABEL_CONTEXT", "system_u:object_r:ephemeral_t:s0")
FSTYPES = set(
    t for t in os.environ.get("RELABEL_FSTYPES", "ext2,ext3,ext4,xfs,btrfs").split(",") if t
)
# Upper bound on how long a newly attached volume can stay unlabelled. It is a
# ceiling, not a cadence: the loop also wakes whenever the mount table changes,
# so in practice a new volume is labelled within RELABEL_SETTLE_SECONDS of being
# mounted. Set to 0 to sweep once and exit.
INTERVAL = int(os.environ.get("RELABEL_INTERVAL_SECONDS", "300"))

# Minimum gap between sweeps, and the debounce after a mount-table change. A pod
# starting makes a burst of mounts; waiting a moment coalesces the burst into one
# sweep instead of one per mount. Also the floor that keeps a pathological poll
# from spinning.
SETTLE = int(os.environ.get("RELABEL_SETTLE_SECONDS", "10"))
DRY_RUN = os.environ.get("RELABEL_DRY_RUN", "false").lower() in ("1", "true", "yes")
MOUNTINFO = os.environ.get("RELABEL_MOUNTINFO", "/proc/self/mountinfo")
NODE = os.environ.get("NODE_NAME", "unknown")
# Walk every volume on the first sweep after start, ignoring the root marker.
# The marker can only be trusted if whatever wrote it was correct; a run that
# labelled roots without being able to label their contents (as the first
# DaemonSet rollout did, lacking CAP_FOWNER) leaves volumes that look done and
# are not. Re-verifying on start makes a pod restart the repair. Steady-state
# cost is a getxattr per inode, with nothing written on a clean volume.
VERIFY_ON_START = os.environ.get("RELABEL_VERIFY_ON_START", "true").lower() in ("1", "true", "yes")

# getxattr returns a NUL-terminated string, and setxattr is given one, matching
# what the kernel and setfattr(1) do. A label written without the NUL compares
# unequal to one read back, which would make every cycle redo every volume.
GOOD = CONTEXT.encode() + b"\x00"


def log(msg):
    print("[%s] %s" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg), flush=True)


def unescape(path):
    # mountinfo escapes space, tab, newline and backslash as octal.
    for octal, char in (("\\040", " "), ("\\011", "\t"), ("\\012", "\n"), ("\\134", "\\")):
        path = path.replace(octal, char)
    return path


def discover():
    """Every mounted CSI globalmount on a local block filesystem, as (path, source)."""
    found = {}
    with open(MOUNTINFO) as fh:
        for line in fh:
            fields = line.split()
            try:
                # Fields after the optional-field separator are fixed-position;
                # the fields before it are not, because there can be any number
                # of optional fields (shared:, master:, propagate_from:).
                sep = fields.index("-")
            except ValueError:
                continue
            mountpoint, fstype, source = unescape(fields[4]), fields[sep + 1], fields[sep + 2]
            if not mountpoint.startswith(PREFIX) or MARKER not in mountpoint:
                continue
            if fstype not in FSTYPES:
                continue
            found[mountpoint] = source
    return sorted(found.items())


def label_of(path):
    try:
        return os.getxattr(path, ATTR, follow_symlinks=False)
    except OSError:
        # ENODATA on a filesystem that has the xattr but not this one; ENOTSUP
        # on one that has no security namespace at all. Neither is `GOOD`, so
        # both fall through to a write attempt, which reports the real error.
        return None


def descendants(root, dev):
    """Every path under `root`, excluding `root` itself. Same device only."""
    for parent, dirs, files in os.walk(root):
        kept = []
        for name in dirs:
            path = os.path.join(parent, name)
            try:
                if os.lstat(path).st_dev != dev:
                    continue  # a nested mount -- not this volume's to relabel
            except OSError:
                continue
            kept.append(name)
            yield path
        dirs[:] = kept  # os.walk descends into exactly what is left here
        for name in files:
            yield os.path.join(parent, name)


def relabel(mountpoint, source):
    """Full walk of one volume. Returns (written, errors, seconds)."""
    started = time.time()
    stats = collections.Counter()

    try:
        dev = os.lstat(mountpoint).st_dev
    except OSError as err:
        log("volume=%s source=%s SKIP stat failed: %s" % (mountpoint, source, err))
        return 0, 1, time.time() - started

    def apply(path):
        if label_of(path) == GOOD:
            stats["ok"] += 1
            return
        if DRY_RUN:
            stats["would"] += 1
            return
        try:
            os.setxattr(path, ATTR, GOOD, follow_symlinks=False)
            stats["set"] += 1
        except OSError as err:
            stats["err"] += 1
            if stats["err"] <= 3:
                log("  errno=%d %s" % (err.errno, path))

    # Two passes. The first can take minutes on a large volume, and the workload
    # keeps writing throughout; the second catches whatever it created. Anything
    # created after the second pass inherits the label from its parent directory,
    # which pass one already fixed -- so two is enough, and a third would find
    # nothing. A dry run does one pass only: with nothing actually written, a
    # second pass would re-count every entry and report double the real work.
    for _ in ((1,) if DRY_RUN else (1, 2)):
        for path in descendants(mountpoint, dev):
            apply(path)

    # Root last, and only if everything under it succeeded -- otherwise the
    # marker would claim a volume is done when it is not, and every later sweep
    # would skip it. See invariant 1 in the module docstring.
    if stats["err"]:
        log("  root left unlabelled: %d errors under %s" % (stats["err"], mountpoint))
    else:
        apply(mountpoint)

    return stats["set"] + stats["would"], stats["err"], time.time() - started


def sweep(verify=False):
    volumes = discover()
    dirty = volumes if verify else [(m, s) for m, s in volumes if label_of(m) != GOOD]

    if not dirty:
        log("clean node=%s volumes=%d" % (NODE, len(volumes)))
        return

    log(
        "start node=%s volumes=%d %s=%d context=%s%s"
        % (
            NODE,
            len(volumes),
            "verify" if verify else "dirty",
            len(dirty),
            CONTEXT,
            " DRY_RUN" if DRY_RUN else "",
        )
    )
    written = errors = 0
    for mountpoint, source in dirty:
        vol_written, vol_errors, seconds = relabel(mountpoint, source)
        written += vol_written
        errors += vol_errors
        if verify and not (vol_written or vol_errors):
            continue  # a verify pass over a clean volume is not worth a line
        log(
            "  %s %s written=%d errors=%d %.1fs"
            % (source, mountpoint[len(PREFIX):][:16], vol_written, vol_errors, seconds)
        )
    log("done node=%s volumes=%d written=%d errors=%d" % (NODE, len(dirty), written, errors))


def wait_for_mount_change(timeout):
    """Block until the mount table changes, or `timeout` seconds pass.

    poll(2) on /proc/self/mountinfo reports POLLPRI|POLLERR whenever the mount
    table changes -- the same mechanism `findmnt --poll` uses. Watching it is
    what turns RELABEL_INTERVAL_SECONDS from a cadence into a backstop: a volume
    attached just after a sweep gets labelled seconds later instead of up to a
    full interval later. That window is the whole point of running this at all,
    because an unlabelled volume under a busy pod produced roughly 46 denials
    per second during the 2026-09-10 incident.

    The file must be read to EOF before polling. An unread procfs file is
    already readable, so poll would return immediately every time and the loop
    would degrade to spinning at the SETTLE floor.
    """
    time.sleep(min(SETTLE, timeout))
    remaining = timeout - SETTLE
    if remaining <= 0:
        return
    try:
        with open(MOUNTINFO) as fh:
            fh.read()
            poller = select.poll()
            poller.register(fh, select.POLLPRI | select.POLLERR)
            poller.poll(remaining * 1000)
    except Exception as err:
        log("mount-table poll unavailable (%r); falling back to sleep" % (err,))
        time.sleep(remaining)


def main():
    if not os.path.isdir(PREFIX):
        # Not fatal: a node can legitimately have no CSI volumes attached yet,
        # and kubelet creates this directory on the first one.
        log("note: %s does not exist yet on node=%s" % (PREFIX, NODE))

    verify = VERIFY_ON_START
    while True:
        try:
            sweep(verify)
            verify = False
        except Exception as err:  # keep the DaemonSet alive; the next sweep retries
            log("sweep FAILED: %r" % (err,))
        if INTERVAL <= 0:
            return
        wait_for_mount_change(INTERVAL)


if __name__ == "__main__":
    sys.exit(main())
