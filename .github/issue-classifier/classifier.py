#!/usr/bin/env python3
"""Deterministic safety boundary for the issue-classification workflow."""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DEFAULT_CONFIG_PATH = HERE / "config.json"
DEFAULT_EVALUATION_PATH = HERE / "evaluation-cases.json"
DEFAULT_PROMPT_PATH = (
    ROOT / ".github" / "workflows" / "shared" / "issue-classification.md"
)
DEFAULT_ISSUE_INPUT_PATH = Path("/tmp/gh-aw/agent/issue-input.json")
AUTOMATION_ACTOR = "github-actions[bot]"
TRUSTED_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}
MAX_AGENT_OUTPUT_BYTES = 1_048_576
MAX_CLASSIFICATION_BYTES = 65_536


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def parse_bool(value: Any, default: bool = False) -> bool:
    if value in (None, ""):
        return default
    return str(value).lower() == "true"


def truncate(value: Any, maximum: int) -> str:
    text = "" if value is None else str(value)
    if len(text) <= maximum:
        return text
    marker = "… [truncated]"
    if maximum <= len(marker):
        return marker[:maximum]
    return f"{text[: maximum - len(marker) - 1]}\n{marker}"


def load_config(path: str | Path | None = None) -> dict[str, Any]:
    config = json.loads(Path(path or DEFAULT_CONFIG_PATH).read_text())
    require(bool(config.get("model")), "Classifier model is required")
    threshold = config.get("confidenceThreshold")
    require(
        isinstance(threshold, (int, float)) and 0 <= threshold <= 1,
        "confidenceThreshold must be between zero and one",
    )
    require(bool(config.get("primaryLabels")), "A primary label is required")
    require(
        isinstance(config.get("maxSupplementalLabels"), int)
        and config["maxSupplementalLabels"] >= 0,
        "maxSupplementalLabels must be a non-negative integer",
    )
    labels = managed_labels(config)
    require(len(labels) == len(set(labels)), "Managed labels must be unique")
    overlap = set(labels) & set(config.get("neverAutomate", []))
    require(not overlap, f"Labels cannot be managed and human-only: {sorted(overlap)}")
    return config


def managed_labels(config: dict[str, Any]) -> list[str]:
    return [
        *config["primaryLabels"],
        *config["supplementalLabels"],
        *config["statusLabels"],
    ]


def is_trusted_comment(comment: dict[str, Any], issue_author: str | None) -> bool:
    login = comment.get("user", {}).get("login")
    return bool(login) and (
        login == issue_author
        or comment.get("author_association") in TRUSTED_ASSOCIATIONS
    )


def select_trusted_comments(
    comments: list[dict[str, Any]], issue_author: str | None, config: dict[str, Any]
) -> list[dict[str, Any]]:
    trusted = [
        comment for comment in comments if is_trusted_comment(comment, issue_author)
    ]
    trusted.sort(
        key=lambda comment: comment.get("updated_at")
        or comment.get("created_at")
        or "",
        reverse=True,
    )
    selected: list[dict[str, Any]] = []
    remaining = config["maxTrustedCommentCharacters"]
    for comment in trusted:
        if len(selected) >= config["maxTrustedComments"] or remaining <= 0:
            break
        maximum = min(config["maxSingleCommentCharacters"], remaining)
        body = truncate(comment.get("body"), maximum)
        selected.append(
            {
                "author": comment["user"]["login"],
                "association": comment.get("author_association", "NONE"),
                "created_at": comment.get("created_at"),
                "updated_at": comment.get("updated_at"),
                "body": body,
            }
        )
        remaining -= len(body)
    return selected


def build_issue_input(
    issue: dict[str, Any], comments: list[dict[str, Any]], config: dict[str, Any]
) -> dict[str, Any]:
    return {
        "issue": {
            "number": issue["number"],
            "title": truncate(issue.get("title"), 256),
            "body": truncate(issue.get("body"), config["maxIssueBodyCharacters"]),
        },
        "trusted_comments_newest_first": select_trusted_comments(
            comments, issue.get("user", {}).get("login"), config
        ),
    }


def _validate_confidence(value: Any, field: str) -> None:
    require(
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and 0 <= value <= 1,
        f"{field} must be a number between zero and one",
    )


