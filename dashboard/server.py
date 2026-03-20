#!/usr/bin/env python3
"""
pg_durable Dashboard Server
A lightweight dashboard to visualize durable function instances and their node graphs.
Uses psql subprocess calls — no extra Python dependencies needed.
"""

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

PG_HOST = "localhost"
PG_PORT = "28817"
PG_DB = "postgres"

def run_query(sql):
    """Run a SQL query via psql and return JSON results."""
    # Use psql with CSV output for easy parsing
    cmd = [
        PSQL, "-h", PG_HOST, "-p", PG_PORT, "-d", PG_DB,
        "-t",  # tuples only
        "-A",  # unaligned
        "-F", "\t",  # tab separator
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
    rows = []
    for line in result["data"].split("\n"):
        if not line.strip():
            continue
        values = line.split("\t")
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
        elif parsed.path == "/api/pipelines":
            self.send_json(self.get_pipelines())
        elif parsed.path == "/api/pipeline/status":
            params = parse_qs(parsed.query)
            name = params.get("name", [None])[0]
            if not name:
                self.send_json({"error": "name required"})
            else:
                self.send_json(self.get_pipeline_status(name))
        elif parsed.path == "/api/pipeline/runs":
            params = parse_qs(parsed.query)
            name = params.get("name", [None])[0]
            if not name:
                self.send_json({"error": "name required"})
            else:
                self.send_json(self.get_pipeline_runs(name))
        elif parsed.path == "/api/pipeline/explain":
            params = parse_qs(parsed.query)
            name = params.get("name", [None])[0]
            if not name:
                self.send_json({"error": "name required"})
            else:
                self.send_json(self.get_pipeline_explain(name))
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
        elif parsed.path == "/api/pipeline/run":
            self.send_json(self.run_pipeline(data))
        elif parsed.path == "/api/pipeline/pause":
            self.send_json(self.pause_pipeline(data))
        elif parsed.path == "/api/pipeline/resume":
            self.send_json(self.resume_pipeline(data))
        elif parsed.path == "/api/pipeline/backfill":
            self.send_json(self.backfill_pipeline(data))
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
        # Sanitize to prevent injection (only allow hex chars)
        safe_id = ''.join(c for c in instance_id if c in '0123456789abcdef')
        return query_to_dicts(
            f"""SELECT id, instance_id, node_type, 
                       query,
                       result_name, left_node, right_node, status,
                       result::text as result, error
                FROM df.nodes
                WHERE instance_id = '{safe_id}'
                ORDER BY created_at""",
            ["id", "instance_id", "node_type", "query", "result_name",
             "left_node", "right_node", "status", "result", "error"]
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
        """Find Running/pending instances, and flag those with SIGNAL nodes."""
        return query_to_dicts(
            """SELECT 
                   i.id as instance_id,
                   i.label,
                   i.status as instance_status,
                   to_char(i.created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at,
                   COALESCE(sig.signal_name, '') as signal_name,
                   COALESCE(sig.signal_status, '') as signal_status,
                   COALESCE(sig.timeout_seconds, '') as timeout_seconds,
                   COALESCE(sig.node_id, '') as signal_node_id
               FROM df.instances i
               LEFT JOIN LATERAL (
                   SELECT 
                       n.id as node_id,
                       n.status as signal_status,
                       (n.query::jsonb->>'signal_name') as signal_name,
                       COALESCE(n.query::jsonb->>'timeout_seconds', '') as timeout_seconds
                   FROM df.nodes n 
                   WHERE n.instance_id = i.id 
                     AND n.node_type = 'SIGNAL'
                   ORDER BY n.created_at DESC
                   LIMIT 1
               ) sig ON true
               WHERE i.status IN ('Running', 'pending')
               ORDER BY i.created_at DESC""",
            ["instance_id", "label", "instance_status", "created_at",
             "signal_name", "signal_status", "timeout_seconds", "signal_node_id"]
        )

    # ===== AI Pipeline API =====

    def _has_ai_schema(self):
        """Check if the ai schema exists."""
        result = run_query("SELECT 1 FROM information_schema.schemata WHERE schema_name = 'ai'")
        return "error" not in result and result.get("data", "").strip() == "1"

    def get_pipelines(self):
        if not self._has_ai_schema():
            return []
        return query_to_dicts(
            """SELECT p.name,
                      p.source_config->>'type' as source_type,
                      p.source_config->>'table_name' as source_table,
                      array_length(p.steps, 1)::text as step_count,
                      p.trigger_type,
                      p.paused::text as paused,
                      to_char(p.created_at, 'YYYY-MM-DD HH24:MI:SS') as created_at,
                      p.created_by,
                      COALESCE(cp.total_processed::text, '0') as total_processed,
                      COALESCE(lr.status, '') as last_run_status,
                      COALESCE(lr.instance_id, '') as last_instance_id,
                      COALESCE(to_char(lr.started_at, 'YYYY-MM-DD HH24:MI:SS'), '') as last_run_at
               FROM ai.pipelines p
               LEFT JOIN ai.pipeline_checkpoints cp ON cp.pipeline_name = p.name
               LEFT JOIN LATERAL (
                   SELECT pr.status, pr.instance_id, pr.started_at
                   FROM ai.pipeline_runs pr
                   WHERE pr.pipeline_name = p.name
                   ORDER BY pr.started_at DESC
                   LIMIT 1
               ) lr ON true
               ORDER BY p.created_at DESC""",
            ["name", "source_type", "source_table", "step_count", "trigger_type",
             "paused", "created_at", "created_by", "total_processed",
             "last_run_status", "last_instance_id", "last_run_at"]
        )

    def get_pipeline_status(self, name):
        if not self._has_ai_schema():
            return {"error": "AI pipeline schema not installed"}
        safe_name = re.sub(r'[^a-zA-Z0-9_-]', '', name)
        return query_to_dicts(
            f"""SELECT * FROM ai.status('{safe_name}')""",
            ["name", "trigger_type", "paused", "last_run_status", "last_run_at",
             "total_runs", "total_processed", "last_instance", "df_status"]
        )

    def get_pipeline_runs(self, name):
        if not self._has_ai_schema():
            return []
        safe_name = re.sub(r'[^a-zA-Z0-9_-]', '', name)
        return query_to_dicts(
            f"""SELECT pr.id::text, pr.instance_id, pr.status,
                       to_char(pr.started_at, 'YYYY-MM-DD HH24:MI:SS') as started_at,
                       COALESCE(to_char(pr.completed_at, 'YYYY-MM-DD HH24:MI:SS'), '') as completed_at,
                       COALESCE(pr.rows_processed::text, '0') as rows_processed,
                       COALESCE(pr.error, '') as error
                FROM ai.pipeline_runs pr
                WHERE pr.pipeline_name = '{safe_name}'
                ORDER BY pr.started_at DESC
                LIMIT 20""",
            ["id", "instance_id", "status", "started_at", "completed_at",
             "rows_processed", "error"]
        )

    def get_pipeline_explain(self, name):
        if not self._has_ai_schema():
            return {"error": "AI pipeline schema not installed"}
        safe_name = re.sub(r'[^a-zA-Z0-9_-]', '', name)
        result = run_query(f"SELECT ai.explain('{safe_name}')")
        if "error" in result:
            return result
        return {"explain": result.get("data", "")}

    def _pipeline_action(self, data, action):
        """Run an ai.* action on a pipeline."""
        name = data.get("name", "")
        if not name or not re.match(r'^[a-zA-Z0-9_-]+$', name):
            return {"error": "Invalid pipeline name"}
        if not self._has_ai_schema():
            return {"error": "AI pipeline schema not installed"}
        sql = f"SELECT ai.{action}('{name}')"
        result = run_query(sql)
        if "error" in result:
            return {"error": result["error"]}
        return {"success": True, "result": result.get("data", "OK")}

    def run_pipeline(self, data):
        return self._pipeline_action(data, "run")

    def pause_pipeline(self, data):
        return self._pipeline_action(data, "pause")

    def resume_pipeline(self, data):
        return self._pipeline_action(data, "resume")

    def backfill_pipeline(self, data):
        return self._pipeline_action(data, "backfill")

    def send_signal(self, data):
        """Send a signal to a running instance via df.signal()."""
        instance_id = data.get("instance_id", "")
        signal_name = data.get("signal_name", "")
        signal_data = data.get("signal_data", "{}")

        # Validate instance_id: only hex chars
        if not instance_id or not re.match(r'^[0-9a-f]+$', instance_id):
            return {"error": "Invalid instance_id"}
        if not signal_name or not re.match(r'^[a-zA-Z0-9_-]+$', signal_name):
            return {"error": "Invalid signal_name"}
        # Validate signal_data is valid JSON
        try:
            json.loads(signal_data)
        except json.JSONDecodeError:
            return {"error": "signal_data must be valid JSON"}

        # Escape single quotes in signal_data for SQL
        safe_data = signal_data.replace("'", "''")
        sql = f"SELECT df.signal('{instance_id}', '{signal_name}', '{safe_data}')"
        result = run_query(sql)
        if "error" in result:
            return {"error": result["error"]}
        return {"success": True, "result": result.get("data", "OK")}

    def log_message(self, format, *args):
        # Quieter logging
        if "/api/" not in str(args[0]):
            super().log_message(format, *args)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8888))
    server = HTTPServer(("0.0.0.0", port), DashboardHandler)
    print(f"🚀 pg_durable Dashboard running at http://localhost:{port}")
    print(f"   Using psql: {PSQL}")
    print(f"   Connected to: {PG_HOST}:{PG_PORT}/{PG_DB}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.server_close()
