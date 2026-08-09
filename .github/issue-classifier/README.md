# Issue classifier

The issue classifier uses GitHub Copilot CLI to apply the repository's existing
labels to new and updated issues. It is disabled until the repository variable
`ISSUE_CLASSIFIER_ENABLED` is set to `true`.

## Behavior

- Automatic runs occur when an issue is opened or edited.
- Comments trigger reconciliation only when they come from the issue author or
  a user associated with the repository as `OWNER`, `MEMBER`, or
  `COLLABORATOR`. Pull request comments are ignored.
- Model context contains the current issue followed by trusted comments,
  newest first. Content and comment counts are capped by `config.json`.
- Copilot uses automatic model selection with its minimum supported 30-credit
  session cap. A custom agent exposes no tools, and the workflow disables
  built-in MCP servers and repository instructions before sending untrusted
  issue text. A normal classification is a single model response; the cap is a
  backstop, not an expected cost.
- A decision must meet the configured confidence threshold before it changes a
  label. Low-confidence decisions leave the current state unchanged.
- The workflow may remove only labels most recently applied by
  `github-actions[bot]`. Human additions are preserved, and a human removal is
  a sticky override.
- The workflow never comments on an issue, closes it, or creates labels.

## Managed labels

The primary labels are `bug`, `enhancement`, and `question`. Supplemental and
status labels are defined in `config.json`. The labels `duplicate`,
`help wanted`, `invalid`, `unconfirmed`, and `wontfix` remain human-only.

## Tests and evaluation

Run the dependency-free unit tests locally:

```sh
node --test .github/issue-classifier/classifier.test.mjs
```

The workflow's manual dispatch supports two modes:

- `classify` accepts an issue number and defaults to a dry run.
- `evaluate` runs the model against the 40 historical cases in
  `evaluation-cases.json`. It fails unless applied-label precision is at least
  90% and primary-label coverage is at least 60%.

Manual dispatches bypass the automatic per-issue quota. Set `dry_run` to false
only when intentionally reconciling the selected issue. The evaluation makes
40 Copilot requests and consumes organization-billed AI credits.

## Rollout

1. An organization owner enables Copilot CLI and selects **Allow use of
   Copilot CLI billed to the organization**. No long-lived secret is needed;
   the workflow uses its scoped `GITHUB_TOKEN`.
2. Merge this workflow while `ISSUE_CLASSIFIER_ENABLED` is absent or false.
3. Run the unit-test workflow, the historical evaluation, and a manual dry run.
4. Set `ISSUE_CLASSIFIER_ENABLED` to `true` in repository Actions variables.
5. After verifying a live maintainer-created issue, enable public issue
   creation in the repository's Issues settings.

Configure an organization cost center and budget before enabling automatic
runs. Set `ISSUE_CLASSIFIER_ENABLED` to `false` as the kill switch if accuracy,
credit use, or label churn is unacceptable.
