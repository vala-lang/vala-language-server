# Issue classifier

The issue classifier uses the OpenAI Responses API to apply the repository's
existing labels to new and updated issues. It is disabled until the repository
variable `ISSUE_CLASSIFIER_ENABLED` is set to `true`.

## Behavior

- Automatic runs occur when an issue is opened or edited.
- Comments trigger reconciliation only when they come from the issue author or
  a user associated with the repository as `OWNER`, `MEMBER`, or
  `COLLABORATOR`. Pull request comments are ignored.
- Model context contains the current issue followed by trusted comments,
  newest first. Content and comment counts are capped by `config.json`.
- The classifier uses `gpt-5.6-luna` with reasoning disabled, strict structured
  output, no tools, and response storage disabled. Untrusted issue text is kept
  separate from the fixed classifier instructions. A normal classification is
  one Responses API request.
- A decision must meet the configured confidence threshold before it changes a
  label. Low-confidence decisions leave the current state unchanged.
- The workflow may remove only labels most recently applied by
  `github-actions[bot]`. Human additions are preserved, and a human removal is
  a sticky override.
- The workflow never gives the model tools, comments on an issue, closes it, or
  creates labels.

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
40 Responses API requests and consumes OpenAI API usage.

## Rollout

1. Create a dedicated OpenAI service account in a project with an appropriate
   budget and rate limits.
2. Add its key as an organization Actions secret named `OPENAI_API_KEY`, with
   access limited to `vala-lang/vala-language-server`. The pull-request test job
   does not receive this secret.
3. Merge this workflow while `ISSUE_CLASSIFIER_ENABLED` is absent or false.
4. Run the unit-test workflow, the historical evaluation, and a manual dry run.
5. Set `ISSUE_CLASSIFIER_ENABLED` to `true` in repository Actions variables.
6. After verifying a live maintainer-created issue, enable public issue
   creation in the repository's Issues settings.

Set `ISSUE_CLASSIFIER_ENABLED` to `false` as the kill switch if accuracy, API
usage, or label churn is unacceptable.