def validate_classification(value: Any, config: dict[str, Any]) -> dict[str, Any]:
    require(isinstance(value, dict), "Model result must be an object")
    require(
        set(value) == {"primary", "decisions", "rationale"},
        "Model result has unexpected top-level fields",
    )
    primary = value["primary"]
    require(
        isinstance(primary, dict) and set(primary) == {"label", "confidence"},
        "primary has unexpected fields",
    )
    require(
        primary["label"] in [*config["primaryLabels"], "none"],
        f"Unknown primary label: {primary['label']}",
    )
    _validate_confidence(primary["confidence"], "primary.confidence")

    decisions = value["decisions"]
    expected = {*config["supplementalLabels"], *config["statusLabels"]}
    require(
        isinstance(decisions, dict) and set(decisions) == expected,
        "Model result decisions do not match the configured labels",
    )
    for label in expected:
        decision = decisions[label]
        require(
            isinstance(decision, dict)
            and set(decision) == {"applicable", "confidence"},
            f"{label} has unexpected fields",
        )
        require(
            isinstance(decision["applicable"], bool),
            f"{label}.applicable must be boolean",
        )
        _validate_confidence(decision["confidence"], f"{label}.confidence")
    require(isinstance(value["rationale"], str), "rationale must be a string")
    require(len(value["rationale"]) <= 500, "rationale exceeds 500 characters")
    return value


def resolve_label_ownership(
    current_labels: list[str],
    events: list[dict[str, Any]],
    configured_labels: list[str],
    automation_actor: str = AUTOMATION_ACTOR,
) -> dict[str, dict[str, Any]]:
    configured = set(configured_labels)
    latest: dict[str, dict[str, Any]] = {}
    for event in sorted(events, key=lambda item: item.get("created_at", "")):
        label = event.get("label", {}).get("name")
        if label in configured and event.get("event") in {"labeled", "unlabeled"}:
            latest[label] = event

    present = set(current_labels)
    ownership: dict[str, dict[str, Any]] = {}
    for label in configured_labels:
        is_present = label in present
        event = latest.get(label)
        if not event:
            state = "human" if is_present else "available"
        else:
            matches = (is_present and event["event"] == "labeled") or (
                not is_present and event["event"] == "unlabeled"
            )
            actor = event.get("actor", {}).get("login")
            if not matches:
                state = "human" if is_present else "blocked"
            elif actor == automation_actor:
                state = "bot" if is_present else "available"
            else:
                state = "human" if is_present else "blocked"
        ownership[label] = {"present": is_present, "state": state}
    return ownership


def build_reconciliation_plan(
    current_labels: list[str],
    events: list[dict[str, Any]],
    classification: dict[str, Any],
    config: dict[str, Any],
    automation_actor: str = AUTOMATION_ACTOR,
) -> dict[str, Any]:
    validate_classification(classification, config)
    labels = managed_labels(config)
    ownership = resolve_label_ownership(
        current_labels, events, labels, automation_actor
    )
    additions: list[str] = []
    removals: list[str] = []
    preserved: list[str] = []
    abstained: list[str] = []

    def add(label: str) -> None:
        state = ownership[label]
        if state["present"]:
            preserved.append(f"{label} (already present)")
        elif state["state"] == "blocked":
            preserved.append(f"{label} (human removal override)")
        else:
            additions.append(label)

    def remove(label: str) -> None:
        state = ownership[label]
        if not state["present"]:
            return
        if state["state"] == "bot":
            removals.append(label)
        else:
            preserved.append(f"{label} (human-owned)")

    threshold = config["confidenceThreshold"]
    primary_labels = list(config["primaryLabels"])
    human_primary = [
        label
        for label in primary_labels
        if ownership[label]["present"] and ownership[label]["state"] == "human"
    ]
    primary = classification["primary"]
    if primary["confidence"] < threshold:
        abstained.append("primary (low confidence)")
    elif human_primary:
        preserved.append(f"primary labels (human override: {', '.join(human_primary)})")
    elif primary["label"] == "none":
        for label in primary_labels:
            remove(label)
    elif ownership[primary["label"]]["state"] == "blocked":
        preserved.append(f"{primary['label']} (human removal override)")
    else:
        add(primary["label"])
        for label in primary_labels:
            if label != primary["label"]:
                remove(label)

    supplemental = list(config["supplementalLabels"])
    positives = sorted(
        (
            label
            for label in supplemental
            if classification["decisions"][label]["applicable"]
            and classification["decisions"][label]["confidence"] >= threshold
        ),
        key=lambda label: (-classification["decisions"][label]["confidence"], label),
    )
    selected = set(positives[: config["maxSupplementalLabels"]])
    for label in supplemental:
        decision = classification["decisions"][label]
        if label in selected:
            add(label)
        elif decision["confidence"] < threshold:
            abstained.append(f"{label} (low confidence)")
        else:
            remove(label)
            if decision["applicable"]:
                abstained.append(f"{label} (supplemental-label limit)")

    for label in config["statusLabels"]:
        decision = classification["decisions"][label]
        if decision["confidence"] < threshold:
            abstained.append(f"{label} (low confidence)")
        elif decision["applicable"]:
            add(label)
        else:
            remove(label)

    unique = lambda values: list(dict.fromkeys(values))
    return {
        "additions": unique(additions),
        "removals": unique(removals),
        "preserved": unique(preserved),
        "abstained": unique(abstained),
        "ownership": ownership,
    }


