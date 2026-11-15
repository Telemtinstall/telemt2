import tempfile
import unittest
import threading
from pathlib import Path
from types import SimpleNamespace
from unittest import mock
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser

from app.dispatch_pool import DispatchPool
from app.access_store import AccessStore
from app.actions import Actions
from app.callback_store import CallbackStore
from app.update_store import UpdateStore
from app.traffic_store import TrafficStore
from app.formatters import split_text
from app.config import load_settings


class AuditRegressions(unittest.TestCase):
    def test_callback_cannot_be_replayed_or_used_in_another_chat(self):
        with tempfile.TemporaryDirectory() as directory:
            store = CallbackStore(Path(directory) / 'access.sqlite3')
            markup = store.markup(10, {'inline_keyboard': [[{'text':'delete', 'callback_data':'delyes:awg:alice'}]]})
            value = markup['inline_keyboard'][0][0]['callback_data']
            with self.assertRaises(ValueError):
                store.resolve(11, value)
            self.assertEqual('delyes:awg:alice', store.resolve(10, value))
            with self.assertRaises(ValueError):
                store.resolve(10, value)
            with self.assertRaises(ValueError):
                store.resolve(10, 'delyes:awg:alice')

    def test_interrupted_dispatch_is_not_replayed_after_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'access.sqlite3'
            self.assertTrue(UpdateStore(path).start(123))
            store = UpdateStore(path)
            self.assertEqual(124, store.offset())
            self.assertEqual([123], store.interrupted())
            self.assertFalse(store.start(123))

    def test_controller_identity_mismatch_never_sends_secret(self):
        server = SimpleNamespace(id='awg', is_amneziawg=True, show=lambda _: {'name':'other', 'config':'SECRET'})
        telegram = mock.Mock()
        actions = Actions(None, telegram, SimpleNamespace(get=lambda _: server), None)
        with self.assertRaises(PermissionError):
            actions.send_config_file_for_client(10, 'awg', 'alice')
        telegram.send_config_file.assert_not_called()

    def test_access_is_purged_even_when_traffic_cleanup_fails(self):
        server = SimpleNamespace(id='awg', show=lambda _: {'name':'alice'}, delete=lambda _: {'name':'alice'})
        access = mock.Mock()
        traffic = SimpleNamespace(delete_user=mock.Mock(side_effect=OSError('disk error')))
        actions = Actions(None, mock.Mock(), SimpleNamespace(get=lambda _: server), None, traffic, access)
        with self.assertRaises(OSError):
            actions.delete_client(10, 'awg', 'alice', 3)
        access.purge_profile.assert_called_once_with('awg', 'alice')

    def test_empty_snapshot_does_not_contact_disabled_controller(self):
        with tempfile.TemporaryDirectory() as directory:
            server = SimpleNamespace(id='vless', protocol='vless', is_amneziawg=False, is_vless=True, traffic=mock.Mock(side_effect=AssertionError('controller contacted')))
            store = TrafficStore(Path(directory))
            self.assertEqual([], store.live_rows(server, {}))
            self.assertEqual(0, store.capture_server(server, {}))

    def test_concurrent_identical_snapshots_are_counted_once(self):
        with tempfile.TemporaryDirectory() as directory:
            store = TrafficStore(Path(directory))
            server = SimpleNamespace(id='vless', protocol='vless', is_amneziawg=False, is_vless=True)
            data = {'clients':[{'name':'alice', 'uplink_bytes':100, 'downlink_bytes':200}]}
            with ThreadPoolExecutor(max_workers=4) as executor:
                list(executor.map(lambda _: store.capture_server(server, data), range(8)))
            self.assertEqual(300, sum(row['total_bytes'] for row in store.stored_daily_rows()))

    def test_database_collision_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            store = TrafficStore(Path(directory))
            store.ensure_user('a__b', 'vless', 'c')
            with self.assertRaises(ValueError):
                store.ensure_user('a', 'vless', 'b__c')

    def test_html_entities_and_tags_survive_chunking(self):
        class Parser(HTMLParser):
            def __init__(self):
                super().__init__(); self.stack=[]; self.text=''
            def handle_starttag(self, tag, attrs): self.stack.append(tag)
            def handle_endtag(self, tag): self.assert_tag = self.stack.pop() == tag
            def handle_data(self, data): self.text += data
        text = '<b>Начало <code>' + 'x &amp; 😃 ' * 20 + '</code></b>'
        result = ''
        for part in split_text(text, 80):
            parser = Parser(); parser.feed(part)
            self.assertEqual([], parser.stack)
            self.assertTrue(parser.assert_tag)
            self.assertLessEqual(len(part.encode('utf-16-le')) // 2, 80)
            result += parser.text
        self.assertEqual('Начало ' + 'x & 😃 ' * 20, result)

    def test_zero_message_limit_rejected(self):
        with self.assertRaises(ValueError): split_text('text', 0)
        with mock.patch.dict('os.environ', {'BOT_TOKEN':'test', 'ALLOWED_USERS':'1', 'MAX_MESSAGE':'0'}, clear=True):
            with self.assertRaises(ValueError): load_settings(Path('/nonexistent-audit-env'))

    def test_slow_chat_does_not_block_other_chat_and_preserves_order(self):
        with tempfile.TemporaryDirectory() as directory:
            store = UpdateStore(Path(directory) / 'access.sqlite3')
            started, release, other = threading.Event(), threading.Event(), threading.Event()
            observed = []
            def handle(update):
                if update['update_id'] == 1:
                    started.set()
                    if not release.wait(5): raise RuntimeError('test release timeout')
                observed.append(update['update_id'])
                if update['update_id'] == 3: other.set()
            pool = DispatchPool(store, handle)
            try:
                for update_id, chat in [(1,10),(2,10),(3,20)]:
                    pool.submit({'update_id':update_id, 'message':{'chat':{'id':chat}}})
                self.assertTrue(started.wait(2))
                self.assertTrue(other.wait(2))
            finally:
                release.set(); pool.close()
            self.assertLess(observed.index(1), observed.index(2))
            self.assertEqual([], store.pending())
            self.assertEqual([], store.interrupted())

    def test_queued_update_survives_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'access.sqlite3'
            update = {'update_id':5, 'message':{'chat':{'id':10}}}
            self.assertTrue(UpdateStore(path).accept(update))
            store = UpdateStore(path)
            self.assertEqual([update], store.pending())
            self.assertTrue(store.start(5))
            store.finish(5)
            self.assertEqual([], store.pending())

    def test_changed_key_revokes_old_access_and_old_buttons(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'access.sqlite3'
            access = AccessStore(path)
            access.sync_profile_identity('awg','alice','old-key-hash')
            token = access.create_invite('awg','amneziawg','alice','1')['token']
            access.claim(token, {'id':2})
            callbacks = CallbackStore(path)
            value = callbacks.markup(1, {'inline_keyboard':[[{'text':'delete','callback_data':'delyes:awg:alice'}]]})['inline_keyboard'][0][0]['callback_data']
            self.assertTrue(access.sync_profile_identity('awg','alice','new-key-hash'))
            self.assertFalse(access.owns('2','awg','alice'))
            with self.assertRaises(ValueError): callbacks.resolve(1,value)
