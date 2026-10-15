class Integer(int):
    @classmethod
    def valueOf(cls, value): return cls(value)
    def intValue(self): return int(self)
class Long(Integer):
    def longValue(self): return int(self)
class String(str):
    def toString(self): return str(self)
    def length(self): return len(self)
class Object: pass
class Double(float):
    def doubleValue(self): return float(self)
class Boolean:
    def __init__(self, value=False): self.value = bool(value)
    def __bool__(self): return self.value
    def booleanValue(self): return self.value