def predicted_labels(
    classification: dict[str, Any], config: dict[str, Any]
) -> list[str]:
    validate_classification(classification, config)
    threshold = config["confidenceThreshold"]
    result: list[str] = []
    primary = classification["primary"]
    if primary["label"] != "none" and primary["confidence"] >= threshold:
        result.append(primary["label"])
    positives = sorted(
        (
            label
            for label in config["supplementalLabels"]
            if classification["decisions"][label]["applicable"]
            and classification["decisions"][label]["confidence"] >= threshold
        ),
        key=lambda label: (-classification["decisions"][label]["confidence"], label),
    )
    result.extend(positives[: config["maxSupplementalLabels"]])
    result.extend(
        label
        for label in config["statusLabels"]
        if classification["decisions"][label]["applicable"]
        and classification["decisions"][label]["confidence"] >= threshold
    )
    return list(dict.fromkeys(result))


def is_trusted_comment_trigger(event: dict[str, Any]) -> bool:
    if "pull_request" in event.get("issue", {}):
        return False
    issue_author = event.get("issue", {}).get("user", {}).get("login")
    return is_trusted_comment(event.get("comment", {}), issue_author)


def recent_automatic_run_count(
    runs: list[dict[str, Any]],
    issue_number: int,
    current_run_id: str | int | None,
    now: datetime | None = None,
) -> int:
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(days=1)
    display_title = f"Issue classifier #{issue_number}"

    def qualifies(run: dict[str, Any]) -> bool:
        try:
            created = datetime.fromisoformat(run["created_at"].replace("Z", "+00:00"))
        except (KeyError, ValueError):
            return False
        return (
            str(run.get("id")) != str(current_run_id)
            and run.get("display_title") == display_title
            and run.get("event") in {"issues", "issue_comment"}
            and run.get("status") == "completed"
            and run.get("conclusion") == "success"
            and created >= cutoff
        )

    return sum(qualifies(run) for run in runs)


def evaluate_predictions(
    results: list[dict[str, Any]], config: dict[str, Any]
) -> dict[str, Any]:
    primary_labels = set(config["primaryLabels"])
    predicted_count = correct_count = expected_primary_count = correct_primary_count = 0
    for result in results:
        expected = set(result["expectedLabels"])
        predicted = set(result["predictedLabels"])
        predicted_count += len(predicted)
        correct_count += len(expected & predicted)
        expected_primary = next(
            (label for label in expected if label in primary_labels), None
        )
        if expected_primary:
            expected_primary_count += 1
            correct_primary_count += expected_primary in predicted
    precision = correct_count / predicted_count if predicted_count else 0
    coverage = (
        correct_primary_count / expected_primary_count if expected_primary_count else 0
    )
    return {
        "predictedCount": predicted_count,
        "correctCount": correct_count,
        "expectedPrimaryCount": expected_primary_count,
        "correctPrimaryCount": correct_primary_count,
        "precision": precision,
        "primaryCoverage": coverage,
        "passed": precision >= 0.9 and coverage >= 0.6,
    }


