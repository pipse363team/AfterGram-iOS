load("@rules_cc//cc:objc_library.bzl", "objc_library")
objc_library(
    name = "AfterGramPython",
    module_name = "AfterGramPython",
    enable_modules = True,
    srcs = ["Sources/AGPythonRuntime.m"],
    hdrs = ["PublicHeaders/AGPythonRuntime.h"],
    includes = ["PublicHeaders"],
    sdk_frameworks = ["Foundation"],
    deps = ["@aftergram_python//:runtime", "@aftergram_python//:extensions"],
    data = ["@aftergram_python//:stdlib"],
    visibility = ["//visibility:public"],
)
