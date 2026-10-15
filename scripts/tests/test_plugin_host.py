import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
import zipfile

SDK = Path(__file__).resolve().parents[2] / 'submodules/AfterGramPython/SDK'
vendor = SDK.parents[2] / 'build-input/aftergram-python/resources/aftergram_sdk.zip'
if vendor.exists(): sys.path.insert(0, str(vendor))
sys.path.insert(0, str(SDK))
import aftergram_host as host

PREFIX = "from base_plugin import BasePlugin, HookResult, HookStrategy\n__id__ = 'test_plugin'\n__name__ = 'Test'\n"

def plugin(body, plugin_id='test_plugin'):
    return PREFIX.replace('test_plugin', plugin_id) + body

class PluginHostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name) / 'account'
        self.source = Path(self.temp.name) / 'input.py'
    def tearDown(self):
        self.call('close')
        self.temp.cleanup()
    def call(self, op, **kwargs):
        return json.loads(host.dispatch(json.dumps({'root': str(self.root), 'account': 42, 'op': op, **kwargs})))
    def install(self, source, enabled=True, adapt=False):
        self.source.write_text(source)
        result = self.call('install', path=str(self.source), adapt=adapt)
        self.assertNotIn('error', result, result)
        self.assertTrue(result.get('installed'), result)
        plugin_id = result['id']
        if enabled: self.assertFalse(self.call('enable', id=plugin_id, enabled=True).get('error'))
        return plugin_id
    def outgoing(self, text): return self.call('outgoing', text=text, peer='123')
    def test_first_plugin_settings_persist_and_restart(self):
        self.install(host.SAMPLE)
        self.assertEqual(self.outgoing('.hello Alice')['text'], 'Hello, Alice!')
        rows = self.call('settings', id='hello_world')['rows']
        self.assertEqual(rows[1]['value'], 'Hello, {name}!')
        self.call('setting', id='hello_world', index=1, value='Hi {name}')
        self.assertEqual(self.outgoing('.hello Alice')['text'], 'Hi Alice')
        self.call('close')
        self.assertEqual(self.outgoing('.hello Bob')['text'], 'Hi Bob')
        self.call('enable', id='hello_world', enabled=False)
        self.assertEqual(self.outgoing('.hello Bob')['text'], '.hello Bob')
    def test_plugin_extension_bom_install_restart_and_adapt(self):
        self.source = self.source.with_suffix('.PLUGIN')
        source = host.SAMPLE.replace('from ui.settings', 'from org.telegram.messenger import UserConfig as Config\nfrom ui.settings')
        self.source.write_text('\ufeff' + source)
        report = self.call('inspect', path=str(self.source))['report']
        self.assertFalse(report['issues']);self.assertTrue(report['changes'])
        installed = self.call('install', path=str(self.source), adapt=True)
        self.assertTrue(installed.get('installed'), installed)
        self.assertFalse(self.call('enable', id='hello_world', enabled=True)['error'])
        self.assertEqual(self.outgoing('.hello iPhone')['text'], 'Hello, iPhone!')
        self.call('close')
        self.assertEqual(self.outgoing('.hello Again')['text'], 'Hello, Again!')
    def test_import_errors_are_short_and_full_trace_is_logged(self):
        self.source.write_text('invalid python syntax :')
        response = self.call('inspect', path=str(self.source))
        self.assertNotIn('Traceback', response['error'])
        self.assertIn('line 1', response['error'])
        self.assertIn('Traceback', '\n'.join(self.call('logs')['logs']))
    def test_source_limit_is_checked_before_reading(self):
        self.source.write_bytes(b' ' * (host.MAX_SOURCE + 1))
        self.assertIn('2 MB', self.call('inspect', path=str(self.source))['error'])
    def test_missing_sdk_symbol_is_rejected_before_execution(self):
        self.source.write_text(plugin('from client_utils import not_a_real_function\nclass TestPlugin(BasePlugin): pass\n'))
        report = self.call('inspect', path=str(self.source))['report']
        self.assertIn('Unsupported SDK symbol: client_utils.not_a_real_function', report['issues'])
    def test_install_analysis_does_not_execute_source(self):
        sentinel = Path(self.temp.name) / 'executed'
        source = plugin(f"from pathlib import Path\nPath({str(sentinel)!r}).write_text('yes')\nclass TestPlugin(BasePlugin): pass\n")
        self.install(source, enabled=False)
        self.assertFalse(sentinel.exists())
        self.call('enable', id='test_plugin', enabled=True)
        self.assertTrue(sentinel.exists())
    def test_adapter_changes_import_not_strings(self):
        source = plugin("from org.telegram.messenger import UserConfig as Config\nfrom java.lang import Integer\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self):\n  self.add_on_send_message_hook()\n def on_send_message_hook(self, account, params):\n  assert Config.selectedAccount == account\n  params.message = str(Integer(7)) + ' org.telegram.messenger'\n  return HookResult(strategy=HookStrategy.MODIFY, params=params)\n")
        self.source.write_text(source)
        inspected = self.call('inspect', path=str(self.source))['report']
        self.assertFalse(inspected['issues']);self.assertEqual(len(inspected['changes']), 2)
        rejected = self.call('install', path=str(self.source), adapt=False)
        self.assertFalse(rejected['installed'])
        self.install(source, adapt=True)
        self.assertEqual(self.outgoing('x')['text'], '7 org.telegram.messenger')
        self.assertEqual((self.root/'test_plugin/original.source').read_text(), source)
    def test_unsupported_android_request_is_explicit(self):
        self.source.write_text(plugin("from android.widget import RecyclerView\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_hook('TL_messages_setTyping')\n"))
        report = self.call('inspect', path=str(self.source))['report']
        self.assertTrue(any('android.widget' in x for x in report['issues']))
        self.assertFalse(self.call('install', path=str(self.source))['installed'])
    def test_cancel_and_default_rollback(self):
        source = plugin("class TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_on_send_message_hook()\n def on_send_message_hook(self, account, params):\n  if params.message == 'cancel': return HookResult(strategy=HookStrategy.CANCEL)\n  params.message = 'ignored'\n  return HookResult()\n")
        self.install(source)
        self.assertTrue(self.outgoing('cancel')['cancel'])
        self.assertEqual(self.outgoing('original')['text'], 'original')
    def test_priority_and_modify_final(self):
        for plugin_id, priority, strategy, suffix in [('first',10,'MODIFY_FINAL','!'),('second',0,'MODIFY','?')]:
            self.install(plugin(f"class TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_on_send_message_hook(priority={priority})\n def on_send_message_hook(self, account, params):\n  params.message += {suffix!r}\n  return HookResult(strategy=HookStrategy.{strategy}, params=params)\n", plugin_id))
        self.assertEqual(self.outgoing('hi')['text'], 'hi!')
    def test_exception_restores_text_discards_actions_and_disables(self):
        source = plugin("from client_utils import send_text\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_on_send_message_hook()\n def on_send_message_hook(self, account, params):\n  params.message = 'bad'\n  send_text(params.peer, 'must not send')\n  raise ValueError('broken')\n")
        self.install(source)
        result = self.outgoing('original')
        self.assertEqual(result['text'], 'original');self.assertFalse(result['actions'])
        self.assertFalse(self.call('list')['plugins'][0]['enabled'])
        self.assertIn('broken', self.call('list')['plugins'][0]['error'])
    def test_timeout_disables_looping_plugin(self):
        self.install(plugin("class TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_on_send_message_hook()\n def on_send_message_hook(self, account, params):\n  while True: pass\n"))
        self.assertEqual(self.outgoing('safe')['text'], 'safe')
        self.assertIn('exceeded', self.call('list')['plugins'][0]['error'])
    def test_incoming_send_and_message_menu(self):
        source = plugin("from base_plugin import MenuItemData, MenuItemType\nfrom client_utils import send_text\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self):\n  self.add_hook('TL_updateNewMessage')\n  self.add_menu_item(MenuItemData(menu_type=MenuItemType.MESSAGE_CONTEXT_MENU, text='Echo', on_click=self.click))\n def on_update_hook(self, name, account, update):\n  send_text(update.message.getDialogId(), update.message.message)\n  return HookResult()\n def click(self, ctx):\n  send_text(ctx['dialog_id'], ctx['message'].messageText)\n")
        self.install(source)
        event = self.call('update', name='TL_updateNewMessage', peer='123', update={'message':{'id':1,'dialog_id':123,'message':'hello'}})
        self.assertEqual(event['actions'][0]['text'], 'hello');self.assertEqual(event['actions'][0]['account'], 42)
        menu = self.call('menus')['menus'][0]
        result = self.call('menu', id='test_plugin', menu=menu['id'], peer='123', context={'dialog_id':123}, message={'messageText':'menu hello'})
        self.assertEqual(result['actions'][0]['text'], 'menu hello')
    def test_accounts_do_not_share_settings(self):
        self.install(host.SAMPLE)
        self.call('settings', id='hello_world');self.call('setting', id='hello_world', index=1, value='A {name}')
        other = self.root;self.root = Path(self.temp.name)/'other'
        try:
            self.install(host.SAMPLE)
            self.assertEqual(self.outgoing('.hello X')['text'], 'Hello, X!')
            self.call('close')
        finally: self.root = other
        self.assertEqual(self.outgoing('.hello X')['text'], 'A X')
    def make_elyx(self, members):
        path = Path(self.temp.name)/'test.elyx'
        with zipfile.ZipFile(path, 'w') as z:
            for name, text in members.items(): z.writestr(name, text)
        return path
    def test_elyx_sources_relative_import_assets_and_locale(self):
        archive = self.make_elyx({'refmap.yml':'main: plugin/src/main.py\nmetainfo: plugin/meta.json\nassets: plugin/res\nstrings: plugin/locales\n',
            'plugin/meta.json':json.dumps({'id':'elyx_test','name':'Elyx Test'}),
            'plugin/src/main.py':"from base_plugin import BasePlugin, HookResult, HookStrategy\nfrom elyx import assets, strings\nfrom .helper import prefix\nclass ElyxTest(BasePlugin):\n def on_plugin_load(self):\n  self.add_on_send_message_hook()\n  self.label = assets['label.txt'].content_string() + strings('hello') + prefix\n def on_send_message_hook(self, account, params):\n  params.message = self.label\n  return HookResult(strategy=HookStrategy.MODIFY, params=params)\n",
            'plugin/src/helper.py':"prefix = '!'\n",'plugin/res/label.txt':'Asset ', 'plugin/locales/strings_en.json':'{"hello":"Hello"}'})
        result = self.call('install', path=str(archive), adapt=False)
        self.assertTrue(result.get('installed'), result)
        self.assertFalse(self.call('enable', id='elyx_test', enabled=True).get('error'))
        self.assertEqual(self.outgoing('x')['text'], 'Asset Hello!')
    def test_archive_traversal_rejected(self):
        archive = self.make_elyx({'../escape.py':'pass'})
        self.assertIn('Invalid', self.call('inspect', path=str(archive))['error'])
        self.assertFalse((Path(self.temp.name)/'escape.py').exists())
    def test_dependency_constraints_and_delete_cleanup(self):
        source = plugin("__requirements__ = ['requests>=2.32', 'packaging==25.0']\nclass TestPlugin(BasePlugin): pass\n")
        self.install(source)
        self.call('delete', id='test_plugin')
        self.assertFalse((self.root/'test_plugin').exists())
        source = source.replace('requests>=2.32', 'requests>=99')
        self.source.write_text(source)
        self.assertTrue(self.call('inspect', path=str(self.source))['report']['issues'])

    def test_formatted_send_edit_and_native_peer_context(self):
        self.install(plugin("from client_utils import send_text, edit_message, get_selected_account\nfrom types import SimpleNamespace\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_on_send_message_hook()\n def on_send_message_hook(self, account, params):\n  assert get_selected_account() == account\n  send_text(params.peer, '😀 <b>bold</b>', parse_mode='html')\n  edit_message(SimpleNamespace(getDialogId=lambda: params.peer, getId=lambda: 7), text='**edited**', parse_mode='markdown')\n  return HookResult(strategy=HookStrategy.CANCEL)\n"))
        result = self.call('outgoing', text='command', peer='123', native_peer='native-123')
        self.assertTrue(result['cancel'])
        send, edit = result['actions']
        self.assertEqual(send['text'], '😀 bold')
        self.assertEqual(send['entities'][0]['offset'], 3)
        self.assertEqual(send['entities'][0]['length'], 4)
        self.assertEqual(send['native_peer'], 'native-123')
        self.assertEqual(edit['type'], 'edit');self.assertEqual(edit['id'], 7)
        self.assertEqual(edit['text'], 'edited');self.assertEqual(edit['entities'][0]['type'], 'bold')

    def test_outgoing_formatted_entities_and_rollback(self):
        self.install(plugin("from extera_utils.text_formatting import parse_text\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_on_send_message_hook()\n def on_send_message_hook(self, account, params):\n  parsed = parse_text('<i>😀 hi</i>')\n  params.message = parsed['message']\n  params.entities = parsed['entities']\n  return HookResult(strategy=HookStrategy.MODIFY, params=params)\n", 'format_first'))
        self.install(plugin("class TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_on_send_message_hook(priority=-1)\n def on_send_message_hook(self, account, params):\n  params.entities = []\n  params.message = 'discard'\n  return HookResult()\n", 'rollback_second'))
        result = self.outgoing('x')
        self.assertEqual(result['text'], '😀 hi')
        self.assertEqual(result['entities'][0]['length'], 5)
        self.assertEqual(result['entities'][0]['type'], 'italic')

    def test_utf16_entity_validation_rejects_split_emoji(self):
        from extera_utils.text_formatting import serialize_entities
        with self.assertRaises(ValueError): serialize_entities([{'type':'bold', 'offset':1, 'length':1}], '😀')
        with self.assertRaises(ValueError): serialize_entities([{'type':'bold', 'offset':0, 'length':3}], '😀')

    def test_html_nested_escaped_code_and_custom_emoji(self):
        from extera_utils.text_formatting import parse_text, serialize_entities
        result = parse_text('😀 <b>x<i>y</i></b> &amp; <pre><code class="language-python">a &lt; b</code></pre><emoji id="123">🦊</emoji>')
        self.assertEqual(result['message'], '😀 xy & a < b🦊')
        entities = serialize_entities(result['entities'], result['message'])
        self.assertEqual([(e['type'], e['offset'], e['length']) for e in entities[:2]], [('bold',3,2),('italic',4,1)])
        self.assertEqual(next(e for e in entities if e['type']=='pre')['language'], 'python')
        self.assertEqual(entities[-1]['document_id'], 123)

    def test_markdown_does_not_format_inside_code(self):
        from extera_utils.text_formatting import parse_text, serialize_entities
        result = parse_text(r'**bold** `*literal*` \*escaped\* [link](https://example.com)', 'Markdown')
        self.assertEqual(result['message'], 'bold *literal* *escaped* link')
        self.assertEqual([e['type'] for e in serialize_entities(result['entities'], result['message'])], ['bold','code','text_link'])

    def test_scheduled_overflow_is_not_dropped(self):
        self.install(plugin("from client_utils import send_text\nfrom android_utils import run_on_ui_thread\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self):\n  for i in range(40): run_on_ui_thread(lambda i=i: send_text(123, str(i)))\n"))
        first = self.call('tick')['actions'];second = self.call('tick')['actions']
        self.assertEqual(len(first), 32);self.assertEqual(len(second), 8)
        self.assertEqual({int(a['text']) for a in first+second}, set(range(40)))

    def test_runnable_cancel_and_stop_event(self):
        self.install(plugin("from android_utils import R\nfrom client_utils import get_queue_by_name, PLUGINS_QUEUE, send_text\nfrom base_plugin import AppEvent\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self):\n  q = get_queue_by_name(PLUGINS_QUEUE)\n  r = R(lambda: send_text(123, 'cancelled'))\n  q.postRunnable(r)\n  q.cancelRunnable(r)\n def on_app_event(self, event):\n  if event == AppEvent.STOP: self.set_setting('stopped', True)\n"))
        self.assertFalse(self.call('tick')['actions'])
        self.call('enable', id='test_plugin', enabled=False)
        self.assertTrue(json.loads((self.root/'settings.json').read_text())['test_plugin']['stopped'])

    def test_multiline_settings_limits_mask_and_long_press(self):
        self.install(plugin("from ui.settings import EditText, Text\nclass TestPlugin(BasePlugin):\n def create_settings(self):\n  return [EditText(key='text', hint='Value', multiline=True, max_length=4, mask='[a-z\\n]*'), Text(text='Hold', on_long_click=lambda v: self.set_setting('held', True))]\n"))
        rows = self.call('settings', id='test_plugin')['rows']
        self.assertTrue(rows[0]['multiline']);self.assertEqual(rows[0]['max_length'], 4)
        self.assertNotIn('error', self.call('setting', id='test_plugin', index=0, value='a\nb'))
        self.assertIn('error', self.call('setting', id='test_plugin', index=0, value='abcde'))
        self.assertIn('error', self.call('setting', id='test_plugin', index=0, value='123'))
        self.call('long_press', id='test_plugin', index=1)
        self.assertTrue(json.loads((self.root/'settings.json').read_text())['test_plugin']['held'])

    def test_all_telegram_constructors_roundtrip(self):
        from aftergram_tl import SCHEMA, native_fixtures, encode, decode
        self.assertEqual(sum(bool(m.get('function')) for m in SCHEMA), 840)
        fixtures = native_fixtures();self.assertEqual(len(fixtures), 1700)
        for item in fixtures:
            with self.subTest(name=item['name']): self.assertEqual(encode(decode(item['payload'])), item['payload'])

    def test_telegram_flags_namespace_and_malformed_response(self):
        from aftergram_tl import TLRPC, encode, decode, deserialize
        from org.telegram.tgnet.tl import TL_messages
        request = TL_messages.sendMessage(peer=TLRPC.TL_inputPeerSelf(), message='hi', random_id=123, silent=True)
        decoded = decode(encode(request))
        self.assertTrue(decoded.silent)
        self.assertEqual(decoded.getClass().getSimpleName(), 'TL_messages_sendMessage')
        self.assertTrue(TLRPC.InputPeer.class_.isAssignableFrom(TLRPC.TL_inputPeerSelf))
        with self.assertRaises(ValueError): deserialize(b'\0')
        with self.assertRaises(ValueError): deserialize(b'\xff' * 4)
        with self.assertRaises(TypeError): encode(TLRPC.TL_messages_getHistory(peer=TLRPC.TL_boolTrue()))

    def test_request_hooks_pre_cancel_modify_and_post(self):
        from aftergram_tl import TLRPC, encode, decode
        self.install(plugin("from org.telegram.tgnet import TLRPC\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self):\n  self.add_hook('TL_account_updateStatus')\n  self.add_hook('TL_messages_setTyping')\n def pre_request_hook(self, name, account, request):\n  if name.endswith('setTyping'): return HookResult(strategy=HookStrategy.CANCEL)\n  request.offline = True\n  return HookResult(strategy=HookStrategy.MODIFY, request=request)\n def post_request_hook(self, name, account, response, error):\n  return HookResult(strategy=HookStrategy.MODIFY_FINAL, response=TLRPC.TL_boolFalse())\n"))
        response = self.call('request_hook', name='account.updateStatus', stage='pre', payload=encode(TLRPC.TL_account_updateStatus(offline=False)))
        self.assertIsInstance(decode(response['payload']).offline, TLRPC.TL_boolTrue)
        response = self.call('request_hook', name='messages.setTyping', stage='pre', payload=encode(TLRPC.TL_messages_setTyping(peer=TLRPC.TL_inputPeerSelf(), action=TLRPC.TL_sendMessageTypingAction())))
        self.assertTrue(response['cancel'])
        response = self.call('request_hook', name='account.updateStatus', stage='post', payload=encode(TLRPC.TL_boolTrue()))
        self.assertIsInstance(decode(response['payload']), TLRPC.TL_boolFalse)

    def test_failed_request_hook_restores_original_packet(self):
        from aftergram_tl import TLRPC, encode
        self.install(plugin("class TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_hook('TL_account_updateStatus')\n def pre_request_hook(self, name, account, request):\n  request.offline = True\n  raise ValueError('hook failed')\n"))
        original = encode(TLRPC.TL_account_updateStatus(offline=False))
        response = self.call('request_hook', name='account.updateStatus', stage='pre', payload=original)
        self.assertEqual(response['payload'],original)
        self.assertFalse(self.call('list')['plugins'][0]['enabled'])

    def test_rpc_callback_scope_and_disable_cleanup(self):
        from aftergram_tl import TLRPC, encode
        self.install(plugin("from org.telegram.tgnet import TLRPC\nfrom client_utils import send_request, send_text\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_on_send_message_hook()\n def on_send_message_hook(self, account, params):\n  send_request(TLRPC.TL_help_getNearestDc(), lambda response,error: send_text(params.peer,response.country if not error else error.text))\n  return HookResult(strategy=HookStrategy.CANCEL)\n"))
        action = self.call('outgoing',text='rpc',peer='123',native_peer='native-peer')['actions'][0]
        response = self.call('rpc_result',callback=action['callback'],payload=encode(TLRPC.TL_nearestDc(country='US',this_dc=2,nearest_dc=2)))
        self.assertEqual(response['actions'][0]['text'],'US')
        self.assertEqual(response['actions'][0]['native_peer'],'native-peer')
        action = self.outgoing('rpc')['actions'][0]
        response = self.call('rpc_result',callback=action['callback'],error={'code':400,'text':'TEST_ERROR'})
        self.assertEqual(response['actions'][0]['text'],'TEST_ERROR')
        action = self.outgoing('rpc')['actions'][0]
        self.call('enable',id='test_plugin',enabled=False)
        self.assertFalse(self.call('list')['callbacks'])
        self.assertFalse(self.call('rpc_result',callback=action['callback'],error={'code':400,'text':'late'})['actions'])

    def test_native_dialog_form_callback_and_disable(self):
        self.install(plugin("from ui.alert import AlertDialogBuilder\nfrom client_utils import get_last_fragment, send_text\nfrom android.widget import EditText\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self):\n  ctx = get_last_fragment().getParentActivity()\n  self.field = EditText(ctx)\n  self.field.setHint('Name')\n  self.dialog = AlertDialogBuilder(ctx).set_title('Hello').set_view(self.field).set_positive_button('Send',self.click).show()\n def click(self,builder,which): send_text(123,self.field.getText().toString())\n"),adapt=True)
        ids = self.call('list')['dialogs'];self.assertEqual(len(ids),1)
        response = self.call('dialog_event',dialog=ids[0],event='button',which=-1,values=['iPhone'])
        self.assertEqual(response['actions'][0]['text'],'iPhone')
        self.assertFalse(self.call('list')['dialogs'])
        self.call('enable',id='test_plugin',enabled=True)
        self.assertTrue(self.call('list')['dialogs'])
        self.call('enable',id='test_plugin',enabled=False)
        self.assertFalse(self.call('list')['dialogs'])

    def test_account_and_peer_helpers_use_native_snapshots(self):
        from aftergram_tl import TLRPC, encode
        self.install(plugin("from client_utils import get_user_config, get_messages_controller\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_on_send_message_hook()\n def on_send_message_hook(self, account, params):\n  config = get_user_config()\n  assert config.getClientUserId() == 111\n  assert config.getCurrentUser().first_name == 'Tester'\n  assert get_messages_controller().getInputPeer(params.peer).access_hash == 456\n  params.message = 'snapshots ok'\n  return HookResult(strategy=HookStrategy.MODIFY,params=params)\n"))
        response = self.call('outgoing',peer='123',text='x',self_id=111,self_user={'_':'user','id':111,'first_name':'Tester'},peer_wire=encode(TLRPC.TL_inputPeerUser(user_id=123,access_hash=456)))
        self.assertEqual(response['text'],'snapshots ok')

    def test_media_send_validates_file_and_emits_caption_entities(self):
        media = Path(self.temp.name)/'photo.png';media.write_bytes(b'example')
        self.install(plugin(f"from client_utils import send_photo\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_on_send_message_hook()\n def on_send_message_hook(self, account, params):\n  send_photo(params.peer,{str(media)!r},caption='<b>caption</b>',parse_mode='HTML')\n  return HookResult(strategy=HookStrategy.CANCEL)\n"))
        action = self.outgoing('photo')['actions'][0]
        self.assertEqual(action['media']['kind'],'photo')
        self.assertEqual(action['text'],'caption')
        self.assertEqual(action['entities'][0]['type'],'bold')
        media.unlink()
        self.assertFalse(self.outgoing('missing')['actions'])

    def test_background_io_does_not_block_foreground_and_preserves_scope(self):
        self.install(plugin("import time\nfrom client_utils import run_on_queue, send_text, get_selected_account\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_on_send_message_hook()\n def on_send_message_hook(self, account, params):\n  run_on_queue(lambda: self.task(params.peer))\n  return HookResult()\n def task(self,peer):\n  time.sleep(0.4)\n  assert get_selected_account() == 42\n  send_text(peer,'background done')\n"))
        self.call('outgoing',text='hi',peer='123',native_peer='native-123')
        started = time.monotonic();self.call('tick')
        self.assertLess(time.monotonic()-started,0.2)
        self.assertEqual(self.call('list')['plugins'][0]['enabled'],True)
        actions = []
        deadline = time.monotonic()+3
        while not actions and time.monotonic() < deadline:
            time.sleep(0.01);actions.extend(self.call('tick')['actions'])
        self.assertEqual(actions[0]['text'],'background done')
        self.assertEqual(actions[0]['native_peer'],'native-123')

    def test_disabling_plugin_discards_late_background_actions(self):
        self.install(plugin("import time\nfrom client_utils import run_on_queue, send_text\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self): run_on_queue(self.task)\n def task(self):\n  time.sleep(0.1)\n  send_text(123,'must be discarded')\n"))
        self.call('tick');self.call('enable',id='test_plugin',enabled=False)
        time.sleep(0.15)
        self.assertFalse(self.call('tick')['actions'])

if __name__ == '__main__': unittest.main()
