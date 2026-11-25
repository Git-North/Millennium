#ifdef __APPLE__
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <libgen.h>
#include <os/lock.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <atomic>
#include <string>
#include <vector>
#include "pipe_bootstrap.h"

typedef int (*start_millennium_t)(void);
typedef int (*stop_millennium_t)(void);

extern char** environ;

namespace
{
constexpr const char* kRuntimePathEnv = "MILLENNIUM_RUNTIME_PATH";
constexpr const char* kChildHookPathEnv = "MILLENNIUM_CHILD_HOOK_PATH";
constexpr const char* kSteamExecutableEnv = "MILLENNIUM_STEAM_EXECUTABLE";
constexpr const char* kBootstrapTraceEnv = "MILLENNIUM_BOOTSTRAP_TRACE_PATH";
} // namespace

#define DYLD_INTERPOSE(_replacement, _replacee)                                                                                                                                    \
    __attribute__((used)) static struct                                                                                                                                            \
    {                                                                                                                                                                              \
        const void* replacement;                                                                                                                                                   \
        const void* replacee;                                                                                                                                                      \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee }

static void* g_millennium_handle = nullptr;
static bool g_bootstrap_enabled = false;

static bool is_steam_main_process_name(const char* filename)
{
    return strcmp(filename, "steam_osx") == 0 || strcmp(filename, "steam_osx.real") == 0;
}

static bool is_steam_main_process()
{
    char path_buffer[PATH_MAX];
    uint32_t size = sizeof(path_buffer);

    if (_NSGetExecutablePath(path_buffer, &size) != 0) {
        return false;
    }

    char resolved[PATH_MAX];
    if (!realpath(path_buffer, resolved)) {
        return false;
    }

    const char* filename = strrchr(resolved, '/');
    filename = filename ? filename + 1 : resolved;
    return is_steam_main_process_name(filename);
}

static bool get_bootstrap_path(char* output, size_t output_size)
{
    Dl_info info;
    if (!dladdr((void*)get_bootstrap_path, &info) || !info.dli_fname) {
        return false;
    }

    char resolved[PATH_MAX];
    if (!realpath(info.dli_fname, resolved)) {
        return false;
    }

    strncpy(output, resolved, output_size - 1);
    output[output_size - 1] = '\0';
    return true;
}

static bool get_adjacent_or_configured_path(const char* env_name, const char* artifact_name, int access_mode, char* output, size_t output_size)
{
    const char* configured = getenv(env_name);
    if (configured && configured[0] != '\0') {
        char resolved[PATH_MAX];
        if (access(configured, access_mode) == 0 && realpath(configured, resolved)) {
            strncpy(output, resolved, output_size - 1);
            output[output_size - 1] = '\0';
            return true;
        }
        return false;
    }

    char bootstrap_path[PATH_MAX];
    if (!get_bootstrap_path(bootstrap_path, sizeof(bootstrap_path))) {
        return false;
    }

    char bootstrap_dir[PATH_MAX];
    strncpy(bootstrap_dir, bootstrap_path, sizeof(bootstrap_dir) - 1);
    bootstrap_dir[sizeof(bootstrap_dir) - 1] = '\0';

    char* directory = dirname(bootstrap_dir);
    char candidate[PATH_MAX];
    snprintf(candidate, sizeof(candidate), "%s/%s", directory, artifact_name);

    if (access(candidate, access_mode) != 0) {
        return false;
    }

    char resolved[PATH_MAX];
    if (!realpath(candidate, resolved)) {
        return false;
    }

    strncpy(output, resolved, output_size - 1);
    output[output_size - 1] = '\0';
    return true;
}

static const char* get_runtime_path()
{
    static char runtime_path[PATH_MAX];
    static bool initialized = false;

    if (!initialized) {
        if (!get_adjacent_or_configured_path(kRuntimePathEnv, __MILLENNIUM_OUTPUT_NAME__, R_OK, runtime_path, sizeof(runtime_path))) {
            return nullptr;
        }
        initialized = true;
    }

    return runtime_path;
}

static const char* get_child_hook_path()
{
    static char child_hook_path[PATH_MAX];
    static bool initialized = false;

    if (!initialized) {
        if (!get_adjacent_or_configured_path(kChildHookPathEnv, __MILLENNIUM_CHILD_HOOK_OUTPUT_NAME__, R_OK, child_hook_path, sizeof(child_hook_path))) {
            return nullptr;
        }
        initialized = true;
    }

    return child_hook_path;
}

