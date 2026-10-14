"""Supported exteraGram API surface, implemented by the AfterGram iOS host."""
from dataclasses import dataclass
from enum import Enum
import logging

class HookStrategy(Enum):
    DEFAULT = 0
    CANCEL = 1
    MODIFY = 2
    MODIFY_FINAL = 3

@dataclass
class HookResult:
    strategy: HookStrategy = HookStrategy.DEFAULT
    request: object = None
    response: object = None
    update: object = None
    updates: object = None
    params: object = None

class AppEvent(Enum):
    START = 0
    STOP = 1
    PAUSE = 2
    RESUME = 3

class MenuItemType(Enum):
    MESSAGE_CONTEXT_MENU = 'message'
    MAIN_MENU = 'main'
    DRAWER_MENU = 'main'
    CHAT_ACTION_MENU = 'chat'
    PROFILE_ACTION_MENU = 'profile'

@dataclass
class MenuItemData:
    menu_type: MenuItemType
    text: str
    on_click: object
    item_id: str = None
    icon: str = None
    subtext: str = None
    condition: str = None
    priority: int = 0

class BasePlugin:
    def __init__(self):
        from aftergram_host import current
        context = current()
        self._attach(context['host'], context['plugin'])
    def _attach(self, host, plugin_id):
        self._host = host
        self.id = plugin_id
        self.plugin_id = plugin_id
        self.logger = logging.getLogger('plugin.' + plugin_id)
        self._send_priority = None
        self._hooks = []
        self._menus = {}
        self._rows = []
    def on_plugin_load(self): pass
    def on_plugin_unload(self): pass
    def on_app_event(self, event_type): pass
    def create_settings(self): return []
    def on_send_message_hook(self, account, params): return HookResult()
    def on_update_hook(self, update_name, account, update): return HookResult()
    def on_updates_hook(self, container_name, account, updates): return HookResult()
    def add_on_send_message_hook(self, priority=0): self._send_priority = int(priority)
    def add_hook(self, name, match_substring=False, priority=0):
        # Incoming message notifications are read-only. Request replacement is not emulated.
        supported = {'TL_updateNewMessage', 'TL_updateNewChannelMessage'}
        if not (name in supported or (match_substring and any(name in event for event in supported))):
            raise NotImplementedError('Unsupported event or raw request hook on iOS: ' + name)
        self._hooks.append((name, bool(match_substring), int(priority)))
    def get_setting(self, key, default=None): return self._host.settings[self.id].get(key, default)
    def set_setting(self, key, value, reload_settings=False):
        self._host.settings[self.id][key] = value
        self._host.save_settings()
    def export_settings(self): return dict(self._host.settings[self.id])
    def import_settings(self, settings, reload_settings=True):
        self._host.settings[self.id].update(settings)
        self._host.save_settings()
    def add_menu_item(self, item):
        if item.menu_type not in (MenuItemType.MESSAGE_CONTEXT_MENU, MenuItemType.MAIN_MENU):
            raise NotImplementedError('Only message and main plugin menus are currently supported')
        if item.condition:
            raise NotImplementedError('Java/MVEL menu conditions need manual adaptation')
        key = item.item_id or str(len(self._menus))
        self._menus[key] = item
        return key
    def remove_menu_item(self, item_id): self._menus.pop(item_id, None)
    def client(self, account=None):
        from client_utils import AccountClient
        return AccountClient(account)
    def log(self, message): self.logger.info(message)
    def hook_method(self, *args, **kwargs): raise NotImplementedError('Xposed is not available on iOS')
