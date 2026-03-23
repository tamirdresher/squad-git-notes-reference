# Squad Routing Rules
# Source of truth for which agent handles which issues/labels/keywords.
# To update: write directly to squad/state branch (universal truth, not feature-scoped).
# Last updated: 2026-03-23

## Issue Label Routing

| Label | Agent | Notes |
|-------|-------|-------|
| `bug` | Ralph | Auto-triage, then route to Data |
| `feature` | Data | Implementation |
| `security` | Worf | Always needs Worf review |
| `security-*` | Worf | Any security-prefixed label |
| `docs` | Seven | Documentation specialist |
| `docs-*` | Seven | Any docs-prefixed label |
| `arch` | Picard | Architecture decisions requiring human |
| `blocked` | Ralph | Re-queue after unblocking |
| `unknown` | Q | Review first, then route |

## Keyword Routing

| Keyword in title/body | Agent |
|-----------------------|-------|
| auth, authentication, JWT, token, secret | Worf + Data |
| vulnerability, CVE, exploit | Worf (escalate to human) |
| documentation, README, API spec | Seven |
| performance, slow, latency, memory | Data |
| test, testing, coverage | Data |

## PR Review Routing

| PR Type | Reviewer |
|---------|---------|
| Any code change | Data |
| Any auth/security change | Worf (required) |
| API contract change | Seven |
| Architecture change | Picard (required, human) |

## Escalation Path

Ralph → Q → Picard → Tamir (human)