static void append_trace(const char* stage)
{
    const char* trace_path = getenv(kBootstrapTraceEnv);
    if (!trace_path || trace_path[0] == '\0') {
        return;
    }

    FILE* file = fopen(trace_path, "a");
    if (!file) {
        return;
    }

    fprintf(file, "%s\n", stage);
    fclose(file);
}

static void append_exec_trace(const char* stage, const char* path, char* const argv[], const char* note)
{
    const char* trace_path = getenv(kBootstrapTraceEnv);
    if (!trace_path || trace_path[0] == '\0') {
        return;
    }

    const char* arg0 = (argv && argv[0]) ? argv[0] : "";
    FILE* file = fopen(trace_path, "a");
    if (!file) {
        return;
    }

    fprintf(file, "%s|path=%s|arg0=%s|note=%s\n", stage ? stage : "", path ? path : "", arg0, note ? note : "");
    fclose(file);
}

static std::string rewrite_injected_libraries(const std::vector<const char*>& library_paths, const char* removed_path, char* const envp[])
{
    std::vector<std::string> rewritten_entries;
    const char* existing_value = nullptr;
    const char* prefix = "DYLD_INSERT_LIBRARIES=";
    const size_t prefix_length = strlen(prefix);

    const auto append_unique_entry = [&](const char* candidate_path)
    {
        if (!candidate_path || candidate_path[0] == '\0') {
            return;
        }

        const char* normalized_entry = candidate_path;
        char resolved_entry[PATH_MAX];
        if (realpath(candidate_path, resolved_entry)) {
            normalized_entry = resolved_entry;
        }

        if (removed_path && strcmp(normalized_entry, removed_path) == 0) {
            return;
        }

        for (const std::string& existing_entry : rewritten_entries) {
            if (existing_entry == normalized_entry) {
                return;
            }
        }

        rewritten_entries.emplace_back(normalized_entry);
    };

    for (const char* library_path : library_paths) {
        append_unique_entry(library_path);
    }

    char* const* source_env = envp ? envp : environ;
    if (source_env) {
        for (size_t index = 0; source_env[index] != nullptr; ++index) {
            if (strncmp(source_env[index], prefix, prefix_length) == 0) {
                existing_value = source_env[index] + prefix_length;
                break;
            }
        }
    }

    if (existing_value && existing_value[0]) {
        std::string existing(existing_value);
        size_t start = 0;
        while (start <= existing.size()) {
            const size_t end = existing.find(':', start);
            const std::string entry = existing.substr(start, end == std::string::npos ? std::string::npos : end - start);
            append_unique_entry(entry.c_str());

            if (end == std::string::npos) {
                break;
            }
            start = end + 1;
        }
    }

    std::string rewritten;
    for (size_t index = 0; index < rewritten_entries.size(); ++index) {
        if (index != 0) {
            rewritten.append(":");
        }
        rewritten.append(rewritten_entries[index]);
    }

    return rewritten;
}

static std::vector<std::string> build_child_environment(char* const envp[], const std::string& dyld_insert_libraries)
{
    std::vector<std::string> environment;
    char* const* source_env = envp ? envp : environ;

    if (source_env) {
        for (size_t index = 0; source_env[index] != nullptr; ++index) {
            if (strncmp(source_env[index], "DYLD_INSERT_LIBRARIES=", 22) == 0) {
                continue;
            }
            environment.emplace_back(source_env[index]);
        }
    }

    if (!dyld_insert_libraries.empty()) {
        environment.emplace_back("DYLD_INSERT_LIBRARIES=" + dyld_insert_libraries);
    }

    return environment;
}

struct InjectionPlan
{
    std::string dyldInsertLibraries;
    bool includesBootstrap = false;
    bool includesChildHook = false;
};

static bool is_steam_main_exec_target(const char* path)
{
    if (!path || path[0] == '\0') {
        return false;
    }

    const char* configured_target = getenv(kSteamExecutableEnv);
    if (!configured_target || configured_target[0] == '\0') {
        return false;
    }

    char resolved_target[PATH_MAX];
    const char* normalized_target = configured_target;
    if (realpath(configured_target, resolved_target)) {
        normalized_target = resolved_target;
    }

    char resolved_path[PATH_MAX];
    const char* normalized_path = path;
    if (realpath(path, resolved_path)) {
        normalized_path = resolved_path;
    }

    return strcmp(normalized_path, normalized_target) == 0;
}

