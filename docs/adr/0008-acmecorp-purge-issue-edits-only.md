# AcmeCorp purge: recreate the identity repo, edit issues here — no history rewrite

Purging the former employer's name from the project takes two different routes by repo. The replacement name everywhere is **AcmeCorp**. The private identity repo is small and consumed only at its tip, so it is deleted and recreated with a clean initial history, renames baked in (key filenames, ssh aliases, gitconfigs, README). This repo keeps its git history untouched — the name appears in issue bodies and comments, which are edited in place, and in one blob (`docs/research/salvage-audit.md` at an old commit) that stays. A `git filter-repo` rewrite would invalidate every commit SHA referenced from issues, PRs, and the map, and GitHub retains orphaned blobs until support-triggered GC anyway — the cure was judged worse than the residue.

Decided while charting [map v2](https://github.com/dbarjs/agent-devcontainer/issues/20); the rejected history rewrite is recorded in its Out-of-scope section.
