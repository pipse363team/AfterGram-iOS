#import "AGPythonRuntime.h"
#import <Python/Python.h>

@interface AGPythonRuntime ()
+ (NSString *)executeJSON:(NSString *)request;
@end

@implementation AGPythonRuntime
+ (NSString *)dispatchJSON:(NSString *)request {
    @synchronized (self) { return [self executeJSON:request]; }
}
+ (NSString *)executeJSON:(NSString *)request {
    // The Swift host serializes initialization and all calls on one dedicated queue.
    static BOOL attempted = NO;
    static NSString *startupError = nil;
    if (!attempted) {
        attempted = YES;
        NSString *bundlePath = [NSBundle.mainBundle pathForResource:@"AfterGramPython" ofType:@"bundle"];
        if (!bundlePath) bundlePath = [[NSBundle bundleForClass:self] pathForResource:@"AfterGramPython" ofType:@"bundle"];
        NSBundle *resources = bundlePath ? [NSBundle bundleWithPath:bundlePath] : nil;
        NSString *stdlib = [resources pathForResource:@"python311" ofType:@"zip"];
        NSString *sdk = [resources pathForResource:@"aftergram_sdk" ofType:@"zip"];
        if (!stdlib || !sdk) {
            startupError = @"Python resources are missing from the app bundle";
        } else {
            PyPreConfig preconfig;
            PyPreConfig_InitIsolatedConfig(&preconfig);
            preconfig.utf8_mode = 1;
            PyStatus status = Py_PreInitialize(&preconfig);
            if (!PyStatus_Exception(status)) {
                PyConfig config;
                PyConfig_InitIsolatedConfig(&config);
                config.install_signal_handlers = 0;
                config.write_bytecode = 0;
                config.module_search_paths_set = 1;
                wchar_t *libPath = Py_DecodeLocale(stdlib.UTF8String, NULL);
                wchar_t *sdkPath = Py_DecodeLocale(sdk.UTF8String, NULL);
                if (!libPath || !sdkPath) {
                    status = PyStatus_Error("Cannot decode Python paths");
                } else {
                    status = PyWideStringList_Append(&config.module_search_paths, libPath);
                    if (!PyStatus_Exception(status)) status = PyWideStringList_Append(&config.module_search_paths, sdkPath);
                    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
                }
                PyMem_RawFree(libPath);
                PyMem_RawFree(sdkPath);
                PyConfig_Clear(&config);
            }
            if (PyStatus_Exception(status)) {
                startupError = status.err_msg ? [NSString stringWithUTF8String:status.err_msg] : @"Python initialization failed";
            } else {
                // The extension loader uses the signed frameworks embedded by Bazel.
                NSString *manifest = [resources pathForResource:@"native-modules" ofType:@"json"];
                NSString *map = [NSString stringWithContentsOfFile:manifest encoding:NSUTF8StringEncoding error:nil];
                NSString *frameworkDir = NSBundle.mainBundle.privateFrameworksPath;
                if (!map || !frameworkDir) {
                    startupError = @"Python native module manifest is missing";
                    PyEval_SaveThread();
                    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"error": startupError} options:0 error:nil];
                    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                }
                PyObject *globals = PyModule_GetDict(PyImport_AddModule("__main__"));
                PyObject *dir = PyUnicode_FromString(frameworkDir.UTF8String);
                PyObject *modules = PyUnicode_FromString(map.UTF8String);
                PyDict_SetItemString(globals, "_ag_framework_dir", dir);
                PyDict_SetItemString(globals, "_ag_module_map", modules);
                Py_XDECREF(dir);
                Py_XDECREF(modules);
                const char *setup =
                    "import sys, _frozen_importlib_external as _ext\n"
                    "# Parse the flat manifest without importing json before native loaders exist.\n"
                    "import ast\n"
                    "_ag_native = ast.literal_eval(_ag_module_map)\n"
                    "class _AGNativeFinder:\n"
                    " def find_spec(self, fullname, path=None, target=None):\n"
                    "  fw = _ag_native.get(fullname)\n"
                    "  if fw:\n"
                    "   binary = _ag_framework_dir + '/' + fw + '.framework/' + fw\n"
                    "   return _ext.spec_from_file_location(fullname, binary, loader=_ext.ExtensionFileLoader(fullname, binary))\n"
                    "sys.meta_path.insert(0, _AGNativeFinder())\n";
                // ast itself only needs the built-in _ast module.
                if (PyRun_SimpleString(setup) != 0) startupError = @"Python native module loader failed";
                PyEval_SaveThread();
            }
        }
    }
    if (startupError) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"error": startupError} options:0 error:nil];
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *module = PyImport_ImportModule("aftergram_host");
    PyObject *method = module ? PyObject_GetAttrString(module, "dispatch") : NULL;
    PyObject *arg = PyUnicode_FromString(request.UTF8String);
    PyObject *result = method ? PyObject_CallFunctionObjArgs(method, arg, NULL) : NULL;
    NSString *output = nil;
    if (result && PyUnicode_Check(result)) {
        const char *utf8 = PyUnicode_AsUTF8(result);
        if (utf8) output = [NSString stringWithUTF8String:utf8];
    }
    if (!output) {
        PyErr_Print();
        output = @"{\"error\":\"Python host call failed; see device log\"}";
    }
    Py_XDECREF(result); Py_XDECREF(arg); Py_XDECREF(method); Py_XDECREF(module);
    PyGILState_Release(gil);
    return output;
}
@end
