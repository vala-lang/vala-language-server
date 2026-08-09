import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  buildIssueInput,
  buildReconciliationPlan,
  evaluatePredictions,
  isTrustedCommentTrigger,
  managedLabels,
  predictedLabels,
  recentAutomaticRunCount,
} from "./classifier-core.mjs";
import { GitHubApi } from "./github-api.mjs";
import { requestClassification } from "./openai-classifier.mjs";

export * from "./classifier-core.mjs";
export { GitHubApi } from "./github-api.mjs";
export * from "./openai-classifier.mjs";

const MODULE_DIRECTORY = path.dirname(fileURLToPath(import.meta.url));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function truncate(value, maximum) {
  const text = value ?? "";
  if (text.length <= maximum) {
    return text;
  }

  const marker = "… [truncated]";
  if (maximum <= marker.length) {
    return marker.slice(0, maximum);
  }

  return `${text.slice(0, maximum - marker.length - 1)}\n${marker}`;
}

function formatPercent(numerator, denominator) {
  if (denominator === 0) {
    return "0.0%";
  }

  return `${((numerator / denominator) * 100).toFixed(1)}%`;
}

function markdownCell(value) {
  return String(value ?? "")
    .replaceAll("|", "\\|")
    .replaceAll("\n", " ");
}

function parseBoolean(value, fallback = false) {
  if (value === undefined || value === null || value === "") {
    return fallback;
  }

  return String(value).toLowerCase() === "true";
}

export async function loadConfig(
  configPath = path.join(MODULE_DIRECTORY, "config.json"),
) {
  const config = JSON.parse(await fs.readFile(configPath, "utf8"));

  assert(config.model, "Classifier model is required");
  assert(
    Number.isFinite(config.confidenceThreshold) &&
      config.confidenceThreshold >= 0 &&
      config.confidenceThreshold <= 1,
    "confidenceThreshold must be between zero and one",
  );
  assert(
    Object.keys(config.primaryLabels).length > 0,
    "At least one primary label is required",
  );
  assert(
    Number.isInteger(config.maxSupplementalLabels) &&
      config.maxSupplementalLabels >= 0,
    "maxSupplementalLabels must be a non-negative integer",
  );
  assert(
    ["none", "low", "medium", "high", "xhigh", "max"].includes(
      config.reasoningEffort,
    ),
    "reasoningEffort is invalid",
  );
  assert(
    Number.isInteger(config.maxOutputTokens) && config.maxOutputTokens > 0,
    "maxOutputTokens must be a positive integer",
  );
  assert(
    Number.isInteger(config.openaiTimeoutMilliseconds) &&
      config.openaiTimeoutMilliseconds > 0,
    "openaiTimeoutMilliseconds must be a positive integer",
  );

  const labels = managedLabels(config);
  assert(
    new Set(labels).size === labels.length,
    "Managed labels must be unique",
  );
  for (const label of config.neverAutomate ?? []) {
    assert(
      !labels.includes(label),
      `${label} cannot be both managed and human-only`,
    );
  }

  return config;
}

export async function validateRepositoryLabels(api, config) {
  const available = new Set(
    (await api.getRepositoryLabels()).map((label) => label.name),
  );
  const missing = managedLabels(config).filter(
    (label) => !available.has(label),
  );
  assert(
    missing.length === 0,
    `Configured repository labels do not exist: ${missing.join(", ")}`,
  );
}

export async function applyReconciliationPlan(api, issueNumber, plan, dryRun) {
  if (dryRun) {
    return;
  }

  await api.addLabels(issueNumber, plan.additions);
  for (const label of plan.removals) {
    await api.removeLabel(issueNumber, label);
  }
}

async function writeSummary(summaryPath, content) {
  if (summaryPath) {
    await fs.appendFile(summaryPath, `${content.trim()}\n`, "utf8");
  }
  process.stdout.write(`${content.trim()}\n`);
}

