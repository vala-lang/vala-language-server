# Issue classifier

The issue classifier is a GitHub Agentic Workflow powered by OpenAI Codex. It
is disabled until the repository variable `ISSUE_CLASSIFIER_ENABLED` is set to
`true`.

## Safety boundary

The live workflow has three stages:

1. A deterministic Python pre-step fetches the issue and caps its body and
   trusted comments according to `config.json`. It also enforces the 45-second
   debounce and five-successful-runs-per-issue daily quota before inference.
2. Codex receives only that untrusted snapshot and the classification policy.
   It has read-only repository permissions and can request one custom safe
   output containing classification JSON.
3. A separate Python job validates the complete JSON contract and computes the
   reconciliation plan. This is the only generated job with `issues: write`.

The model never directly adds or removes labels. The reconciler requires 0.90
confidence, selects at most one primary label and two supplemental labels, and
may remove only labels most recently applied by `github-actions[bot]`. Human
label additions are preserved and human removals are sticky overrides. The
workflow cannot comment, close issues, or create labels or issues.

## Triggers and labels

Automatic runs occur when an issue is opened or edited. A created, edited, or
deleted comment triggers full reconciliation only when it comes from the issue
author or a repository `OWNER`, `MEMBER`, or `COLLABORATOR`; pull request
comments are ignored.

Primary labels are `bug`, `enhancement`, and `question`. Supplemental and
status labels are defined in `config.json`. The labels `duplicate`,
`help wanted`, `invalid`, `unconfirmed`, and `wontfix` remain human-only.

## Development and validation

Install the official compiler and regenerate the checked-in lockfile after
editing `issue-classifier.md`:

```sh
gh extension install github/gh-aw
gh aw compile issue-classifier --approve --validate --strict
```

Do not edit `issue-classifier.lock.yml` directly. Run the dependency-free test
suite with:

```sh
python3 -m unittest discover -s .github/issue-classifier -p "test_*.py"
```

The `Issue classifier validation` workflow runs those tests on pull requests.
Its manual dispatch can also run the model against the 40 historical cases in
`evaluation-cases.json`; evaluation fails below 90% applied-label precision or
60% primary-label coverage. The evaluator uses the same shared classification
policy and makes 40 OpenAI Responses API requests.

## Enablement

1. Add the service-account key as an Actions secret named `OPENAI_API_KEY`.
   For an organization secret, limit repository access to
   `vala-lang/vala-language-server`. The pull-request test job does not receive
   the secret. `CODEX_API_KEY` is also accepted and takes precedence if both
   exist.
2. Merge the workflow while `ISSUE_CLASSIFIER_ENABLED` is absent or `false`.
3. Manually dispatch `Issue classifier validation` with `evaluate` enabled.
4. Manually dispatch `Issue classifier` for one issue with `dry_run` enabled.
5. Set the repository Actions variable `ISSUE_CLASSIFIER_ENABLED` to `true`.

OpenAI API usage is billed to the project behind the service-account key. Set
`ISSUE_CLASSIFIER_ENABLED` to `false` as the kill switch if accuracy, cost, or
label churn is unacceptable.
