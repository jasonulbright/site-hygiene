# Glossary

This page defines the terms of Site Hygiene.

## What it does

It explains the terms that the tool and this guide use.

## When to use it

Use it when a term is not clear.

## Requirements

None.

## Terms

| Term | Meaning |
|---|---|
| Check | A rule over the scan data. It has an ID, a category and a severity. |
| Finding | One result of a check for one object. |
| Evidence | The text that shows why the check found the object. |
| Fix script | The PowerShell that **Run Fix** runs for a finding. |
| Guidance | Fix text that the tool shows but never runs. |
| Suppression | A key that hides a finding in later scans. |
| Rescan delta | The comparison with the last scan: new and resolved findings. |
| SMS Provider | The server role that gives access to the site data. |
| Live view | A view that reads the current site status on demand and on a timer. |
| Refresh All | The command that runs every live query. |
| Auto-refresh | The timer that repeats the refresh. |
| Alert | A toast and a log line when a metric crosses into breach. |
| Supersedence | An application relationship in which a new application replaces an old one. |
| Dependency | An application relationship in which an application needs another one. |
| DDR | Discovery data record. The Inactive Devices view uses its last contact date. |

## Steps

None.

## Limits

None.

## Troubleshooting

None.

## Links

- [Checks](checks.md)
