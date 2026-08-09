# Issue classifier

The issue classifier uses GitHub Models to apply the repository's existing
labels to new and updated issues. It is disabled until the repository variable
`ISSUE_CLASSIFIER_ENABLED` is set to `true`.

## Behavior

- Automatic runs occur when an issue is opened or edited.
- Comments trigger reconciliation only when they come from the issue author or
  a user associated with the repository as `OWNER`, `MEMBER`, or
  `COLLABORATOR`. Pull request comments are ignored.
- Model context contains the current issue followed by trusted comments,
  newest first. Content and comment counts are capped by `config.json`.
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
  90% and primary-label coverage is at least 60%. Requests are paced to stay
  within the model's free low-tier request rate.

Manual dispatches bypass the automatic per-issue quota. Set `dry_run` to false
only when intentionally reconciling the selected issue.

## Rollout

1. An organization owner enables GitHub Models and permits
   `openai/gpt-4o-mini` for the repository.
2. Merge this workflow while `ISSUE_CLASSIFIER_ENABLED` is absent or false.
3. Run the unit-test workflow, the historical evaluation, and a manual dry run.
4. Set `ISSUE_CLASSIFIER_ENABLED` to `true` in repository Actions variables.
5. After verifying a live maintainer-created issue, enable public issue
   creation in the repository's Issues settings.

Keep paid GitHub Models usage disabled or use a zero-dollar budget unless the
maintainers explicitly choose otherwise. Set `ISSUE_CLASSIFIER_ENABLED` to
`false` as the kill switch if accuracy, quota use, or label churn is
unacceptable.