class GitHubApi:
    def __init__(
        self,
        token: str,
        repository: str,
        api_url: str = "https://api.github.com",
        sleep=time.sleep,
    ) -> None:
        require(bool(token), "GITHUB_TOKEN is required")
        require("/" in repository, "GITHUB_REPOSITORY must be owner/name")
        self.token = token
        self.repository = repository
        self.api_url = api_url.rstrip("/")
        self.sleep = sleep

    def request(
        self,
        path: str,
        method: str = "GET",
        body: Any = None,
        allow_not_found: bool = False,
    ) -> Any:
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            f"{self.api_url}{path}",
            data=data,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2026-03-10",
            },
        )
        delays = [1, 2, 4, 8, 16]
        for attempt in range(len(delays) + 1):
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    payload = response.read()
                    return json.loads(payload) if payload else None
            except urllib.error.HTTPError as error:
                if allow_not_found and error.code == 404:
                    return None
                retryable = error.code in {408, 429} or error.code >= 500
                if retryable and attempt < len(delays):
                    retry_after = error.headers.get("Retry-After")
                    delay = (
                        min(int(retry_after), 60) if retry_after else delays[attempt]
                    )
                    self.sleep(delay)
                    continue
                detail = truncate(error.read().decode(errors="replace"), 1000)
                error.close()
                raise RuntimeError(
                    f"GitHub API {method} {path} failed ({error.code}): {detail}"
                ) from error

    def repo_path(self, suffix: str) -> str:
        return f"/repos/{self.repository}{suffix}"

    def paginate(self, path: str, maximum_pages: int = 20) -> list[Any]:
        values: list[Any] = []
        separator = "&" if "?" in path else "?"
        for page in range(1, maximum_pages + 1):
            result = self.request(f"{path}{separator}per_page=100&page={page}")
            require(isinstance(result, list), f"Expected an array from {path}")
            values.extend(result)
            if len(result) < 100:
                break
        return values

    def get_issue(self, issue_number: int) -> dict[str, Any]:
        return self.request(self.repo_path(f"/issues/{issue_number}"))

    def get_comments(self, issue_number: int) -> list[dict[str, Any]]:
        return self.paginate(self.repo_path(f"/issues/{issue_number}/comments"))

    def get_issue_events(self, issue_number: int) -> list[dict[str, Any]]:
        return self.paginate(self.repo_path(f"/issues/{issue_number}/events"))

    def get_repository_labels(self) -> list[dict[str, Any]]:
        return self.paginate(self.repo_path("/labels"))

    def get_workflow_runs(self, workflow_file: str) -> dict[str, Any]:
        encoded = urllib.parse.quote(workflow_file, safe="")
        return self.request(
            self.repo_path(f"/actions/workflows/{encoded}/runs?per_page=100")
        )

    def add_labels(self, issue_number: int, labels: list[str]) -> None:
        if labels:
            self.request(
                self.repo_path(f"/issues/{issue_number}/labels"),
                method="POST",
                body={"labels": labels},
            )

    def remove_label(self, issue_number: int, label: str) -> None:
        encoded = urllib.parse.quote(label, safe="")
        self.request(
            self.repo_path(f"/issues/{issue_number}/labels/{encoded}"),
            method="DELETE",
            allow_not_found=True,
        )


def validate_repository_labels(api: GitHubApi, config: dict[str, Any]) -> None:
    available = {label["name"] for label in api.get_repository_labels()}
    missing = [label for label in managed_labels(config) if label not in available]
    require(
        not missing, f"Configured repository labels do not exist: {', '.join(missing)}"
    )


def apply_reconciliation_plan(
    api: GitHubApi, issue_number: int, plan: dict[str, Any], dry_run: bool
) -> None:
    if dry_run:
        return
    api.add_labels(issue_number, plan["additions"])
    for label in plan["removals"]:
        api.remove_label(issue_number, label)


def response_schema(config: dict[str, Any]) -> dict[str, Any]:
    decision_labels = [*config["supplementalLabels"], *config["statusLabels"]]
    decisions = {
        label: {
            "type": "object",
            "additionalProperties": False,
            "required": ["applicable", "confidence"],
            "properties": {
                "applicable": {"type": "boolean"},
                "confidence": {"type": "number", "minimum": 0, "maximum": 1},
            },
        }
        for label in decision_labels
    }
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["primary", "decisions", "rationale"],
        "properties": {
            "primary": {
                "type": "object",
                "additionalProperties": False,
                "required": ["label", "confidence"],
                "properties": {
                    "label": {
                        "type": "string",
                        "enum": [*config["primaryLabels"], "none"],
                    },
                    "confidence": {"type": "number", "minimum": 0, "maximum": 1},
                },
            },
            "decisions": {
                "type": "object",
                "additionalProperties": False,
                "required": decision_labels,
                "properties": decisions,
            },
            "rationale": {"type": "string", "maxLength": 500},
        },
    }


