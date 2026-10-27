"""Worker mutations reconcile bot storage only after the server confirms the action."""
from app.hysteria_actions import HysteriaActions
from app import formatters


class WorkerActions(HysteriaActions):
    def delete_client(self, chat_id, server_id, ref, message_id):
        server = self.servers.get(server_id)
        self.verify_profile(ref, server.show(ref), server.id)
        # Keep access/traffic records if the server command fails.
        deleted = server.delete(ref)
        name = str(deleted.get('name') or ref)
        if any(item.get('name') in {ref, name} for item in server.list_clients()):
            raise RuntimeError('Сервер не подтвердил удаление пользователя')
        if self.access_store:
            self.access_store.purge_profile(server.id, name)
        if self.traffic_store:
            self.traffic_store.delete_user(server.id, name)
        self.telegram.edit_message(
            chat_id, message_id,
            f'Удален <b>{formatters.h(name)}</b> на сервере <b>{formatters.h(server.title)}</b>.\n'
            'База трафика, доступ к боту и ожидающие приглашения также удалены.',
            {'inline_keyboard': []},
        )
        self.show_list(chat_id, server_id)
