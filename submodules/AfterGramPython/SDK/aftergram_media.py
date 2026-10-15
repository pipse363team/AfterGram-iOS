class AudioManager:
    STREAM_MUSIC = 3
    STREAM_RING = 2
    @staticmethod
    def getStreamMaxVolume(stream): return 0
    @staticmethod
    def getStreamVolume(stream): return 0

class MediaPlayer:
    def __init__(self, *args, **kwargs): raise NotImplementedError('Android MediaPlayer has no iOS equivalent')
