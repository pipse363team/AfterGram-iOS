import json
from pathlib import Path
import sys
import tempfile
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
        self.source.write_text(plugin("from android.widget import LinearLayout\nclass TestPlugin(BasePlugin):\n def on_plugin_load(self): self.add_hook('TL_messages_setTyping')\n"))
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

if __name__ == '__main__': unittest.main()
