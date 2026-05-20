# AI Prompts for pg_durable Development

This directory contains structured prompts for LLMs working on the pg_durable codebase. Each prompt provides comprehensive guidance for common development tasks.

## Available Prompts

### Quality and Maintenance

1. **[pg_durable-clean-warnings.md](pg_durable-clean-warnings.md)**
   - Eliminating compiler warnings in pgrx extension code
   - Running clippy for Rust code
   - Proper handling of unused code
   - Code formatting

2. **[pg_durable-update-docs-tests.md](pg_durable-update-docs-tests.md)**
   - Comprehensive documentation review
   - Proposing E2E tests for code changes
   - Keeping USER_GUIDE.md accurate
   - SQL example validation

### Testing

3. **[pg_durable-create-scenario-test.md](pg_durable-create-scenario-test.md)**
   - Creating SQL-based E2E scenario tests
   - Modeling real-world durable function patterns
   - Testing complex control flow (loops, conditionals, joins, race)

### Git Operations

4. **[pg_durable-merge-main.md](pg_durable-merge-main.md)**
   - Committing changes with proper messages
   - Merging branches to main
   - Pre-commit checklist
   - Deploying to ACR after merge

### Release

5. **[pg_durable-release.md](pg_durable-release.md)**
   - Check for duroxide/duroxide-pg dependency updates
   - Build, clippy, and clean warnings
   - Update documentation and tests
   - Run unit and E2E tests
   - Optional Docker build and ACR deployment

## How to Use These Prompts

### For LLM Assistants
Reference the appropriate prompt when tackling a task:

```
@pg_durable-create-scenario-test.md

Create a scenario test for this durable function pattern: [pattern description]
```

### For Humans
Use these as checklists and guidelines when:
- Onboarding new contributors
- Planning complex changes
- Reviewing pull requests
- Establishing coding standards

## Prompt Design Principles

These prompts follow consistent patterns:

1. **Clear Objective** - What are we trying to accomplish?
2. **Structured Steps** - Ordered tasks to complete the objective
3. **Examples** - Show correct patterns vs anti-patterns
4. **Checklists** - Ensure nothing is missed
5. **Quality Gates** - Validation steps before considering done

## Integration with Development Workflow

### Adding New Features
```
1. Implement feature in src/
2. @pg_durable-clean-warnings.md         - Clean up warnings
3. @pg_durable-create-scenario-test.md   - Add E2E test
4. @pg_durable-update-docs-tests.md      - Update documentation
5. Run full test suite
6. @pg_durable-merge-main.md             - Commit and push
```

### Documentation & Test Update Cycle
```
1. @pg_durable-update-docs-tests.md  - Review docs, propose tests
2. @pg_durable-clean-warnings.md     - Clean up any code issues found
3. @pg_durable-merge-main.md         - Commit and push
```

### Release Workflow
```
1. @pg_durable-release.md            - Full release checklist:
   - Check dependency updates (duroxide, duroxide-pg)
   - Build, clippy, clean warnings
   - Update docs and tests
   - Run unit + E2E tests
   - Optional: Docker build & test
   - Optional: Push to ACR
```

## Key Directories

- `src/` - Rust pgrx extension code
- `tests/e2e/sql/` - SQL-based E2E tests
- `docs/` - Documentation files
- `USER_GUIDE.md` - Main user documentation
- `scripts/` - Test and deployment scripts

## Testing Commands

```bash
# Run pgrx unit tests
./scripts/test-unit.sh

# Run E2E tests locally
./scripts/test-e2e-local.sh

# Run E2E tests in Docker (linux/amd64)
./scripts/test-e2e-docker.sh

# Run specific test
./scripts/test-e2e-local.sh 04_parallel

# Keep server running after tests for debugging
./scripts/test-e2e-local.sh --keep
```

## Quality Standards for Prompts

All prompts should:
- Be actionable (clear steps, not vague suggestions)
- Include examples (both good and bad patterns)
- Have validation steps (how to know you're done)
- Reference actual code when possible
- Be maintainable (update as codebase evolves)

