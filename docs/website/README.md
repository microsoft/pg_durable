# pg_durable Website

This folder contains a static, scenario-driven landing page for pg_durable users.

It also points users to the `pg-durable-sql` agent skill, so an AI assistant can
generate durable-function SQL for them.

## Files

- `index.html` — Main page
- `styles.css` — Page styling

## Preview locally

From the repository root:

```bash
python3 -m http.server 8080
```

Then open:

- <http://localhost:8080/docs/website/index.html>

## Content sources

The website content is based on:

- `docs/SCENARIOS.md`
- `docs/ai/SCENARIOS.md`
- `examples/README.md`
- `USER_GUIDE.md`
- `README.md`

## Related

- `.agents/skills/pg-durable-sql/` — agent skill for generating pg_durable SQL
