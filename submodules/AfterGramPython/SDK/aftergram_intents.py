from urllib.parse import urlsplit

class Uri(str):
    @classmethod
    def parse(cls, value): return cls(value)
    def getScheme(self): return urlsplit(self).scheme
    def getHost(self): return urlsplit(self).hostname
    def getPath(self): return urlsplit(self).path
    def toString(self): return str(self)

class Intent:
    ACTION_VIEW = 'android.intent.action.VIEW'
    ACTION_SEND = 'android.intent.action.SEND'
    EXTRA_TEXT = 'android.intent.extra.TEXT'
    FLAG_ACTIVITY_NEW_TASK = 0x10000000
    CATEGORY_BROWSABLE = 'android.intent.category.BROWSABLE'
    def __init__(self, action=None, uri=None):
        self.action = action;self.data = uri;self.extras = {};self.flags = 0;self.type = None
    def setAction(self, value): self.action = value;return self
    def getAction(self): return self.action
    def setData(self, value): self.data = value;return self
    def getData(self): return self.data
    def setType(self, value): self.type = value;return self
    def addFlags(self, value): self.flags |= int(value);return self
    def putExtra(self, key, value): self.extras[key] = value;return self
    @staticmethod
    def createChooser(intent, title): intent.title = str(title);return intent

class Context:
    def startActivity(self, intent):
        from aftergram_host import emit
        if intent.action == Intent.ACTION_VIEW:
            value = str(intent.data)
            if urlsplit(value).scheme.lower() not in {'https','http','tg','mailto'}: raise ValueError('Unsupported URL scheme')
            emit({'type':'open_url','url':value})
        elif intent.action == Intent.ACTION_SEND and isinstance(intent.extras.get(Intent.EXTRA_TEXT),str):
            emit({'type':'share','text':intent.extras[Intent.EXTRA_TEXT]})
        else: raise NotImplementedError('This Android intent has no iOS equivalent')
    def getApplicationContext(self): return self