def _prompt_body(path: str | Path = DEFAULT_PROMPT_PATH) -> str:
    text = Path(path).read_text()
    if text.startswith("---\n"):
        _, _, text = text.partition("\n---\n")
    return text.strip()


def openai_request(
    issue_input: dict[str, Any], config: dict[str, Any]
) -> dict[str, Any]:
    return {
        "model": config["model"],
        "reasoning": {"effort": config["reasoningEffort"]},
        "instructions": _prompt_body(),
        "input": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": f"UNTRUSTED_ISSUE_INPUT_JSON\n{json.dumps(issue_input)}",
                    }
                ],
            }
        ],
        "max_output_tokens": config["maxOutputTokens"],
        "store": False,
        "text": {
            "format": {
                "type": "json_schema",
                "name": "issue_classification",
                "strict": True,
                "schema": response_schema(config),
            }
        },
        "tools": [],
    }


def parse_openai_response(response: Any, config: dict[str, Any]) -> dict[str, Any]:
    require(isinstance(response, dict), "OpenAI response is missing")
    error = response.get("error")
    incomplete_details = response.get("incomplete_details")
    failure = (
        (error.get("message") if isinstance(error, dict) else None)
        or (
            incomplete_details.get("reason")
            if isinstance(incomplete_details, dict)
            else None
        )
        or response.get("status")
        or "unknown status"
    )
    require(
        response.get("status") == "completed",
        f"OpenAI response did not complete: {failure}",
    )
    texts: list[str] = []
    refusals: list[str] = []
    for item in response.get("output", []):
        if item.get("type") != "message":
            continue
        for content in item.get("content", []):
            if content.get("type") == "output_text" and isinstance(
                content.get("text"), str
            ):
                texts.append(content["text"])
            elif content.get("type") == "refusal" and isinstance(
                content.get("refusal"), str
            ):
                refusals.append(content["refusal"])
    require(
        not refusals,
        f"OpenAI refused classification: {refusals[0] if refusals else ''}",
    )
    require(len(texts) == 1, "OpenAI response must contain one text output")
    require(
        len(texts[0].encode()) <= MAX_CLASSIFICATION_BYTES,
        "OpenAI response exceeds 64 KiB",
    )
    try:
        return validate_classification(json.loads(texts[0]), config)
    except json.JSONDecodeError as error:
        raise ValueError(f"OpenAI response was not valid JSON: {error}") from error


def request_classification(
    issue_input: dict[str, Any], config: dict[str, Any], api_key: str
) -> dict[str, Any]:
    require(bool(api_key), "OPENAI_API_KEY is required")
    request = urllib.request.Request(
        os.getenv("OPENAI_RESPONSES_URL", "https://api.openai.com/v1/responses"),
        data=json.dumps(openai_request(issue_input, config)).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
    )
    delays = [1, 2, 4, 8, 16]
    for attempt in range(len(delays) + 1):
        try:
            with urllib.request.urlopen(
                request, timeout=config["openaiTimeoutMilliseconds"] / 1000
            ) as response:
                return parse_openai_response(json.load(response), config)
        except urllib.error.HTTPError as error:
            if (error.code in {408, 429} or error.code >= 500) and attempt < len(
                delays
            ):
                retry_after = error.headers.get("Retry-After")
                time.sleep(
                    min(int(retry_after), 60) if retry_after else delays[attempt]
                )
                continue
            detail = truncate(error.read().decode(errors="replace"), 1000)
            error.close()
            raise RuntimeError(
                f"OpenAI Responses request failed ({error.code}): {detail}"
            ) from error


def _load_event(environment: dict[str, str]) -> dict[str, Any]:
    path = environment.get("GITHUB_EVENT_PATH")
    return json.loads(Path(path).read_text()) if path else {}


def _issue_number(environment: dict[str, str], event: dict[str, Any]) -> int:
    raw = environment.get("ISSUE_NUMBER") or event.get("issue", {}).get("number")
    try:
        number = int(raw)
    except (TypeError, ValueError) as error:
        raise ValueError("An issue number is required") from error
    require(number > 0, "Issue number must be positive")
    return number


