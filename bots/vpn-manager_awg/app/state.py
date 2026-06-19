class BotState:
    def __init__(self):
        self.pending_create: set[str] = set()

    def set_pending_create(self, user_id: str) -> None:
        self.pending_create.add(user_id)

    def clear_pending_create(self, user_id: str) -> None:
        self.pending_create.discard(user_id)

    def is_pending_create(self, user_id: str) -> bool:
        return user_id in self.pending_create

