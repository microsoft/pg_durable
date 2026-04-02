-- Seed data: two invoices for the initial demo.
-- One small (auto-approved), one large (needs human approval).

INSERT INTO demo.invoices (description, raw_amount) VALUES
    ('Acme Corp - Office supplies order Q2', '$3,420.00'),
    ('GlobalTech Consulting - Cloud infrastructure advisory engagement', '$24,500.00');

SELECT id, description, raw_amount, status
FROM demo.invoices
ORDER BY id;