function classificationSummary({
  issue,
  classification,
  plan,
  dryRun,
  trustedCommentCount,
}) {
  const decisions = Object.entries(classification.decisions)
    .map(([label, decision]) => ({ label, ...decision }))
    .sort((left, right) => left.label.localeCompare(right.label));

  const lines = [
    `## Issue classifier: #${issue.number}`,
    "",
    `- Mode: ${dryRun ? "dry run" : "apply"}`,
    `- Trusted comments supplied: ${trustedCommentCount}`,
    `- Primary decision: ${classification.primary.label} (${classification.primary.confidence.toFixed(2)})`,
    `- Add: ${plan.additions.join(", ") || "none"}`,
    `- Remove: ${plan.removals.join(", ") || "none"}`,
    `- Preserved: ${plan.preserved.join("; ") || "none"}`,
    `- Abstained: ${plan.abstained.join("; ") || "none"}`,
    "",
    "| Label | Applicable | Confidence |",
    "| --- | --- | ---: |",
    ...decisions.map(
      (decision) =>
        `| ${markdownCell(decision.label)} | ${decision.applicable ? "yes" : "no"} | ${decision.confidence.toFixed(2)} |`,
    ),
  ];

  return lines.join("\n");
}

async function loadIssueContext(api, issueNumber, config) {
  const [issue, comments] = await Promise.all([
    api.getIssue(issueNumber),
    api.getComments(issueNumber),
  ]);
  assert(
    !issue.pull_request,
    `#${issueNumber} is a pull request, not an issue`,
  );
  const issueInput = buildIssueInput(issue, comments, config);
  return { issue, comments, issueInput };
}

async function runEvaluation({
  api,
  config,
  apiKey,
  openaiApiUrl,
  fetchImplementation,
  sleep,
  summaryPath,
  evaluationPath,
}) {
  const evaluation = JSON.parse(await fs.readFile(evaluationPath, "utf8"));
  assert(
    Array.isArray(evaluation.cases) && evaluation.cases.length === 40,
    "The evaluation set must contain exactly 40 cases",
  );

  const results = [];
  for (const evaluationCase of evaluation.cases) {
    process.stdout.write(`Evaluating issue #${evaluationCase.issueNumber}\n`);
    const { issueInput } = await loadIssueContext(
      api,
      evaluationCase.issueNumber,
      config,
    );
    const classification = await requestClassification({
      issueInput,
      config,
      apiKey,
      apiUrl: openaiApiUrl,
      fetchImplementation,
      sleep,
    });
    results.push({
      issueNumber: evaluationCase.issueNumber,
      expectedLabels: evaluationCase.expectedLabels,
      predictedLabels: predictedLabels(classification, config),
    });
  }

  const metrics = evaluatePredictions(results, config);
  const rows = results.map((result) => {
    const expected = result.expectedLabels.join(", ") || "none";
    const predicted = result.predictedLabels.join(", ") || "none";
    return `| #${result.issueNumber} | ${markdownCell(expected)} | ${markdownCell(predicted)} |`;
  });
  const summary = [
    "## Issue classifier evaluation",
    "",
    `- Precision: ${formatPercent(metrics.correctCount, metrics.predictedCount)}`,
    `- Primary-label coverage: ${formatPercent(metrics.correctPrimaryCount, metrics.expectedPrimaryCount)}`,
    `- Result: ${metrics.passed ? "pass" : "fail"}`,
    "",
    "| Issue | Expected | Predicted |",
    "| --- | --- | --- |",
    ...rows,
  ].join("\n");
  await writeSummary(summaryPath, summary);

  assert(
    metrics.passed,
    "Evaluation failed the 90% precision or 60% primary-label coverage gate",
  );
}

