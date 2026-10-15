from android_utils import run_on_ui_thread

class Handler:
    def __init__(self, looper=None): self.looper = looper
    def post(self, runnable): run_on_ui_thread(runnable);return True
    def postDelayed(self, runnable, delay): run_on_ui_thread(runnable, delay);return True
    def removeCallbacks(self, runnable):
        from client_utils import get_queue_by_name, PLUGINS_QUEUE
        get_queue_by_name(PLUGINS_QUEUE).cancelRunnable(runnable)

class Looper:
    @staticmethod
    def getMainLooper(): return 'main'
    @staticmethod
    def myLooper(): return 'main'

class Build:
    class VERSION:
        SDK_INT = 35
        RELEASE = 'iOS'

class Bundle(dict):
    def putString(self, key, value): self[key] = str(value)
    def getString(self, key, default=None): return self.get(key, default)
    def putInt(self, key, value): self[key] = int(value)
    def getInt(self, key, default=0): return int(self.get(key, default))

class SystemClock:
    @staticmethod
    def uptimeMillis():
        import time
        return int(time.monotonic() * 1000)
    elapsedRealtime = uptimeMillis

class Environment:
    @staticmethod
    def getExternalStorageDirectory():
        from pathlib import Path
        return Path.home()
