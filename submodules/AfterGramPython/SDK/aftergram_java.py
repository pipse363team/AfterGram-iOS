class Integer(int):
    @classmethod
    def valueOf(cls, value): return cls(value)
    def intValue(self): return int(self)
class Long(Integer):
    def longValue(self): return int(self)
class String(str): pass
