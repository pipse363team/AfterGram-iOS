class Array:
    @staticmethod
    def getLength(value): return len(value)
    @staticmethod
    def get(value, index): return value[index]

class Modifier:
    PUBLIC = 1
    PRIVATE = 2
    STATIC = 8
    FINAL = 16
