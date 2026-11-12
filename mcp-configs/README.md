# Read-only DB access for agents

Do not rely on the MCP server for safety. Enforce it in the database:

```sql
CREATE ROLE agent_ro LOGIN PASSWORD '...';
GRANT CONNECT ON DATABASE appdb TO agent_ro;
GRANT USAGE ON SCHEMA public TO agent_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO agent_ro;
ALTER ROLE agent_ro SET default_transaction_read_only = on;
```

Point it at a replica or a sanitized copy, never production data with PII.
Check the server package's maintenance status before adopting it; swap in
whichever Postgres MCP server you trust.