static InjectionPlan build_injection_plan(const char* path, char* const envp[], const char* bootstrap_path_ptr)
{
    InjectionPlan plan;
    const char* child_hook_path = get_child_hook_path();

    plan.includesBootstrap = bootstrap_path_ptr && is_steam_main_exec_target(path);
    plan.includesChildHook = child_hook_path && access(child_hook_path, R_OK) == 0;

    std::vector<const char*> injected_libraries;
    if (plan.includesBootstrap) {
        injected_libraries.push_back(bootstrap_path_ptr);
    }
    if (plan.includesChildHook) {
        injected_libraries.push_back(child_hook_path);
    }

    plan.dyldInsertLibraries = rewrite_injected_libraries(injected_libraries, plan.includesBootstrap ? nullptr : bootstrap_path_ptr, envp);
    return plan;
}

static const char* describe_injection_plan(const InjectionPlan& plan)
{
    if (plan.includesBootstrap && plan.includesChildHook) {
        return "bootstrap+child-hook";
    }
    if (plan.includesBootstrap) {
        return "bootstrap";
    }
    if (plan.includesChildHook) {
        return "child-hook";
    }
    return "";
}

static void update_current_process_injected_libraries()
{
    char bootstrap_path[PATH_MAX];
    if (!get_bootstrap_path(bootstrap_path, sizeof(bootstrap_path))) {
        return;
    }

    const char* existing_value = getenv("DYLD_INSERT_LIBRARIES");
    if (!existing_value || existing_value[0] == '\0') {
        return;
    }

    const char* child_hook_path = get_child_hook_path();
    std::vector<const char*> injected_libraries;

    if (child_hook_path && access(child_hook_path, R_OK) == 0) {
        injected_libraries.push_back(child_hook_path);
    }

    const std::string rewritten = rewrite_injected_libraries(injected_libraries, bootstrap_path, nullptr);
    if (rewritten.empty()) {
        unsetenv("DYLD_INSERT_LIBRARIES");
        return;
    }

    setenv("DYLD_INSERT_LIBRARIES", rewritten.c_str(), 1);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int call_execve_syscall(const char* path, char* const argv[], char* const envp[])
{
    return static_cast<int>(syscall(SYS_execve, path, argv, envp ? envp : environ));
}
#pragma clang diagnostic pop

static int millennium_execve(const char* path, char* const argv[], char* const envp[])
{
    // The inherited environment already contains the child hook. Both exec
    // entry points can use it without allocating in the browser's fork child.
    if (g_bootstrap_enabled && (envp == environ || !envp) && getpid() != millennium_pipe_bootstrap::owner && millennium_pipe_bootstrap::is_browser(path, argv)) {
        return millennium_pipe_bootstrap::exec(path, argv, environ, call_execve_syscall);
    }
    append_exec_trace("exec-enter", path, argv, "");

    if (!g_bootstrap_enabled) {
        append_exec_trace("exec-bootstrap-disabled", path, argv, "");
        return call_execve_syscall(path, argv, envp);
    }

    char bootstrap_path[PATH_MAX];
    const char* bootstrap_path_ptr = get_bootstrap_path(bootstrap_path, sizeof(bootstrap_path)) ? bootstrap_path : nullptr;
    const InjectionPlan plan = build_injection_plan(path, envp, bootstrap_path_ptr);
    std::vector<std::string> owned_environment = build_child_environment(envp, plan.dyldInsertLibraries);
    std::vector<char*> exec_environment;
    exec_environment.reserve(owned_environment.size() + 1);
    for (std::string& entry : owned_environment) {
        exec_environment.push_back(entry.data());
    }
    exec_environment.push_back(nullptr);

    const char* trace_stage = plan.includesBootstrap || plan.includesChildHook ? "exec-pass-through" : "exec-missing-injection";
    append_exec_trace(trace_stage, path, argv, describe_injection_plan(plan));
    return millennium_pipe_bootstrap::exec(path, argv, exec_environment.data(), call_execve_syscall);
}

DYLD_INTERPOSE(millennium_execve, execve);

static int millennium_execv(const char* path, char* const argv[])
{
    return millennium_execve(path, argv, environ);
}

DYLD_INTERPOSE(millennium_execv, execv);

// StartMillennium creates the runtime thread, which immediately binds sockets, spawns plugin
// processes and starts thread pools. It must not run while dyld is still running initializers:
// other inserted libraries (Proton-ish's protonish.dylib, loaded after this one) patch
// libsystem_kernel's __TEXT from their initializers by making the page writable, and any other
// thread that executes a syscall stub on that page meanwhile dies with SIGBUS
// (KERN_PROTECTION_FAILURE). Initializers run single-threaded on the main thread before main(),
// and the main queue is only drained once main() runs the run loop, so starting from the main
// queue keeps the process single-threaded until every initializer has returned. libmillennium
// already relies on Steam draining the main queue (macos_window_style.mm). The callback lives in
// this library, which is never unloaded, and bootstrap_cleanup cancels it if Steam exits first.
static start_millennium_t g_start_millennium = nullptr;
static bool g_start_pending = false;
static bool g_runtime_started = false;
static os_unfair_lock g_start_lock = OS_UNFAIR_LOCK_INIT;

static void start_millennium_after_initializers(void*)
{
    os_unfair_lock_lock(&g_start_lock);
    const bool pending = g_start_pending;
    g_start_pending = false;
    if (pending) {
        append_trace("bootstrap-start-runtime");
        if (g_start_millennium() < 0) {
            fprintf(stderr, "[Millennium] Failed to start runtime.\n");
            dlclose(g_millennium_handle);
            g_millennium_handle = nullptr;
            millennium_pipe_bootstrap::shutdown();
        } else {
            g_runtime_started = true;
        }
    }
    os_unfair_lock_unlock(&g_start_lock);
}

// Steam quits through exit(), whether main() returns, AppKit terminates, or Steam calls it
// itself. bootstrap_cleanup -> StopMillennium only runs once exit() has already run every
// atexit handler registered after this library's: Steam's static destructors and the
// function-local statics libmillennium creates while running. Millennium's threads keep using
// those during that time, and its teardown frees and logs through them afterwards, which
// corrupts the heap (SIGSEGV in mfm_free, or std::thread::join throwing during backend
// shutdown). So stop the runtime here, before exit() destroys anything, and leave only the
// final step (cancelling the exit watchdog) to StopMillennium. Calls to exit() from inside
// this library are not interposed, so the exit() below is the real one.
typedef int (*before_exit_millennium_t)(void);

static void millennium_exit(int status)
{
    static std::atomic<bool> stopping{ false };

    os_unfair_lock_lock(&g_start_lock);
    const bool started = g_runtime_started && g_millennium_handle;
    os_unfair_lock_unlock(&g_start_lock);

    if (started && !stopping.exchange(true)) {
        auto before_exit = (before_exit_millennium_t)dlsym(g_millennium_handle, "MillenniumBeforeExit");
        if (before_exit) {
            append_trace("bootstrap-before-exit");
            before_exit();
        }
    }

    exit(status);
}

DYLD_INTERPOSE(millennium_exit, exit);

__attribute__((constructor)) static void bootstrap_init()
{
    if (!is_steam_main_process()) {
        return;
    }

    g_bootstrap_enabled = true;
    append_trace("bootstrap-main-process");
    update_current_process_injected_libraries();

    const char* runtime_path = get_runtime_path();
    if (!runtime_path) {
        fprintf(stderr, "[Millennium] Failed to resolve runtime path for macOS bootstrap.\n");
        return;
    }

    g_millennium_handle = dlopen(runtime_path, RTLD_NOW | RTLD_GLOBAL);
    if (!g_millennium_handle) {
        fprintf(stderr, "[Millennium] Failed to load runtime library: %s\n", dlerror());
        return;
    }

    start_millennium_t start_millennium = (start_millennium_t)dlsym(g_millennium_handle, "StartMillennium");
    if (!start_millennium) {
        fprintf(stderr, "[Millennium] Failed to locate StartMillennium: %s\n", dlerror());
        dlclose(g_millennium_handle);
        g_millennium_handle = nullptr;
        return;
    }

    if (!millennium_pipe_bootstrap::initialize(g_millennium_handle)) {
        fprintf(stderr, "[Millennium] Failed to start runtime.\n");
        dlclose(g_millennium_handle);
        g_millennium_handle = nullptr;
        millennium_pipe_bootstrap::shutdown();
        return;
    }

    g_start_millennium = start_millennium;
    g_start_pending = true;
    dispatch_async_f(dispatch_get_main_queue(), nullptr, start_millennium_after_initializers);
}

__attribute__((destructor)) static void bootstrap_cleanup()
{
    os_unfair_lock_lock(&g_start_lock);
    const bool never_started = g_start_pending;
    g_start_pending = false;
    os_unfair_lock_unlock(&g_start_lock);

    if (!g_millennium_handle) {
        return;
    }

    stop_millennium_t stop_millennium = never_started ? nullptr : (stop_millennium_t)dlsym(g_millennium_handle, "StopMillennium");
    if (stop_millennium) {
        stop_millennium();
    }

    dlclose(g_millennium_handle);
    g_millennium_handle = nullptr;

    g_bootstrap_enabled = false;
    millennium_pipe_bootstrap::shutdown();
}
#endif
