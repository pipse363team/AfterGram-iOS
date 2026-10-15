from aftergram_host import current
from android_utils import run_on_ui_thread
class AndroidUtilities:
    runOnUIThread = staticmethod(run_on_ui_thread)
    @staticmethod
    def dp(value): return float(value)
    @staticmethod
    def cancelRunOnUIThread(fn):
        from client_utils import get_queue_by_name, PLUGINS_QUEUE
        get_queue_by_name(PLUGINS_QUEUE).cancelRunnable(fn)
class _UserConfigMeta(type):
    @property
    def selectedAccount(cls): return current()['account']
class UserConfig(metaclass=_UserConfigMeta):
    @staticmethod
    def getInstance(account):
        from client_utils import get_user_config
        return get_user_config(account)
class MessagesController:
    @staticmethod
    def getInstance(account):
        from client_utils import get_messages_controller
        return get_messages_controller(account)
class ConnectionsManager:
    @staticmethod
    def getInstance(account):
        from client_utils import get_connections_manager
        return get_connections_manager(account)
class ApplicationLoader:
    from aftergram_ui import NativeContext
    applicationContext = NativeContext()

class LocaleController:
    @staticmethod
    def getString(key, resource_id=None): return str(resource_id or key)
    @staticmethod
    def getInstance(): return LocaleController()
    @property
    def isRTL(self): return False
    @property
    def currentLocale(self): return 'en'

class NotificationCenter:
    MESSAGE_RECEIVED = 'message_received'
    MESSAGE_EDITED = 'message_edited'
    MESSAGE_DELETED = 'message_deleted'
    @staticmethod
    def getInstance(account=0): return NotificationCenter()
    def addObserver(self, *args): raise NotImplementedError('Telegram UI notifications require a native plugin event hook')
    def removeObserver(self, *args): return None

class FileLoader:
    @staticmethod
    def getInstance(account=0): return FileLoader()
    def getPathToAttach(self, *args, **kwargs): raise NotImplementedError('Android media paths are not available on iOS')
    def isLoadingFile(self, *args, **kwargs): return False

class BuildVars:
    DEBUG_VERSION = False
    APP_VERSION_STRING = 'AfterGram iOS'
    APP_VERSION = 1300

class SendMessagesHelper: pass
class MessageObject: pass
class MediaController: pass
class ChatObject: pass
class R:
    class drawable: pass
    class string: pass
    class color: pass
