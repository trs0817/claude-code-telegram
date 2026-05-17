## Summary

What does this PR do? One or two sentences.

## Related issue

Closes #<issue-number> (if applicable).

## Changes

- Bullet list of concrete changes
- Keep this honest — reviewers will diff anyway

## Testing

How did you verify this works? Include:
- Commands run locally (`pytest`, `ruff`, `py_compile`)
- Manual test of the relevant code path on a real server (if applicable)

## Checklist

- [ ] `python3 -m py_compile src/claude_telegram_bot.py` passes
- [ ] `ruff check src/ tests/` passes
- [ ] `pytest tests/` passes (and new tests added if behavior changed)
- [ ] README updated if user-facing behavior changed
- [ ] CHANGELOG.md updated under `## [Unreleased]`
- [ ] No secrets, tokens, or chat IDs introduced anywhere in the diff
