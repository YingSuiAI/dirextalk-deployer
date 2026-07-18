#!/bin/sh
# Create the Agent's isolated PostgreSQL principal/database and write only its
# mounted DSN. This runs once inside the existing Postgres network namespace;
# generated credentials never enter Compose arguments, logs, or user-data.
set -eu

runtime_dir=${AGENT_RUNTIME_DIR:?AGENT_RUNTIME_DIR is required}
db_url_file="$runtime_dir/agent-database-url"
agent_role=dirextalk_agent
agent_database=dirextalk_agent

die() {
  printf '%s\n' "agent DB initialization failed: $*" >&2
  exit 1
}

random_url_key() {
  dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr '+/' '-_' | tr -d '=\n'
}

psql_admin() {
  PGPASSWORD="$POSTGRES_PASSWORD" psql \
    --no-password \
    --host=postgres \
    --username="$POSTGRES_USER" \
    --dbname="$POSTGRES_DB" \
    --set=ON_ERROR_STOP=1 \
    "$@"
}

[ -n "${POSTGRES_USER:-}" ] || die 'POSTGRES_USER is required'
[ -n "${POSTGRES_PASSWORD:-}" ] || die 'POSTGRES_PASSWORD is required'
[ -n "${POSTGRES_DB:-}" ] || die 'POSTGRES_DB is required'
mkdir -p "$runtime_dir"
umask 077

if [ -e "$db_url_file" ]; then
  [ -f "$db_url_file" ] && [ -s "$db_url_file" ] || die 'existing Agent database URL is not a non-empty regular file'
  role_exists=$(psql_admin --tuples-only --no-align --command "SELECT 1 FROM pg_roles WHERE rolname='$agent_role'" | tr -d '\r\n')
  database_exists=$(psql_admin --tuples-only --no-align --command "SELECT 1 FROM pg_database WHERE datname='$agent_database'" | tr -d '\r\n')
  [ "$role_exists" = 1 ] && [ "$database_exists" = 1 ] || die 'mounted Agent database URL exists but its role/database does not'
  chmod 0400 "$db_url_file"
  chown 65532:65532 "$db_url_file"
  exit 0
fi

database_password=$(random_url_key)
[ "${#database_password}" -ge 32 ] || die 'could not generate Agent database password material'

# The generated URL-safe value cannot add SQL syntax. It is sent only through
# psql stdin, never via an argv flag or a process environment export.
printf "DO \$\$ BEGIN\n  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '%s') THEN\n    CREATE ROLE %s LOGIN PASSWORD '%s';\n  ELSE\n    ALTER ROLE %s LOGIN PASSWORD '%s';\n  END IF;\nEND \$\$;\n" \
  "$agent_role" "$agent_role" "$database_password" "$agent_role" "$database_password" \
  | psql_admin

database_exists=$(psql_admin --tuples-only --no-align --command "SELECT 1 FROM pg_database WHERE datname='$agent_database'" | tr -d '\r\n')
if [ "$database_exists" != 1 ]; then
  psql_admin --command "CREATE DATABASE $agent_database OWNER $agent_role"
fi

printf 'postgres://%s:%s@postgres:5432/%s?sslmode=disable\n' \
  "$agent_role" "$database_password" "$agent_database" > "$db_url_file"
unset database_password
chmod 0400 "$db_url_file"
chown 65532:65532 "$db_url_file"
