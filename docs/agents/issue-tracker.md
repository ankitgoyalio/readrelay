# Issue tracker

Track issues, specs, and tickets in GitHub Issues. Pass `--repo ankitgoyalio/readrelay` to each `gh issue` command so it targets this repository from forks and worktrees.

- Publish with `gh issue create --title <title> --body-file <file>`.
- Fetch with `gh issue view <number> --json number,title,body,labels,comments`. Use `gh issue list` with `--state` and `--label` filters to find tickets.
- Use native sub-issues and dependencies. On creation, use `--parent <number>` and `--blocked-by <numbers>`. For existing issues, use `gh issue edit <parent> --add-sub-issue <child>` and `gh issue edit <child> --add-blocked-by <blocker>`.
- Count open blockers with `gh issue view <number> --json blockedBy --jq '[.blockedBy.nodes[] | select(.state == "OPEN")] | length'`. A ticket is unblocked when all blockers are closed.
- Apply or remove labels with `gh issue edit <number> --add-label <label>` or `--remove-label <label>`.
- Post triage updates with `gh issue comment <number> --body-file <file>`. When closing an issue, post the reason before running `gh issue close <number>`.

**PRs as a request surface: no.**