def _api(environment: dict[str, str]) -> GitHubApi:
    return GitHubApi(
        environment.get("GITHUB_TOKEN", ""),
        environment.get("GITHUB_REPOSITORY", ""),
        environment.get("GITHUB_API_URL", "https://api.github.com"),
    )


def write_summary(environment: dict[str, str], content: str) -> None:
    summary = environment.get("GITHUB_STEP_SUMMARY")
    if summary:
        with Path(summary).open("a") as output:
            output.write(f"{content.strip()}\n")
    print(content.strip())


def write_noop(environment: dict[str, str], message: str) -> None:
    output = environment.get("GH_AW_SAFE_OUTPUTS")
    require(bool(output), "GH_AW_SAFE_OUTPUTS is required to skip the agent")
    target = Path(output)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("a") as stream:
        stream.write(json.dumps({"type": "noop", "message": message}) + "\n")


def prepare(environment: dict[str, str] | None = None, sleep=time.sleep) -> None:
    environment = environment or dict(os.environ)
    config = load_config(environment.get("CLASSIFIER_CONFIG_PATH"))
    event = _load_event(environment)
    event_name = environment.get("GITHUB_EVENT_NAME", "workflow_dispatch")
    issue_number = _issue_number(environment, event)
    api = _api(environment)

    if event_name == "issue_comment" and not is_trusted_comment_trigger(event):
        message = (
            "The comment is on a pull request or is not from a trusted participant."
        )
        write_noop(environment, message)
        write_summary(
            environment, f"## Issue classifier: #{issue_number}\n\nSkipped: {message}"
        )
        return

    automatic = event_name in {"issues", "issue_comment"}
    if automatic:
        workflow_file = environment.get(
            "CLASSIFIER_WORKFLOW_FILE", "issue-classifier.lock.yml"
        )
        runs = api.get_workflow_runs(workflow_file).get("workflow_runs", [])
        count = recent_automatic_run_count(
            runs, issue_number, environment.get("GITHUB_RUN_ID")
        )
        if count >= config["automaticRunsPerIssuePerDay"]:
            message = (
                f"Issue #{issue_number} reached the limit of "
                f"{config['automaticRunsPerIssuePerDay']} automatic classifications in 24 hours."
            )
            write_noop(environment, message)
            write_summary(
                environment,
                f"## Issue classifier: #{issue_number}\n\nSkipped: {message}",
            )
            return
        sleep(config["debounceMilliseconds"] / 1000)

    validate_repository_labels(api, config)
    issue = api.get_issue(issue_number)
    require(
        "pull_request" not in issue, f"#{issue_number} is a pull request, not an issue"
    )
    issue_input = build_issue_input(issue, api.get_comments(issue_number), config)
    target = Path(
        environment.get("CLASSIFIER_ISSUE_INPUT_PATH", DEFAULT_ISSUE_INPUT_PATH)
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(issue_input, separators=(",", ":")))
    write_summary(
        environment,
        f"## Issue classifier: #{issue_number}\n\nPrepared {len(issue_input['trusted_comments_newest_first'])} trusted comments for classification.",
    )


def parse_agent_classification(
    path: str | Path, config: dict[str, Any]
) -> dict[str, Any]:
    raw = Path(path).read_bytes()
    require(len(raw) <= MAX_AGENT_OUTPUT_BYTES, "Agent output exceeds 1 MiB")
    try:
        output = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ValueError(f"Agent output was not valid JSON: {error}") from error
    require(
        isinstance(output, dict) and isinstance(output.get("items"), list),
        "Agent output is missing items",
    )
    items = [
        item for item in output["items"] if item.get("type") == "reconcile_issue_labels"
    ]
    require(len(items) == 1, "Agent must call reconcile_issue_labels exactly once")
    encoded = items[0].get("classification_json")
    require(isinstance(encoded, str), "classification_json must be a string")
    require(
        len(encoded.encode()) <= MAX_CLASSIFICATION_BYTES,
        "classification_json exceeds 64 KiB",
    )
    try:
        classification = json.loads(encoded)
    except json.JSONDecodeError as error:
        raise ValueError(f"classification_json was not valid JSON: {error}") from error
    return validate_classification(classification, config)


