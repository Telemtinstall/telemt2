class BotState:
    def __init__(self):
        self.pending_create: dict[tuple[str, int], dict] = {}
        self.navigation: dict[tuple[str, int], dict] = {}

    @staticmethod
    def key(user_id: str, chat_id: int) -> tuple[str, int]:
        return str(user_id), int(chat_id)

    def set_pending_create(self, user_id: str, chat_id: int, server_id: str) -> None:
        self.pending_create[self.key(user_id, chat_id)] = {"server_id": server_id}

    def clear_pending_create(self, user_id: str, chat_id: int | None = None) -> None:
        if chat_id is not None:
            self.pending_create.pop(self.key(user_id, chat_id), None)
            return
        for key in [key for key in self.pending_create if key[0] == str(user_id)]:
            self.pending_create.pop(key, None)

    def is_pending_create(self, user_id: str, chat_id: int | None = None) -> bool:
        if chat_id is not None:
            return self.key(user_id, chat_id) in self.pending_create
        return any(key[0] == str(user_id) for key in self.pending_create)

    def pending_create_server(self, user_id: str, chat_id: int | None = None) -> str | None:
        if chat_id is not None:
            item = self.pending_create.get(self.key(user_id, chat_id)) or {}
            return item.get("server_id")
        for key, item in self.pending_create.items():
            if key[0] == str(user_id):
                return item.get("server_id")
        return None

    def set_context(
        self,
        user_id: str,
        chat_id: int,
        screen: str,
        server_id: str | None = None,
        ref: str | None = None,
    ) -> None:
        self.navigation[self.key(user_id, chat_id)] = {
            "screen": screen,
            "server_id": server_id,
            "ref": ref,
        }

    def context(self, user_id: str, chat_id: int) -> dict:
        return dict(self.navigation.get(self.key(user_id, chat_id)) or {})

    def clear_context(self, user_id: str, chat_id: int) -> None:
        self.navigation.pop(self.key(user_id, chat_id), None)
