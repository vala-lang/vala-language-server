const TRUSTED_ASSOCIATIONS = new Set(["OWNER", "MEMBER", "COLLABORATOR"]);
const AUTOMATION_ACTOR = "github-actions[bot]";
const ONE_DAY_MILLISECONDS = 24 * 60 * 60 * 1000;

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function unique(values) {
  return [...new Set(values)];
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

function confidenceIsHigh(value, config) {
  return value >= config.confidenceThreshold;
}

export function managedLabels(config) {
  return [
    ...Object.keys(config.primaryLabels),
    ...Object.keys(config.supplementalLabels),
    ...Object.keys(config.statusLabels),
  ];
}

export function isTrustedComment(comment, issueAuthorLogin) {
  if (!comment?.user?.login) {
    return false;
  }

  return (
    comment.user.login === issueAuthorLogin ||
    TRUSTED_ASSOCIATIONS.has(comment.author_association)
  );
}

export function selectTrustedComments(comments, issueAuthorLogin, config) {
  const candidates = comments
    .filter((comment) => isTrustedComment(comment, issueAuthorLogin))
    .sort((left, right) => {
      const leftTime = Date.parse(left.updated_at ?? left.created_at ?? 0);
      const rightTime = Date.parse(right.updated_at ?? right.created_at ?? 0);
      return rightTime - leftTime;
    });

  const selected = [];
  let remainingCharacters = config.maxTrustedCommentCharacters;

  for (const comment of candidates) {
    if (
      selected.length >= config.maxTrustedComments ||
      remainingCharacters <= 0
    ) {
      break;
    }

    const maximum = Math.min(
      config.maxSingleCommentCharacters,
      remainingCharacters,
    );
    const body = truncate(comment.body ?? "", maximum);

    selected.push({
      author: comment.user.login,
      association: comment.author_association ?? "NONE",
      created_at: comment.created_at ?? null,
      updated_at: comment.updated_at ?? null,
      body,
    });
    remainingCharacters -= body.length;
  }

  return selected;
}

export function buildIssueInput(issue, comments, config) {
  return {
    issue: {
      number: issue.number,
      title: truncate(issue.title ?? "", 256),
      body: truncate(issue.body ?? "", config.maxIssueBodyCharacters),
    },
    trusted_comments_newest_first: selectTrustedComments(
      comments,
      issue.user?.login,
      config,
    ),
  };
}

function validateConfidence(value, field) {
  assert(
    typeof value === "number" &&
      Number.isFinite(value) &&
      value >= 0 &&
      value <= 1,
    `${field} must be a number between zero and one`,
  );
}

export function validateClassification(value, config) {
  assert(value && typeof value === "object", "Model result must be an object");
  assert(
    Object.keys(value).length === 3 &&
      ["primary", "decisions", "rationale"].every((key) => key in value),
    "Model result has unexpected top-level fields",
  );
  assert(
    value.primary && typeof value.primary === "object",
    "Model result is missing primary",
  );
  assert(
    Object.keys(value.primary).length === 2 &&
      "label" in value.primary &&
      "confidence" in value.primary,
    "primary has unexpected fields",
  );

  const primaryLabels = [...Object.keys(config.primaryLabels), "none"];
  assert(
    primaryLabels.includes(value.primary.label),
    `Unknown primary label: ${value.primary.label}`,
  );
  validateConfidence(value.primary.confidence, "primary.confidence");

  assert(
    value.decisions && typeof value.decisions === "object",
    "Model result is missing decisions",
  );

  const expectedDecisions = [
    ...Object.keys(config.supplementalLabels),
    ...Object.keys(config.statusLabels),
  ];
  const actualDecisions = Object.keys(value.decisions);
  assert(
    actualDecisions.length === expectedDecisions.length &&
      expectedDecisions.every((label) => actualDecisions.includes(label)),
    "Model result decisions do not match the configured labels",
  );

  for (const label of expectedDecisions) {
    const decision = value.decisions[label];
    assert(
      decision && typeof decision === "object",
      `Missing decision for ${label}`,
    );
    assert(
      Object.keys(decision).length === 2 &&
        "applicable" in decision &&
        "confidence" in decision,
      `${label} has unexpected fields`,
    );
    assert(
      typeof decision.applicable === "boolean",
      `${label}.applicable must be boolean`,
    );
    validateConfidence(decision.confidence, `${label}.confidence`);
  }

  assert(typeof value.rationale === "string", "rationale must be a string");
  assert(value.rationale.length <= 500, "rationale exceeds 500 characters");

  return value;
}

function lastLabelEvents(events, configuredLabels) {
  const configured = new Set(configuredLabels);
  const result = new Map();
  const sortedEvents = [...events].sort(
    (left, right) => Date.parse(left.created_at) - Date.parse(right.created_at),
  );

  for (const event of sortedEvents) {
    const label = event.label?.name;
    if (
      !configured.has(label) ||
      (event.event !== "labeled" && event.event !== "unlabeled")
    ) {
      continue;
    }

    result.set(label, event);
  }

  return result;
}

export function resolveLabelOwnership(
  currentLabels,
  events,
  configuredLabels,
  automationActor = AUTOMATION_ACTOR,
) {
  const present = new Set(currentLabels);
  const lastEvents = lastLabelEvents(events, configuredLabels);
  const ownership = {};

  for (const label of configuredLabels) {
    const isPresent = present.has(label);
    const event = lastEvents.get(label);

    if (!event) {
      ownership[label] = {
        present: isPresent,
        state: isPresent ? "human" : "available",
      };
      continue;
    }

    const actor = event.actor?.login;
    const changedByAutomation = actor === automationActor;
    const eventMatchesState =
      (isPresent && event.event === "labeled") ||
      (!isPresent && event.event === "unlabeled");

    if (!eventMatchesState) {
      ownership[label] = {
        present: isPresent,
        state: isPresent ? "human" : "blocked",
      };
    } else if (changedByAutomation) {
      ownership[label] = {
        present: isPresent,
        state: isPresent ? "bot" : "available",
      };
    } else {
      ownership[label] = {
        present: isPresent,
        state: isPresent ? "human" : "blocked",
      };
    }
  }

  return ownership;
}

function createPlanRecorder(ownership) {
  const additions = [];
  const removals = [];
  const preserved = [];
  const abstained = [];

  return {
    additions,
    removals,
    preserved,
    abstained,
    add(label) {
      const labelOwnership = ownership[label];
      if (labelOwnership.present) {
        preserved.push(`${label} (already present)`);
      } else if (labelOwnership.state === "blocked") {
        preserved.push(`${label} (human removal override)`);
      } else {
        additions.push(label);
      }
    },
    remove(label) {
      const labelOwnership = ownership[label];
      if (!labelOwnership.present) {
        return;
      }

      if (labelOwnership.state === "bot") {
        removals.push(label);
      } else {
        preserved.push(`${label} (human-owned)`);
      }
    },
  };
}

export function buildReconciliationPlan(
  currentLabels,
  events,
  classification,
  config,
  automationActor = AUTOMATION_ACTOR,
) {
  validateClassification(classification, config);

  const configuredLabels = managedLabels(config);
  const ownership = resolveLabelOwnership(
    currentLabels,
    events,
    configuredLabels,
    automationActor,
  );
  const plan = createPlanRecorder(ownership);
  const primaryLabels = Object.keys(config.primaryLabels);
  const humanPrimaryLabels = primaryLabels.filter(
    (label) => ownership[label].present && ownership[label].state === "human",
  );

  if (!confidenceIsHigh(classification.primary.confidence, config)) {
    plan.abstained.push("primary (low confidence)");
  } else if (humanPrimaryLabels.length > 0) {
    plan.preserved.push(
      `primary labels (human override: ${humanPrimaryLabels.join(", ")})`,
    );
  } else if (classification.primary.label === "none") {
    for (const label of primaryLabels) {
      plan.remove(label);
    }
  } else {
    const desired = classification.primary.label;
    if (ownership[desired].state === "blocked") {
      plan.preserved.push(`${desired} (human removal override)`);
    } else {
      plan.add(desired);
      for (const label of primaryLabels) {
        if (label !== desired) {
          plan.remove(label);
        }
      }
    }
  }

  const supplementalLabels = Object.keys(config.supplementalLabels);
  const positiveSupplemental = supplementalLabels
    .filter((label) => {
      const decision = classification.decisions[label];
      return (
        decision.applicable && confidenceIsHigh(decision.confidence, config)
      );
    })
    .sort(
      (left, right) =>
        classification.decisions[right].confidence -
          classification.decisions[left].confidence ||
        left.localeCompare(right),
    );
  const selectedSupplemental = new Set(
    positiveSupplemental.slice(0, config.maxSupplementalLabels),
  );

  for (const label of supplementalLabels) {
    const decision = classification.decisions[label];
    if (selectedSupplemental.has(label)) {
      plan.add(label);
    } else if (
      !decision.applicable &&
      confidenceIsHigh(decision.confidence, config)
    ) {
      plan.remove(label);
    } else if (
      decision.applicable &&
      confidenceIsHigh(decision.confidence, config)
    ) {
      plan.abstained.push(`${label} (supplemental-label limit)`);
    } else {
      plan.abstained.push(`${label} (low confidence)`);
    }
  }

  for (const label of Object.keys(config.statusLabels)) {
    const decision = classification.decisions[label];
    if (!confidenceIsHigh(decision.confidence, config)) {
      plan.abstained.push(`${label} (low confidence)`);
    } else if (decision.applicable) {
      plan.add(label);
    } else {
      plan.remove(label);
    }
  }

  return {
    additions: unique(plan.additions),
    removals: unique(plan.removals),
    preserved: unique(plan.preserved),
    abstained: unique(plan.abstained),
    ownership,
  };
}

export function predictedLabels(classification, config) {
  validateClassification(classification, config);
  const labels = [];

  if (
    classification.primary.label !== "none" &&
    confidenceIsHigh(classification.primary.confidence, config)
  ) {
    labels.push(classification.primary.label);
  }

  const supplemental = Object.keys(config.supplementalLabels)
    .filter((label) => {
      const decision = classification.decisions[label];
      return (
        decision.applicable && confidenceIsHigh(decision.confidence, config)
      );
    })
    .sort(
      (left, right) =>
        classification.decisions[right].confidence -
          classification.decisions[left].confidence ||
        left.localeCompare(right),
    )
    .slice(0, config.maxSupplementalLabels);
  labels.push(...supplemental);

  for (const label of Object.keys(config.statusLabels)) {
    const decision = classification.decisions[label];
    if (decision.applicable && confidenceIsHigh(decision.confidence, config)) {
      labels.push(label);
    }
  }

  return unique(labels);
}

export function isTrustedCommentTrigger(event) {
  if (event.issue?.pull_request) {
    return false;
  }

  return isTrustedComment(event.comment, event.issue?.user?.login);
}

export function recentAutomaticRunCount(
  workflowRuns,
  issueNumber,
  currentRunId,
  now = new Date(),
) {
  const cutoff = now.getTime() - ONE_DAY_MILLISECONDS;
  const displayTitle = `Issue classifier #${issueNumber}`;

  return workflowRuns.filter((run) => {
    return (
      String(run.id) !== String(currentRunId) &&
      run.display_title === displayTitle &&
      (run.event === "issues" || run.event === "issue_comment") &&
      run.status === "completed" &&
      run.conclusion === "success" &&
      Date.parse(run.created_at) >= cutoff
    );
  }).length;
}

export function evaluatePredictions(results, config) {
  const primaryLabels = new Set(Object.keys(config.primaryLabels));
  let predictedCount = 0;
  let correctCount = 0;
  let expectedPrimaryCount = 0;
  let correctPrimaryCount = 0;

  for (const result of results) {
    const expected = new Set(result.expectedLabels);
    const predicted = new Set(result.predictedLabels);
    predictedCount += predicted.size;
    correctCount += [...predicted].filter((label) =>
      expected.has(label),
    ).length;

    const expectedPrimary = [...expected].find((label) =>
      primaryLabels.has(label),
    );
    if (expectedPrimary) {
      expectedPrimaryCount += 1;
      if (predicted.has(expectedPrimary)) {
        correctPrimaryCount += 1;
      }
    }
  }

  const precision = predictedCount === 0 ? 0 : correctCount / predictedCount;
  const primaryCoverage =
    expectedPrimaryCount === 0 ? 0 : correctPrimaryCount / expectedPrimaryCount;

  return {
    predictedCount,
    correctCount,
    expectedPrimaryCount,
    correctPrimaryCount,
    precision,
    primaryCoverage,
    passed: precision >= 0.9 && primaryCoverage >= 0.6,
  };
}
