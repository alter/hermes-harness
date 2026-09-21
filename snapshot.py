# snapshot.py
import os
import shutil
import subprocess
import sys
import tempfile


def git(workdir, *args, env=None):
    done = subprocess.run(["git", *args], cwd=workdir, env=env, check=True, capture_output=True, text=True)
    return done.stdout.strip()


def worktree_tree(workdir, excludes):
    index = git(workdir, "rev-parse", "--git-path", "index")
    if not os.path.isabs(index):
        index = os.path.join(workdir, index)
    handle, scratch = tempfile.mkstemp(prefix="hh-index.")
    os.close(handle)
    try:
        if os.path.exists(index):
            shutil.copyfile(index, scratch)
        else:
            os.unlink(scratch)
        env = dict(os.environ, GIT_INDEX_FILE=scratch)
        spec = [".", ":!.hermes-notes"] + [f":!{name}" for name in excludes if name]
        # git add -A exits 1 whenever a given pathspec's bare name (magic prefix and
        # all) also matches a .gitignore entry, even as an exclusion — which is the
        # normal case here, since a project usually gitignores its own task tree.
        # The staging itself is still correct; only the advisory exit code is not.
        subprocess.run(["git", "add", "-A", "--", *spec], cwd=workdir, env=env, capture_output=True, text=True)
        return git(workdir, "write-tree", env=env)
    finally:
        if os.path.exists(scratch):
            os.unlink(scratch)


def main():
    try:
        print(worktree_tree(sys.argv[1], sys.argv[2:]))
    except Exception:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
