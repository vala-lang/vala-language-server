function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function truncate(value, maximum) {
  const text = value ?? "";
  return text.length <= maximum ? text : `${text.slice(0, maximum)}…`;
}

export async function retryingFetch(url, options, fetchImplementation, sleep) {
  const delays = [1000, 2000, 4000, 8000, 16000];

  for (let attempt = 0; ; attempt += 1) {
    const response = await fetchImplementation(url, options);
    if (
      response.status !== 429 &&
      response.status !== 408 &&
      response.status < 500
    ) {
      return response;
    }

    if (attempt >= delays.length) {
      return response;
    }

    const retryAfter = Number.parseInt(response.headers.get("retry-after"), 10);
    const delay = Number.isFinite(retryAfter)
      ? Math.min(retryAfter * 1000, 60000)
      : delays[attempt];
    await sleep(delay);
  }
}

export class GitHubApi {
  constructor({
    token,
    repository,
    apiUrl = "https://api.github.com",
    fetchImplementation = globalThis.fetch,
    sleep = (milliseconds) =>
      new Promise((resolve) => setTimeout(resolve, milliseconds)),
  }) {
    assert(token, "GITHUB_TOKEN is required");
    assert(repository?.includes("/"), "GITHUB_REPOSITORY must be owner/name");
    this.token = token;
    this.repository = repository;
    this.apiUrl = apiUrl.replace(/\/$/, "");
    this.fetchImplementation = fetchImplementation;
    this.sleep = sleep;
  }

  async request(apiPath, { method = "GET", body, allowNotFound = false } = {}) {
    const response = await retryingFetch(
      `${this.apiUrl}${apiPath}`,
      {
        method,
        headers: {
          Accept: "application/vnd.github+json",
          Authorization: `Bearer ${this.token}`,
          "Content-Type": "application/json",
          "X-GitHub-Api-Version": "2026-03-10",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
      },
      this.fetchImplementation,
      this.sleep,
    );

    if (allowNotFound && response.status === 404) {
      return null;
    }

    if (!response.ok) {
      const responseText = truncate(await response.text(), 1000);
      throw new Error(
        `GitHub API ${method} ${apiPath} failed (${response.status}): ${responseText}`,
      );
    }

    if (response.status === 204) {
      return null;
    }

    return response.json();
  }

  async paginate(apiPath, maximumPages = 20) {
    const separator = apiPath.includes("?") ? "&" : "?";
    const values = [];

    for (let page = 1; page <= maximumPages; page += 1) {
      const result = await this.request(
        `${apiPath}${separator}per_page=100&page=${page}`,
      );
      assert(Array.isArray(result), `Expected an array from ${apiPath}`);
      values.push(...result);
      if (result.length < 100) {
        break;
      }
    }

    return values;
  }

  repositoryPath(suffix) {
    return `/repos/${this.repository}${suffix}`;
  }

  getIssue(issueNumber) {
    return this.request(this.repositoryPath(`/issues/${issueNumber}`));
  }

  getComments(issueNumber) {
    return this.paginate(
      this.repositoryPath(`/issues/${issueNumber}/comments`),
    );
  }

  getIssueEvents(issueNumber) {
    return this.paginate(this.repositoryPath(`/issues/${issueNumber}/events`));
  }

  getRepositoryLabels() {
    return this.paginate(this.repositoryPath("/labels"));
  }

  getWorkflowRuns(workflowFile) {
    return this.request(
      this.repositoryPath(
        `/actions/workflows/${encodeURIComponent(workflowFile)}/runs?per_page=100`,
      ),
    );
  }

  addLabels(issueNumber, labels) {
    if (labels.length === 0) {
      return Promise.resolve(null);
    }

    return this.request(this.repositoryPath(`/issues/${issueNumber}/labels`), {
      method: "POST",
      body: { labels },
    });
  }

  removeLabel(issueNumber, label) {
    return this.request(
      this.repositoryPath(
        `/issues/${issueNumber}/labels/${encodeURIComponent(label)}`,
      ),
      { method: "DELETE", allowNotFound: true },
    );
  }
}
