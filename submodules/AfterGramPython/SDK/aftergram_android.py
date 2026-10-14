from aftergram_host import current
from android_utils import run_on_ui_thread
class AndroidUtilities:
    runOnUIThread = staticmethod(run_on_ui_thread)
    @staticmethod
    def dp(value): return float(value)
class _UserConfigMeta(type):
    @property
    def selectedAccount(cls): return current()['account']
class UserConfig(metaclass=_UserConfigMeta): pass
