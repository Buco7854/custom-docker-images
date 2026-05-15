#!/bin/bash
# Daily maintenance for the nginx-ui sqlite DB.
#
# Disables all upstream + site health checks that nginx-ui runs in the
# background. They generate constant traffic to every backend, which we
# don't want on this host.
#
# Runs on the host (not inside a container). The DB lives inside the
# nginx container at /etc/nginx-ui/database.db; we shell in via `docker
# exec` so we don't need to know the host bind path.
#
# Install:
#   sudo cp scripts/maintenance_nginx_ui.sh /usr/local/bin/
#   sudo chmod +x /usr/local/bin/maintenance_nginx_ui.sh
#   echo "0 4 * * * root /usr/local/bin/maintenance_nginx_ui.sh \
#       >> /var/log/maintenance_nginx_ui.log 2>&1" \
#       | sudo tee /etc/cron.d/nginx-ui-maintenance

set -euo pipefail

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

echo "$(ts) [maintenance] starting nginx-ui DB cleanup"

docker exec nginx sqlite3 /etc/nginx-ui/database.db <<'EOF'
-- Triggers: any newly inserted row gets forced-disabled.
DROP TRIGGER IF EXISTS trg_force_disable_upstream;
CREATE TRIGGER trg_force_disable_upstream
AFTER INSERT ON upstream_configs
BEGIN
    UPDATE upstream_configs SET enabled = 0 WHERE id = NEW.id;
END;

DROP TRIGGER IF EXISTS trg_force_disable_site_check;
CREATE TRIGGER trg_force_disable_site_check
AFTER INSERT ON site_configs
BEGIN
    UPDATE site_configs SET health_check_enabled = 0 WHERE id = NEW.id;
END;

-- Sweep any existing rows that aren't already disabled.
UPDATE upstream_configs SET enabled = 0 WHERE enabled != 0;
UPDATE site_configs SET health_check_enabled = 0 WHERE health_check_enabled != 0;
EOF

echo "$(ts) [maintenance] done"
