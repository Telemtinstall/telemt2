"""Restore persisted service choices through the same audited worker FIFO."""
import logging
import uuid

log = logging.getLogger('vpnbot.reconciliation')


def enqueue_reconciliation(queue, actions):
    admins = sorted(actions.settings.allowed_users)
    if not admins:
        return
    actor = str(admins[0])
    token = uuid.uuid4().hex
    for server_id, enabled in actions.access_store.protocol_states().items():
        try:
            server = actions.servers.get(server_id)
            if server.is_active() == enabled:
                continue
            queue.enqueue('reconcile:' + token + ':' + server_id, actor, int(actor),
                          'toggle_protocol', [int(actor), server_id, enabled, actor], {})
            log.warning('Service reconciliation queued: %s', server_id)
        except Exception:
            log.warning('Could not inspect service state: %s', server_id)
