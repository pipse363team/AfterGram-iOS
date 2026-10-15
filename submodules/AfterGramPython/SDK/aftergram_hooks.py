class MethodHook:
    def beforeHookedMethod(self, param): pass
    def afterHookedMethod(self, param): pass

def _unsupported(name):
    raise NotImplementedError(name + ' requires Android runtime method interception, which iOS does not provide')

def find_class(name): return None
def hook_all_methods(*args, **kwargs): return _unsupported('hook_all_methods')
def hook_all_constructors(*args, **kwargs): return _unsupported('hook_all_constructors')

def get_private_field(instance, name, *args):
    if instance is None: return None
    return getattr(instance, str(name), None)

def set_private_field(instance, name, value, *args):
    if instance is None: return False
    setattr(instance, str(name), value)
    return True

def find_constructor_exact(*args, **kwargs): return None
def find_method_exact(*args, **kwargs): return None
def get_java_class(name): return None