def _classification_summary(
    issue_number: int,
    classification: dict[str, Any],
    plan: dict[str, Any],
    dry_run: bool,
) -> str:
    decisions = sorted(classification["decisions"].items())
    lines = [
        f"## Issue classifier: #{issue_number}",
        "",
        f"- Mode: {'dry run' if dry_run else 'apply'}",
        f"- Primary: {classification['primary']['label']} ({classification['primary']['confidence']:.2f})",
        f"- Add: {', '.join(plan['additions']) or 'none'}",
        f"- Remove: {', '.join(plan['removals']) or 'none'}",
        f"- Preserved: {'; '.join(plan['preserved']) or 'none'}",
        f"- Abstained: {'; '.join(plan['abstained']) or 'none'}",
        "",
        "| Label | Applicable | Confidence |",
        "| --- | --- | ---: |",
    ]
    lines.extend(
        f"| {label.replace('|', chr(92) + '|')} | {'yes' if value['applicable'] else 'no'} | {value['confidence']:.2f} |"
        for label, value in decisions
    )
    return "\n".join(lines)


def reconcile(environment: dict[str, str] | None = None) -> None:
    environment = environment or dict(os.environ)
    config = load_config(environment.get("CLASSIFIER_CONFIG_PATH"))
    event = _load_event(environment)
    issue_number = _issue_number(environment, event)
    output_path = environment.get("GH_AW_AGENT_OUTPUT")
    require(bool(output_path), "GH_AW_AGENT_OUTPUT is required")
    classification = parse_agent_classification(output_path, config)
    api = _api(environment)
    validate_repository_labels(api, config)
    issue = api.get_issue(issue_number)
    require(
        "pull_request" not in issue, f"#{issue_number} is a pull request, not an issue"
    )
    current = [
        label if isinstance(label, str) else label.get("name")
        for label in issue.get("labels", [])
    ]
    current = [label for label in current if label]
    plan = build_reconciliation_plan(
        current, api.get_issue_events(issue_number), classification, config
    )
    dry_run = parse_bool(environment.get("CLASSIFIER_DRY_RUN")) or parse_bool(
        environment.get("GH_AW_SAFE_OUTPUTS_STAGED")
    )
    apply_reconciliation_plan(api, issue_number, plan, dry_run)
    write_summary(
        environment,
        _classification_summary(issue_number, classification, plan, dry_run),
    )


def evaluate(environment: dict[str, str] | None = None) -> None:
    environment = environment or dict(os.environ)
    config = load_config(environment.get("CLASSIFIER_CONFIG_PATH"))
    api = _api(environment)
    validate_repository_labels(api, config)
    fixture = json.loads(
        Path(
            environment.get("CLASSIFIER_EVALUATION_PATH", DEFAULT_EVALUATION_PATH)
        ).read_text()
    )
    cases = fixture.get("cases")
    require(
        isinstance(cases, list) and len(cases) == 40,
        "The evaluation set must contain exactly 40 cases",
    )
    results: list[dict[str, Any]] = []
    for case in cases:
        issue_number = case["issueNumber"]
        print(f"Evaluating issue #{issue_number}", flush=True)
        issue = api.get_issue(issue_number)
        issue_input = build_issue_input(issue, api.get_comments(issue_number), config)
        classification = request_classification(
            issue_input, config, environment.get("OPENAI_API_KEY", "")
        )
        results.append(
            {
                "issueNumber": issue_number,
                "expectedLabels": case["expectedLabels"],
                "predictedLabels": predicted_labels(classification, config),
            }
        )
    metrics = evaluate_predictions(results, config)
    rows = [
        f"| #{result['issueNumber']} | {', '.join(result['expectedLabels']) or 'none'} | {', '.join(result['predictedLabels']) or 'none'} |"
        for result in results
    ]
    summary = "\n".join(
        [
            "## Issue classifier evaluation",
            "",
            f"- Precision: {metrics['precision']:.1%}",
            f"- Primary-label coverage: {metrics['primaryCoverage']:.1%}",
            f"- Result: {'pass' if metrics['passed'] else 'fail'}",
            "",
            "| Issue | Expected | Predicted |",
            "| --- | --- | --- |",
            *rows,
        ]
    )
    write_summary(environment, summary)
    require(
        metrics["passed"],
        "Evaluation failed the 90% precision or 60% primary-label coverage gate",
    )


def main() -> None:
    commands = {"prepare": prepare, "reconcile": reconcile, "evaluate": evaluate}
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    require(
        command in commands,
        f"Usage: {Path(sys.argv[0]).name} prepare|reconcile|evaluate",
    )
    commands[command]()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 - concise workflow error boundary
        print(f"Issue classifier failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