async function runClassification({
  api,
  config,
  issueNumber,
  dryRun,
  automatic,
  workflowFile,
  currentRunId,
  apiKey,
  openaiApiUrl,
  fetchImplementation,
  sleep,
  summaryPath,
}) {
  if (automatic) {
    const workflowRuns = await api.getWorkflowRuns(workflowFile);
    const recentRuns = recentAutomaticRunCount(
      workflowRuns.workflow_runs ?? [],
      issueNumber,
      currentRunId,
    );
    if (recentRuns >= config.automaticRunsPerIssuePerDay) {
      await writeSummary(
        summaryPath,
        `## Issue classifier: #${issueNumber}\n\nSkipped: the issue reached the limit of ${config.automaticRunsPerIssuePerDay} automatic classifications in 24 hours.`,
      );
      return;
    }

    await sleep(config.debounceMilliseconds);
  }

  await validateRepositoryLabels(api, config);
  const { issue, issueInput } = await loadIssueContext(
    api,
    issueNumber,
    config,
  );
  const events = await api.getIssueEvents(issueNumber);
  const classification = await requestClassification({
    issueInput,
    config,
    apiKey,
    apiUrl: openaiApiUrl,
    fetchImplementation,
    sleep,
  });
  const currentLabels = issue.labels
    .map((label) => (typeof label === "string" ? label : label.name))
    .filter(Boolean);
  const plan = buildReconciliationPlan(
    currentLabels,
    events,
    classification,
    config,
  );

  await applyReconciliationPlan(api, issueNumber, plan, dryRun);
  await writeSummary(
    summaryPath,
    classificationSummary({
      issue,
      classification,
      plan,
      dryRun,
      trustedCommentCount: issueInput.trusted_comments_newest_first.length,
    }),
  );
}

export async function main(
  environment = process.env,
  {
    fetchImplementation = globalThis.fetch,
    sleep = (milliseconds) =>
      new Promise((resolve) => setTimeout(resolve, milliseconds)),
  } = {},
) {
  const eventName = environment.GITHUB_EVENT_NAME ?? "workflow_dispatch";
  const event = environment.GITHUB_EVENT_PATH
    ? JSON.parse(await fs.readFile(environment.GITHUB_EVENT_PATH, "utf8"))
    : {};
  const mode = environment.CLASSIFIER_MODE || "classify";
  assert(
    mode === "classify" || mode === "evaluate",
    `Unsupported classifier mode: ${mode}`,
  );
  const token = environment.GITHUB_TOKEN;
  const repository = environment.GITHUB_REPOSITORY;
  const config = await loadConfig(environment.CLASSIFIER_CONFIG_PATH);
  const api = new GitHubApi({
    token,
    repository,
    apiUrl: environment.GITHUB_API_URL,
    fetchImplementation,
    sleep,
  });

  if (eventName === "issue_comment" && !isTrustedCommentTrigger(event)) {
    await writeSummary(
      environment.GITHUB_STEP_SUMMARY,
      "## Issue classifier\n\nSkipped: the event was a pull-request comment or came from an untrusted commenter.",
    );
    return;
  }

  if (mode === "evaluate") {
    assert(
      eventName === "workflow_dispatch",
      "Evaluation requires workflow_dispatch",
    );
    await validateRepositoryLabels(api, config);
    await runEvaluation({
      api,
      config,
      apiKey: environment.OPENAI_API_KEY,
      openaiApiUrl: environment.OPENAI_RESPONSES_URL,
      fetchImplementation,
      sleep,
      summaryPath: environment.GITHUB_STEP_SUMMARY,
      evaluationPath:
        environment.CLASSIFIER_EVALUATION_PATH ??
        path.join(MODULE_DIRECTORY, "evaluation-cases.json"),
    });
    return;
  }

  const issueNumber = Number.parseInt(
    environment.ISSUE_NUMBER || event.issue?.number,
    10,
  );
  assert(Number.isInteger(issueNumber), "An issue number is required");
  const automatic = eventName === "issues" || eventName === "issue_comment";
  const dryRun = automatic
    ? false
    : parseBoolean(environment.CLASSIFIER_DRY_RUN, true);

  await runClassification({
    api,
    config,
    issueNumber,
    dryRun,
    automatic,
    workflowFile:
      environment.CLASSIFIER_WORKFLOW_FILE || "issue-classifier.yml",
    currentRunId: environment.GITHUB_RUN_ID,
    apiKey: environment.OPENAI_API_KEY,
    openaiApiUrl: environment.OPENAI_RESPONSES_URL,
    fetchImplementation,
    sleep,
    summaryPath: environment.GITHUB_STEP_SUMMARY,
  });
}

const executedPath = process.argv[1]
  ? pathToFileURL(path.resolve(process.argv[1])).href
  : null;
if (executedPath === import.meta.url) {
  main().catch((error) => {
    process.stderr.write(`Issue classifier failed: ${error.message}\n`);
    process.exitCode = 1;
  });
}
