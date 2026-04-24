#!/usr/bin/env python3
"""
pg_durable Visualization Dashboard Server (v2)
Serves the dashboard-v2 UI and proxies pg_durable introspection APIs.
Uses psql subprocess calls — no extra Python dependencies needed.
"""

import csv
import io
import json
import glob
import os
import subprocess
import re
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# Find psql binary
PSQL_PATTERN = os.path.expanduser("~/.pgrx/17.*/pgrx-install/bin/psql")
PSQL_CANDIDATES = glob.glob(PSQL_PATTERN)
PSQL = PSQL_CANDIDATES[0] if PSQL_CANDIDATES else "psql"

PG_HOST = os.environ.get("PG_HOST", "localhost")
PG_PORT = os.environ.get("PG_PORT", "28817")
PG_DB = os.environ.get("PG_DB", "postgres")


def run_query(sql):
    """Run a SQL query via psql and return CSV results."""
    cmd = [
        PSQL, "-h", PG_HOST, "-p", PG_PORT, "-d", PG_DB,
        "-t",  # tuples only
        "--csv",  # CSV output
        "-c", sql
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            return {"error": result.stderr.strip()}
        return {"data": result.stdout.strip()}
    except Exception as e:
        return {"error": str(e)}


def query_to_dicts(sql, columns):
    """Run query and convert to list of dicts."""
    result = run_query(sql)
    if "error" in result:
        return result
    data = result["data"]
    if not data:
        return []
    rows = []
    reader = csv.reader(io.StringIO(data))
    for values in reader:
        if not any(v.strip() for v in values):
            continue
        row = {}
        for i, col in enumerate(columns):
            row[col] = values[i] if i < len(values) else None
        rows.append(row)
    return rows


class DashboardHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.dirname(os.path.abspath(__file__)), **kwargs)

    def do_GET(self):
        parsed = urlparse(self.path)

        if parsed.path == "/api/instances":
            self.send_json(self.get_instances())
        elif parsed.path == "/api/nodes":
            params = parse_qs(parsed.query)
            instance_id = params.get("instance_id", [None])[0]
            if not instance_id:
                self.send_json({"error": "instance_id required"})
            else:
                self.send_json(self.get_nodes(instance_id))
        elif parsed.path == "/api/stats":
            self.send_json(self.get_stats())
        elif parsed.path == "/api/waiting":
            self.send_json(self.get_waiting_instances())
        elif parsed.path == "/api/explain":
            params = parse_qs(parsed.query)
            instance_id = params.get("instance_id", [None])[0]
            expression = params.get("expression", [None])[0]
            if instance_id:
                self.send_json(self.get_explain_instance(instance_id))
            elif expression:
                self.send_json(self.get_explain_expression(expression))
            else:
                self.send_json({"error": "instance_id or expression required"})
        elif parsed.path == "/api/instance_info":
            params = parse_qs(parsed.query)
            instance_id = params.get("instance_id", [None])[0]
            if not instance_id:
                self.send_json({"error": "instance_id required"})
            else:
                self.send_json(self.get_instance_info(instance_id))
        elif parsed.path == "/api/pipeline/explain":
            params = parse_qs(parsed.query)
            name = params.get("name", [None])[0]
            if not name:
                self.send_json({"error": "name required"})
            else:
                self.send_json(self.get_pipeline_explain(name))
        elif parsed.path == "/api/pipeline/instances":
            params = parse_qs(parsed.query)
            name = params.get("name", [None])[0]
            if not name:
                self.send_json({"error": "name required"})
            else:
                self.send_json(self.get_pipeline_instances(name))
        else:
            super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8')
        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self.send_json({"error": "Invalid JSON"})
            return

        if parsed.path == "/api/signal":
            self.send_json(self.send_signal(data))
        elif parsed.path == "/api/cancel":
            self.send_json(self.cancel_instance(data))
        else:
            self.send_json({"error": "Not found"})

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def send_json(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def get_instances(self):
        return query_to_dicts(
            """SELECT id, label, status, root_node,
                      to_char(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at,
                      to_char(completed_at, 'YYYY-MM-DD HH24:MI:SS') as completed_at,
                      COALESCE(
                        EXTRACT(EPOCH FROM (completed_at - created_at))::text,
                        ''
                      ) as duration_secs
               FROM df.instances
               ORDER BY created_at DESC""",
            ["id", "label", "status", "root_node", "created_at", "completed_at", "duration_secs"]
        )

    def get_nodes(self, instance_id):
        # Sanitize to prevent injection (only allow hex chars and dashes)
        safe_id = ''.join(c for c in instance_id if c in '0123456789abcdef-')
        return query_to_dicts(
            f"""SELECT id, instance_id, node_type, 
                       query,
                       result_name, left_node, right_node, status,
                       result::text as result, error,
                       to_char(created_at, 'YYYY-MM-DD HH24:MI:SS.MS') as created_at,
                       to_char(updated_at, 'YYYY-MM-DD HH24:MI:SS.MS') as updated_at,
                       COALESCE(
                         EXTRACT(EPOCH FROM (updated_at - created_at))::text,
                         ''
                       ) as duration_secs
                FROM df.nodes
                WHERE instance_id = '{safe_id}'
                ORDER BY created_at""",
            ["id", "instance_id", "node_type", "query", "result_name",
             "left_node", "right_node", "status", "result", "error",
             "created_at", "updated_at", "duration_secs"]
        )

    def get_stats(self):
        return query_to_dicts(
            """SELECT status, COUNT(*)::text as count
               FROM df.instances
               GROUP BY status
               ORDER BY status""",
            ["status", "count"]
        )

    def get_waiting_instances(self):
        """Find Running/pending instances with SIGNAL nodes that haven't completed."""
        return query_to_dicts(
            """SELECT 
                   i.id as instance_id,
                   i.label,
                   i.status as instance_status,
                   to_char(i.created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at,
                   sig.signal_name,
                   sig.signal_status,
                   COALESCE(sig.timeout_seconds, '') as timeout_seconds,
                   sig.node_id as signal_node_id
               FROM df.instances i
               INNER JOIN LATERAL (
                   SELECT 
                       n.id as node_id,
                       n.status as signal_status,
                       (n.query::jsonb->>'signal_name') as signal_name,
                       COALESCE(n.query::jsonb->>'timeout_seconds', '') as timeout_seconds
                   FROM df.nodes n 
                   WHERE n.instance_id = i.id 
                     AND n.node_type = 'SIGNAL'
                     AND n.status NOT IN ('completed', 'failed')
                   ORDER BY n.created_at DESC
                   LIMIT 1
               ) sig ON true
               WHERE i.status IN ('Running', 'pending')
               ORDER BY i.created_at DESC""",
            ["instance_id", "label", "instance_status", "created_at",
             "signal_name", "signal_status", "timeout_seconds", "signal_node_id"]
        )

    def get_explain_instance(self, instance_id):
        safe_id = ''.join(c for c in instance_id if c in '0123456789abcdef-')
        result = run_query(f"SELECT df.explain('{safe_id}')")
        if "error" in result:
            return result
        return {"explain": result.get("data", "")}

    def get_explain_expression(self, expression):
        # df.explain() takes a Durofut (the DSL expression evaluated inline).
        # Users may enter: "SELECT df.start(expr, 'label')" or just "expr"
        safe_expr = expression.strip().rstrip(';')
        if safe_expr.upper().startswith('SELECT '):
            safe_expr = safe_expr[7:].strip()
        # If user wrapped in df.explain(...), unwrap
        if safe_expr.lower().startswith('df.explain(') and safe_expr.endswith(')'):
            safe_expr = safe_expr[len('df.explain('):-1].strip()
        # If user wrapped in df.start(expr, 'label'), extract just expr
        if safe_expr.lower().startswith('df.start(') and safe_expr.endswith(')'):
            inner = safe_expr[len('df.start('):-1].strip()
            # Remove trailing label: find last top-level comma not inside parens/quotes
            depth = 0
            in_quote = False
            last_comma = -1
            for i, ch in enumerate(inner):
                if ch == "'" and (i == 0 or inner[i-1] != '\\'):
                    in_quote = not in_quote
                elif not in_quote:
                    if ch == '(':
                        depth += 1
                    elif ch == ')':
                        depth -= 1
                    elif ch == ',' and depth == 0:
                        last_comma = i
            if last_comma > 0:
                safe_expr = inner[:last_comma].strip()
            else:
                safe_expr = inner
        result = run_query(f"SELECT df.explain({safe_expr})")
        if "error" in result:
            return result
        return {"explain": result.get("data", "")}

    def get_instance_info(self, instance_id):
        safe_id = ''.join(c for c in instance_id if c in '0123456789abcdef-')
        rows = query_to_dicts(
            f"""SELECT id, label, status, root_node,
                       to_char(created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at,
                       to_char(completed_at, 'YYYY-MM-DD HH24:MI:SS') as completed_at,
                       COALESCE(
                         EXTRACT(EPOCH FROM (completed_at - created_at))::text,
                         ''
                       ) as duration_secs
                FROM df.instances
                WHERE id = '{safe_id}'""",
            ["id", "label", "status", "root_node", "created_at", "completed_at", "duration_secs"]
        )
        if isinstance(rows, dict) and "error" in rows:
            return rows
        return rows[0] if rows else {"error": "Instance not found"}

    def get_pipeline_explain(self, name):
        safe_name = re.sub(r'[^a-zA-Z0-9_-]', '', name)
        result = run_query(f"SELECT ai.explain('{safe_name}')")
        if "error" in result:
            return result
        return {"explain": result.get("data", "")}

    def get_pipeline_instances(self, name):
        safe_name = re.sub(r'[^a-zA-Z0-9_-]', '', name)
        return query_to_dicts(
            f"""SELECT i.id, i.label, i.status,
                       to_char(i.created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at,
                       to_char(i.completed_at, 'YYYY-MM-DD HH24:MI:SS') as completed_at,
                       COALESCE(
                         EXTRACT(EPOCH FROM (i.completed_at - i.created_at))::text,
                         ''
                       ) as duration_secs
                FROM df.instances i
                WHERE i.label = 'ai-pipeline:{safe_name}'
                ORDER BY i.created_at DESC
                LIMIT 20""",
            ["id", "label", "status", "created_at", "completed_at", "duration_secs"]
        )

    def send_signal(self, data):
        """Send a signal to a running instance via df.signal()."""
        instance_id = data.get("instance_id", "")
        signal_name = data.get("signal_name", "")
        signal_data = data.get("signal_data", "{}")

        if not instance_id or not re.match(r'^[0-9a-f-]+$', instance_id):
            return {"error": "Invalid instance_id"}
        if not signal_name or not re.match(r'^[a-zA-Z0-9_-]+$', signal_name):
            return {"error": "Invalid signal_name"}
        try:
            json.loads(signal_data)
        except json.JSONDecodeError:
            return {"error": "signal_data must be valid JSON"}

        safe_data = signal_data.replace("'", "''")
        sql = f"SELECT df.signal('{instance_id}', '{signal_name}', '{safe_data}')"
        result = run_query(sql)
        if "error" in result:
            return {"error": result["error"]}
        return {"success": True, "result": result.get("data", "OK")}

    def cancel_instance(self, data):
        """Cancel a running instance via df.cancel()."""
        instance_id = data.get("instance_id", "")
        reason = data.get("reason", "Cancelled from dashboard")

        if not instance_id or not re.match(r'^[0-9a-f-]+$', instance_id):
            return {"error": "Invalid instance_id"}
        # Sanitize reason
        safe_reason = reason.replace("'", "''")[:200]

        sql = f"SELECT df.cancel('{instance_id}', '{safe_reason}')"
        result = run_query(sql)
        if "error" in result:
            return {"error": result["error"]}
        return {"success": True, "result": result.get("data", "OK")}

    def log_message(self, format, *args):
        if "/api/" not in str(args[0]):
            super().log_message(format, *args)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8889))
    server = HTTPServer(("0.0.0.0", port), DashboardHandler)
    print(f"pg_durable Visualization Dashboard running at http://localhost:{port}")
    print(f"  Using psql: {PSQL}")
    print(f"  Connected to: {PG_HOST}:{PG_PORT}/{PG_DB}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.server_close()
