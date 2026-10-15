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
